#include <metal_stdlib>
#include "shader_types.h"
using namespace metal;
using namespace gc::shader;

// ------------------------------------------------------------ helpers
static float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float noise2(float2 p) {
  float2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}
static float fbm(float2 p) { return noise2(p) * 0.55 + noise2(p * 2.1 + 3.7) * 0.3 + noise2(p * 4.3 + 9.1) * 0.15; }

// ------------------------------------------------------------ highway board
struct HighwayVert { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct HighwayOut { float4 pos [[position]]; float2 uv; float3 world; };

vertex HighwayOut highway_vs(uint vid [[vertex_id]], constant float3* verts [[buffer(0)]], constant float2* uvs [[buffer(1)]], constant FrameUniforms& u [[buffer(2)]]) {
  HighwayOut o;
  o.world = verts[vid];
  o.uv = uvs[vid];
  o.pos = u.viewProj * float4(o.world, 1.0);
  return o;
}

// Brushed metal (horizontal streaks that vary mostly along the scroll axis), tiled like the web canvas texture.
static float brushed(float2 t) {
  float2 p = fract(t) * 256.0;
  float row = hash21(float2(0.0, floor(p.y)));
  float row2 = hash21(float2(0.0, floor(p.y) + 1.0));
  float grain = hash21(floor(p));
  return 0.5 + (row - 0.5) * 0.5 + (grain - 0.5) * 0.25 + (row2 - 0.5) * 0.15;
}

fragment float4 highway_fs(HighwayOut in [[stage_in]], constant FrameUniforms& u [[buffer(2)]]) {
  float W = u.highwayWidth;
  float x = (in.uv.x - 0.5) * W;
  float laneX = x * u.laneSign + 2.5;
  float scrollZ = in.world.z + u.scroll;
  float br = brushed(float2(in.uv.x * 2.0, scrollZ * 0.08));
  float br2 = brushed(float2(in.uv.x * 0.7 + 0.3, scrollZ * 0.02));
  float3 base = float3(0.055, 0.055, 0.062) + (br - 0.5) * 0.05 + (br2 - 0.5) * 0.03;
  float3 toCam = normalize(u.cameraPos - in.world);
  float sheen = pow(max(0.0, 1.0 - abs(in.uv.x - 0.5 - sin(u.time * 0.35) * 0.25) * 2.2), 3.0) * 0.06;
  sheen += pow(max(0.0, toCam.y), 6.0) * 0.05 * (0.6 + 0.4 * br);
  base += sheen;
  float streak = pow(noise2(float2(in.uv.x * 4.0, scrollZ * 0.5 - u.time * 2.2)), 3.0);
  float bolt = pow(noise2(float2(in.uv.x * 12.0 + u.time, scrollZ * 0.25 - u.time * 4.0)), 8.0);
  float3 spBase = float3(0.03, 0.07, 0.2) + (br - 0.5) * 0.06 + float3(0.25, 0.55, 1.0) * (streak * 0.3 + bolt * 0.7);
  float3 col = mix(base, spBase, u.starPower);
  float d = 1.0;
  for (int k = 1; k < 5; k++) d = min(d, abs(laneX - float(k)));
  float line = 1.0 - smoothstep(0.008, 0.026, d);
  col = mix(col, mix(float3(0.30, 0.30, 0.33), float3(0.55, 0.75, 1.0), u.starPower), line * 0.9);
  float nearStrike = smoothstep(-9.0, 0.6, in.world.z) * smoothstep(2.4, 0.4, in.world.z);
  float heldArr[5] = {u.held.x, u.held.y, u.held.z, u.held.w, u.heldExtra.x};
  for (int k = 0; k < 5; k++) {
    float inLane = 1.0 - smoothstep(0.30, 0.5, abs(laneX - (float(k) + 0.5)));
    col += u.laneColors[k].rgb * inLane * heldArr[k] * nearStrike * 0.16;
  }
  col += float3(0.05, 0.045, 0.04) * u.beat * smoothstep(3.0, 0.0, abs(in.world.z));
  col += u.flash * float3(0.2, 0.28, 0.4);
  col += (u.lighting.x * 0.25 + u.lighting.w * 0.35) * float3(1.0, 0.95, 0.9);
  col *= 1.0 - u.lighting.y * 0.55;
  float fade = smoothstep(-u.highwayLen, -(u.highwayLen - 8.0), in.world.z);
  return float4(col * fade, 1.0);
}

// ------------------------------------------------------------ lit instanced gems / receptors
struct LitVert { float3 pos [[attribute(0)]]; float3 normal [[attribute(1)]]; float3 tint [[attribute(2)]]; };
struct LitOut { float4 pos [[position]]; float3 world; float3 normal; float3 color; float emissive; };

vertex LitOut lit_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant float3* verts [[buffer(0)]], constant float3* normals [[buffer(1)]], constant float3* tints [[buffer(3)]], constant GemInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]], constant LitMaterial& m [[buffer(5)]]) {
  LitOut o;
  float4 w = inst[iid].model * float4(verts[vid], 1.0);
  float3 n = normalize((inst[iid].model * float4(normals[vid], 0.0)).xyz);
  if (m.mirror > 0.5) { w.y = -w.y - 0.02; n.y = -n.y; }  // planar reflection in the board
  o.world = w.xyz;
  o.normal = n;
  o.color = tints[vid] * inst[iid].color.rgb;
  o.emissive = inst[iid].color.w;
  o.pos = u.viewProj * w;
  return o;
}

// Procedural "room" environment (bright overhead panels, warm key panels, dark floor) standing in for
// the web build's RoomEnvironment PMREM. Roughness widens the panels so rough surfaces see a blurred room.
static float3 envLight(float3 d, float rough) {
  float up = d.y;
  float3 sky = mix(float3(0.16, 0.15, 0.14), float3(0.75, 0.72, 0.66), smoothstep(-0.25, 0.9, up));
  float soft = rough * 0.35;
  float panel = smoothstep(0.55 - soft, 0.96 - soft * 0.4, dot(d, normalize(float3(0.0, 1.0, 0.3))));
  float panel2 = smoothstep(0.72 - soft, 0.985 - soft * 0.4, dot(d, normalize(float3(-0.6, 0.45, -0.65))));
  float panel3 = smoothstep(0.76 - soft, 0.99 - soft * 0.4, dot(d, normalize(float3(0.7, 0.35, 0.6))));
  float3 col = sky + float3(1.0, 0.96, 0.88) * panel * 1.7 + float3(1.0, 0.85, 0.42) * panel2 * 1.1 + float3(0.9, 0.92, 1.0) * panel3 * 0.9;
  col = mix(col, float3(0.05, 0.045, 0.045), smoothstep(0.0, -0.5, up));
  return col;
}
static float ggxD(float NoH, float a) { float a2 = a * a; float d = NoH * NoH * (a2 - 1.0) + 1.0; return a2 / (M_PI_F * d * d + 1e-5); }
static float ggxVis(float NoL, float NoV, float a) { float k = a * a * 0.5; return 0.25 / ((NoL * (1.0 - k) + k) * (NoV * (1.0 - k) + k) + 1e-4); }
static float3 fresnel(float3 f0, float VoH) { return f0 + (1.0 - f0) * pow(1.0 - VoH, 5.0); }

fragment float4 lit_fs(LitOut in [[stage_in]], constant FrameUniforms& u [[buffer(2)]], constant LitMaterial& m [[buffer(5)]]) {
  float3 n = normalize(in.normal);
  float3 v = normalize(u.cameraPos - in.world);
  if (dot(n, v) < 0.0) n = -n;  // two-sided: meshes are drawn without culling
  float NoV = max(0.0, dot(n, v));
  float3 base = in.color;
  float rough = max(0.05, m.roughness), a = rough * rough;
  float3 f0 = mix(float3(0.04), base, m.metalness);
  float3 diffuseColor = base * (1.0 - m.metalness);
  // lights matching the web scene: ambient, warm key, yellow rim, warm point light over the strike line
  struct L { float3 dir; float3 radiance; };
  float3 toPt = float3(0.0, 3.5, 1.5) - in.world;
  float ptDist = length(toPt);
  L lights[3] = {
    {normalize(float3(2.0, 8.0, 5.0)), float3(1.0, 0.957, 0.878) * 1.8},
    {normalize(float3(-3.0, 5.0, -10.0)), float3(1.0, 0.83, 0.21) * 1.4},
    {toPt / ptDist, float3(1.0, 0.91, 0.75) * 16.0 / (ptDist * ptDist + 1.0)}};
  float3 diffuse = diffuseColor * 0.35 / M_PI_F;
  float3 spec = 0.0, cc = 0.0;
  for (int i = 0; i < 3; i++) {
    float NoL = max(0.0, dot(n, lights[i].dir));
    if (NoL <= 0.0) continue;
    float3 h = normalize(lights[i].dir + v);
    float NoH = max(0.0, dot(n, h)), VoH = max(0.0, dot(v, h));
    float3 rad = lights[i].radiance * NoL;
    diffuse += diffuseColor / M_PI_F * rad;
    spec += ggxD(NoH, a) * ggxVis(NoL, NoV, a) * fresnel(f0, VoH) * rad;
    cc += ggxD(NoH, 0.12 * 0.12) * ggxVis(NoL, NoV, 0.12 * 0.12) * fresnel(float3(0.04), VoH).x * rad;
  }
  // image based part: procedural room
  float3 R = reflect(-v, n);
  float3 fr = f0 + (max(float3(1.0 - rough), f0) - f0) * pow(1.0 - NoV, 5.0);
  float3 envSpec = envLight(R, rough) * fr * m.envIntensity;
  float3 envDiff = diffuseColor * mix(float3(0.22, 0.2, 0.19), float3(0.6, 0.57, 0.52), n.y * 0.5 + 0.5) * m.envIntensity;
  float ccF = 0.04 + 0.96 * pow(1.0 - NoV, 5.0);
  float3 envCc = envLight(R, 0.12) * ccF * m.envIntensity * 1.2;
  float3 col = diffuse + envDiff + spec + envSpec;
  col = col * (1.0 - m.clearcoat * ccF) + (cc + envCc) * m.clearcoat;
  col += base * in.emissive;
  float fade = smoothstep(-u.highwayLen, -(u.highwayLen - 8.0), in.world.z);
  if (m.mirror > 0.5) {
    if (abs(in.world.x) > u.highwayWidth * 0.5 || in.world.z > 2.4) discard_fragment();
    float depthFade = saturate(1.0 + in.world.y / 0.7);  // deeper below the board = fainter
    float a = m.reflect * depthFade * (1.0 - u.lighting.y * 0.8);
    return float4(col * fade * a, a);
  }
  col *= 1.0 + u.lighting.x * 0.5 + u.lighting.w * 0.6;
  return float4(col * fade, 1.0);
}

// ------------------------------------------------------------ flat coloured geometry (rails, beat lines, strike line)
struct FlatOut { float4 pos [[position]]; float4 color; float z; };

vertex FlatOut flat_vs(uint vid [[vertex_id]], constant FlatVertex* verts [[buffer(0)]], constant FrameUniforms& u [[buffer(2)]]) {
  FlatOut o;
  o.pos = u.viewProj * float4(verts[vid].pos, 1.0);
  o.color = verts[vid].color;
  o.z = verts[vid].pos.z;
  return o;
}

fragment float4 flat_fs(FlatOut in [[stage_in]], constant FrameUniforms& u [[buffer(2)]]) {
  float fade = smoothstep(-u.highwayLen, -(u.highwayLen - 8.0), in.z);
  return float4(in.color.rgb * fade, in.color.a * fade);
}

// ------------------------------------------------------------ sustain trails (additive)
struct TrailOut { float4 pos [[position]]; float2 uv; float along; uint iid; };

constant uint TRAIL_SEGMENTS = 64;  // the whammy wobble is evaluated per vertex, so the strip is subdivided along its length

vertex TrailOut trail_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant TrailInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]]) {
  // triangle strip of TRAIL_SEGMENTS segments: 2 * (TRAIL_SEGMENTS + 1) vertices, uv in [0,1]
  float2 uv = float2(vid & 1, float(vid >> 1) / float(TRAIL_SEGMENTS));
  TrailInstance t = inst[iid];
  float along = (uv.y - 0.5) * t.length;
  // whammy wobble: a wave travelling away from the fret, anchored at the strike line, eased by the smoothed whammy amount
  float fromFret = (1.0 - uv.y) * t.length;  // distance from the near (strike line) end
  float anchor = smoothstep(0.0, 1.6, fromFret);
  float amp = u.whammy * t.active * 0.11 * anchor * (0.7 + 0.3 * u.whammy);
  float wob = amp * sin(fromFret * 2.6 - u.time * 16.0);
  float x = t.pos.x + (uv.x - 0.5) * t.width + wob;
  float z = t.pos.z + along;
  TrailOut o;
  o.pos = u.viewProj * float4(x, t.pos.y, z, 1.0);
  o.uv = uv;
  o.along = along;
  o.iid = iid;
  return o;
}

fragment float4 trail_fs(TrailOut in [[stage_in]], constant TrailInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]]) {
  TrailInstance t = inst[in.iid];
  float x = abs(in.uv.x - 0.5) * 2.0;
  float core = 1.0 - smoothstep(0.18, 0.34, x);
  float glow = 1.0 - smoothstep(0.2, 1.0, x);
  float endFade = smoothstep(0.0, 0.08, in.uv.y) * smoothstep(1.0, 0.92, in.uv.y);
  float stripes = 0.5 + 0.5 * sin(in.along * 4.0 + u.time * 9.0);
  float energy = t.active * (0.35 + 0.45 * stripes);
  float3 coreCol = mix(t.color.rgb, float3(1.0), 0.25 + energy * 0.35) * (1.0 + t.active * 0.7);
  float3 glowCol = mix(t.color.rgb, float3(0.6, 0.85, 1.0), t.sp * 0.6) * (0.25 + t.active * 0.35);
  float3 col = coreCol * core + glowCol * glow * (1.0 - core * 0.5);
  float alpha = (core * 0.95 + glow * 0.45) * endFade;
  if (t.dropped > 0.5) { col = float3(0.35) * core + float3(0.12) * glow; alpha = (core * 0.7 + glow * 0.2) * endFade; }
  return float4(col * alpha, alpha);
}

// ------------------------------------------------------------ procedural flames (additive billboards)
struct FlameOut { float4 pos [[position]]; float2 uv; uint iid; };

vertex FlameOut flame_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant FlameInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]]) {
  float2 uv = float2(vid & 1, vid >> 1);
  FlameInstance f = inst[iid];
  // billboard: right = camera right approximated by world x, up = world y tilted toward camera
  float3 right = float3(1.0, 0.0, 0.0) * f.flip;
  float3 up = normalize(float3(0.0, 1.0, 0.35));
  float3 p = f.pos + right * (uv.x - 0.5) * f.scale * 1.0 + up * uv.y * f.scale * 2.1;
  FlameOut o;
  o.pos = u.viewProj * float4(p, 1.0);
  o.uv = uv;
  o.iid = iid;
  return o;
}

fragment float4 flame_fs(FlameOut in [[stage_in]], constant FlameInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]]) {
  FlameInstance f = inst[in.iid];
  float2 uv = in.uv;
  float t = u.time * 2.4 + f.seed;
  float n = fbm(float2(uv.x * 3.0 + f.seed, uv.y * 3.5 - t * 2.2));
  float n2 = fbm(float2(uv.x * 6.0 - f.seed, uv.y * 7.0 - t * 3.1));
  float age = 1.0 - f.life;
  float height = 0.55 + 0.55 * smoothstep(0.0, 0.35, age) * (1.0 - 0.5 * smoothstep(0.5, 1.0, age));
  float w = (0.34 * (1.0 - uv.y / height) + 0.03) * (1.0 - 0.25 * age);
  float dx = (uv.x - 0.5) + (n - 0.5) * 0.45 * uv.y;
  float shape = 1.0 - smoothstep(w * 0.5, w, abs(dx));
  float tip = 1.0 - smoothstep(height * 0.55, height, uv.y + (n2 - 0.5) * 0.35);
  float base = smoothstep(0.0, 0.06, uv.y);
  float flame = shape * tip * base;
  float heat = clamp(flame * (0.4 + 0.6 * n2), 0.0, 1.0);
  float3 core = float3(1.0, 0.97, 0.85);
  float3 mid = mix(float3(1.0, 0.62, 0.12), f.color.rgb, 0.35);
  float3 outer = mix(float3(0.9, 0.22, 0.02), f.color.rgb, 0.45);
  float3 col = mix(outer, mid, smoothstep(0.15, 0.55, heat));
  col = mix(col, core, smoothstep(0.72, 1.0, heat) * (1.0 - uv.y * 0.9));
  float alpha = heat * (1.0 - smoothstep(0.75, 1.0, age));
  col *= 1.0 + 0.8 * smoothstep(0.5, 1.0, heat);  // HDR core feeds the bloom
  return float4(col * alpha, alpha);
}

// ------------------------------------------------------------ sparks (additive camera-facing dots)
struct SparkOut { float4 pos [[position]]; float2 uv; float4 color; };

vertex SparkOut spark_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant SparkInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]]) {
  float2 uv = float2(vid & 1, vid >> 1);
  SparkInstance sp = inst[iid];
  float3 right = float3(1.0, 0.0, 0.0);
  float3 up = normalize(float3(0.0, 1.0, 0.45));
  float3 p = sp.pos + right * (uv.x - 0.5) * sp.size + up * (uv.y - 0.5) * sp.size;
  SparkOut o;
  o.pos = u.viewProj * float4(p, 1.0);
  o.uv = uv;
  o.color = sp.color;
  return o;
}

fragment float4 spark_fs(SparkOut in [[stage_in]]) {
  float d = length(in.uv - 0.5) * 2.0;
  float a = pow(max(0.0, 1.0 - d), 1.6);
  float core = smoothstep(0.5, 0.0, d);
  float3 col = in.color.rgb * a + float3(1.0, 0.95, 0.8) * core * 0.6;
  return float4(col * a, a);
}

// ------------------------------------------------------------ hit rings (additive quads flat on the board)
struct RingOut { float4 pos [[position]]; float2 uv; uint iid; };

vertex RingOut ring_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant RingInstance* inst [[buffer(4)]], constant FrameUniforms& u [[buffer(2)]]) {
  float2 uv = float2(vid & 1, vid >> 1);
  RingInstance r = inst[iid];
  float3 p = r.pos + float3((uv.x - 0.5) * r.scaleX, 0.0, (uv.y - 0.5) * r.scaleZ);
  RingOut o;
  o.pos = u.viewProj * float4(p, 1.0);
  o.uv = uv;
  o.iid = iid;
  return o;
}

fragment float4 ring_fs(RingOut in [[stage_in]], constant RingInstance* inst [[buffer(4)]]) {
  RingInstance r = inst[in.iid];
  float d = length(in.uv - 0.5) * 2.0;
  float band = smoothstep(0.62, 0.8, d) * smoothstep(1.0, 0.88, d);
  float glow = smoothstep(1.0, 0.3, d) * 0.18;
  float a = (band + glow) * r.alpha;
  return float4(r.color.rgb * a, a);
}

// ------------------------------------------------------------ soft glows: radial halo (pad.x = 0) or lane light gradient (pad.x = 1)
fragment float4 glow_fs(RingOut in [[stage_in]], constant RingInstance* inst [[buffer(4)]]) {
  RingInstance r = inst[in.iid];
  float a;
  if (r.pad.x > 1.5) {  // band sweeping up the highway
    float band = smoothstep(0.0, 0.45, in.uv.y) * smoothstep(1.0, 0.55, in.uv.y);
    float side = smoothstep(0.0, 0.08, in.uv.x) * smoothstep(1.0, 0.92, in.uv.x);
    a = band * side;
  } else if (r.pad.x > 0.5) {
    float t = in.uv.y;  // 1 at the near (strike line) end
    float along = t < 0.7 ? smoothstep(0.0, 0.7, t) * 0.35 : mix(0.35, 0.9, smoothstep(0.7, 1.0, t));
    float side = smoothstep(0.0, 0.25, in.uv.x) * smoothstep(1.0, 0.75, in.uv.x);
    a = along * side;
  } else {
    float d = length(in.uv - 0.5) * 2.0;
    a = d < 0.25 ? mix(1.0, 0.55, d / 0.25) : d < 0.6 ? mix(0.55, 0.12, (d - 0.25) / 0.35) : mix(0.12, 0.0, clamp((d - 0.6) / 0.4, 0.0, 1.0));
  }
  a *= r.alpha;
  return float4(r.color.rgb * a, a);
}

// ------------------------------------------------------------ background (full-screen stage lights)
struct BgOut { float4 pos [[position]]; float2 uv; };

vertex BgOut bg_vs(uint vid [[vertex_id]]) {
  float2 uv = float2(vid & 1, vid >> 1);
  BgOut o;
  o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
  o.uv = uv;
  return o;
}

static float spot(float2 uv, float2 origin, float angle, float width) {
  float2 d = uv - origin;
  float a = atan2(d.x, -d.y);
  float dist = length(d);
  float cone = smoothstep(width, 0.0, abs(a - angle));
  return cone * smoothstep(1.6, 0.0, dist) * (0.55 + 0.45 * smoothstep(0.0, 0.25, dist));
}

fragment float4 bg_fs(BgOut in [[stage_in]], constant FrameUniforms& u [[buffer(2)]]) {
  float2 uv = in.uv;
  float aspect = u.pad0 > 0.0 ? u.pad0 : 1.6;
  float2 p = float2((uv.x - 0.5) * aspect, uv.y - 0.5);
  float warmth = u.lighting.z;
  float3 base = mix(mix(float3(0.02, 0.025, 0.05), float3(0.045, 0.035, 0.02), warmth), float3(0.015, 0.012, 0.012), uv.y);
  float3 lightCol = mix(mix(float3(0.35, 0.55, 1.0), float3(1.0, 0.72, 0.18), warmth), float3(0.25, 0.45, 1.0), u.starPower);
  float t = u.time * mix(1.6, 1.0, warmth);
  float2 uvA = float2(uv.x * aspect, uv.y);
  float s = 0.0;
  s += spot(uvA, float2(0.15 * aspect, 1.05), sin(t * 0.7) * 0.6, 0.075);
  s += spot(uvA, float2(0.85 * aspect, 1.05), sin(t * 0.9 + 2.0) * 0.6, 0.075);
  s += spot(uvA, float2(0.5 * aspect, 1.08), sin(t * 0.5 + 1.0) * 0.9, 0.06);
  s += 0.6 * spot(uvA, float2(0.35 * aspect, 1.05), sin(t * 1.3 + 4.0) * 0.7, 0.05);
  s += 0.6 * spot(uvA, float2(0.65 * aspect, 1.05), sin(t * 1.1 + 3.0) * 0.7, 0.05);
  float haze = noise2(uvA * 3.0 + float2(t * 0.05, -t * 0.02)) * 0.5 + noise2(uvA * 7.0 - float2(t * 0.08, t * 0.03)) * 0.25;
  s *= 0.6 + 0.8 * haze;
  float crowdLine = 0.16 + 0.05 * noise2(float2(uvA.x * 14.0, 0.0)) + 0.03 * noise2(float2(uvA.x * 40.0 + t * 0.3, 1.0));
  float crowd = smoothstep(crowdLine + 0.005, crowdLine - 0.005, uv.y);
  float glow = smoothstep(0.6, 0.0, length(p * float2(0.8, 1.6) - float2(0.0, -0.3)));
  float3 col = base + lightCol * (s * 0.3 * (0.85 + 0.3 * u.beat)) + lightCol * glow * 0.2 * (0.8 + 0.4 * u.beat);
  col = mix(col, float3(0.01, 0.005, 0.01), crowd * 0.92);
  col *= 1.0 - 0.55 * length(p * float2(0.7, 1.0));
  col += (u.lighting.x * 0.35 + u.lighting.w * 0.5) * float3(1.0, 0.97, 0.9) * (1.0 - crowd * 0.9);
  col *= 1.0 - u.lighting.y * 0.9;
  return float4(col, 1.0);
}

fragment float4 bg_img_fs(BgOut in [[stage_in]], constant FrameUniforms& u [[buffer(2)]], texture2d<float> img [[texture(0)]]) {
  constexpr sampler smp(filter::linear, address::clamp_to_edge);
  float aspect = u.pad0 > 0.0 ? u.pad0 : 1.6;
  float ia = u.bgAspect > 0.0 ? u.bgAspect : 1.6;
  // cover-fit
  float2 uv = in.uv;
  uv.y = 1.0 - uv.y;
  if (aspect > ia) { float s = ia / aspect; uv.y = (uv.y - 0.5) * s + 0.5; }
  else { float s = aspect / ia; uv.x = (uv.x - 0.5) * s + 0.5; }
  float3 tex = img.sample(smp, uv).rgb;
  tex = pow(tex, float3(2.2));
  float2 p = float2((in.uv.x - 0.5) * aspect, in.uv.y - 0.5);
  float vign = 1.0 - 0.55 * length(p * float2(0.7, 1.0));
  float3 lightCol = mix(float3(1.0, 0.72, 0.18), float3(0.25, 0.45, 1.0), u.starPower);
  float3 col = tex * 0.42 * vign + lightCol * u.flash * 0.15;
  return float4(col, 1.0);
}

fragment float4 bg_plain_fs(BgOut in [[stage_in]], constant FrameUniforms& u [[buffer(2)]]) {
  float aspect = u.pad0 > 0.0 ? u.pad0 : 1.6;
  float2 p = float2((in.uv.x - 0.5) * aspect, in.uv.y - 0.5);
  float3 base = mix(float3(0.03, 0.025, 0.02), float3(0.012, 0.01, 0.01), in.uv.y);
  return float4(base * (1.0 - 0.5 * length(p)), 1.0);
}

// ------------------------------------------------------------ post: bloom threshold / blur / composite
struct PostOut { float4 pos [[position]]; float2 uv; };
vertex PostOut post_vs(uint vid [[vertex_id]]) {
  float2 uv = float2(vid & 1, vid >> 1);
  PostOut o;
  o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
  o.uv = float2(uv.x, 1.0 - uv.y);
  return o;
}

fragment float4 bright_fs(PostOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant PostParams& p [[buffer(0)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  // 4-tap box so thin bright features (rails, sparks) survive the half-res downsample; soft knee around the threshold
  float2 o = p.texel * 0.5;
  float3 c = (src.sample(s, in.uv + float2(-o.x, -o.y)).rgb + src.sample(s, in.uv + float2(o.x, -o.y)).rgb + src.sample(s, in.uv + float2(-o.x, o.y)).rgb + src.sample(s, in.uv + float2(o.x, o.y)).rgb) * 0.25;
  float l = dot(c, float3(0.2126, 0.7152, 0.0722));
  float k = smoothstep(p.threshold - 0.3, p.threshold + 0.3, l);
  return float4(c * k, 1.0);
}

fragment float4 blur_fs(PostOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant PostParams& p [[buffer(0)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  const float w[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
  float3 c = src.sample(s, in.uv).rgb * w[0];
  for (int i = 1; i < 5; i++) {
    float2 off = p.dir * p.texel * float(i) * 1.5;
    c += src.sample(s, in.uv + off).rgb * w[i];
    c += src.sample(s, in.uv - off).rgb * w[i];
  }
  return float4(c, 1.0);
}

static float3 neutralTone(float3 x) {
  // Khronos PBR neutral (approximation of three.js NeutralToneMapping)
  const float startCompression = 0.8 - 0.04;
  const float desaturation = 0.15;
  float d = 1.0 - startCompression;
  float peak = max(x.r, max(x.g, x.b));
  if (peak < startCompression) return x;
  float newPeak = 1.0 - d * d / (peak + d - startCompression);
  x *= newPeak / peak;
  float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
  return mix(x, float3(newPeak), g);
}
static float3 acesTone(float3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

fragment float4 composite_fs(PostOut in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> bloom [[texture(1)]], texture2d<float> bloomWide [[texture(2)]], constant PostParams& p [[buffer(0)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  float3 c = scene.sample(s, in.uv).rgb + (bloom.sample(s, in.uv).rgb * 1.3 + bloomWide.sample(s, in.uv).rgb * 1.7) * p.strength;
  c *= p.exposure;
  float l = dot(c, float3(0.2126, 0.7152, 0.0722));
  c = mix(float3(l), c, p.saturation);
  c = (c - 0.18) * p.contrast + 0.18;
  c = max(c, 0.0);
  if (p.tone > 1.5) c = acesTone(c);
  else if (p.tone > 0.5) c = neutralTone(c);
  else c = clamp(c, 0.0, 1.0);
  // linear -> sRGB
  c = pow(c, float3(1.0 / 2.2));
  return float4(c, 1.0);
}

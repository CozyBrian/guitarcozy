#include "renderer.h"
#include <algorithm>
#include <cmath>
#include <random>
#include <mutex>
#include "shader_types.h"

using namespace gc::shader;

namespace gc::render {

namespace {
constexpr float LANE_W = 1.f, HIGHWAY_W = 5.3f, HIGHWAY_LEN = 24.f, NEAR_Z = 2.6f, BASE_SPEED = 10.f, GEM_R = 0.47f;
constexpr int MAX_INST = 2048, MAX_FLAT = 8192, MAX_TRAILS = 512, MAX_FLAMES = 32, MAX_SPARKS = 512, MAX_RINGS = 24, MAX_GLOWS = 16;
const uint32_t FRET_COLORS[6] = {0x59bd65, 0xe25853, 0xffd335, 0x548ed8, 0xf29a47, 0xb455ff};

simd_float4 rgba(uint32_t hex, float a = 1.f) {
  auto lin = [](float c) { return powf(c, 2.2f); };
  return simd_make_float4(lin(((hex >> 16) & 255) / 255.f), lin(((hex >> 8) & 255) / 255.f), lin((hex & 255) / 255.f), a);
}

simd_float4x4 perspective(float fovY, float aspect, float n, float f) {
  const float ys = 1.f / tanf(fovY * 0.5f), xs = ys / aspect, zs = f / (n - f);
  return simd_matrix(simd_make_float4(xs, 0, 0, 0), simd_make_float4(0, ys, 0, 0), simd_make_float4(0, 0, zs, -1), simd_make_float4(0, 0, n * zs, 0));
}
simd_float4x4 lookAt(simd_float3 eye, simd_float3 at, simd_float3 up) {
  simd_float3 z = simd_normalize(eye - at), x = simd_normalize(simd_cross(up, z)), y = simd_cross(z, x);
  return simd_matrix(simd_make_float4(x.x, y.x, z.x, 0), simd_make_float4(x.y, y.y, z.y, 0), simd_make_float4(x.z, y.z, z.z, 0), simd_make_float4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1));
}
simd_float4x4 translateScale(float x, float y, float z, float s, float sy) {
  return simd_matrix(simd_make_float4(s, 0, 0, 0), simd_make_float4(0, sy, 0, 0), simd_make_float4(0, 0, s, 0), simd_make_float4(x, y, z, 1));
}

// ---- geometry builders (positions + normals + tint mask; white tint takes the instance colour)
struct Geo { std::vector<simd_float3> pos, nrm, tint; };

void addTri(Geo& g, simd_float3 a, simd_float3 b, simd_float3 c, simd_float3 tint, bool smoothNormals = false, simd_float3 na = {}, simd_float3 nb = {}, simd_float3 nc = {}) {
  simd_float3 n = simd_normalize(simd_cross(b - a, c - a));
  g.pos.insert(g.pos.end(), {a, b, c});
  if (smoothNormals) g.nrm.insert(g.nrm.end(), {na, nb, nc});
  else g.nrm.insert(g.nrm.end(), {n, n, n});
  g.tint.insert(g.tint.end(), {tint, tint, tint});
}

// lathe a 2D profile (r, y) around Y
void lathe(Geo& g, const std::vector<std::pair<float, float>>& prof, int segments, simd_float3 tint) {
  std::vector<simd_float2> profile;
  for (const auto& [r, y] : prof) profile.push_back(simd_make_float2(r, y));
  for (size_t i = 0; i + 1 < profile.size(); i++) {
    simd_float2 p0 = profile[i], p1 = profile[i + 1];
    simd_float2 d = simd_normalize(simd_make_float2(p1.y - p0.y, -(p1.x - p0.x)));  // outward normal in (r,y)
    for (int s = 0; s < segments; s++) {
      float a0 = float(s) / segments * 2 * float(M_PI), a1 = float(s + 1) / segments * 2 * float(M_PI);
      auto P = [&](simd_float2 p, float a) { return simd_make_float3(cosf(a) * p.x, p.y, sinf(a) * p.x); };
      auto N = [&](float a) { return simd_normalize(simd_make_float3(cosf(a) * d.x, d.y, sinf(a) * d.x)); };
      simd_float3 A = P(p0, a0), B = P(p0, a1), C = P(p1, a1), D = P(p1, a0);
      if (p0.x < 1e-5f) { addTri(g, A, C, D, tint, true, N(a0), N(a1), N(a0)); continue; }
      if (p1.x < 1e-5f) { addTri(g, A, B, C, tint, true, N(a0), N(a1), N(a1)); continue; }
      addTri(g, A, B, C, tint, true, N(a0), N(a1), N(a1));
      addTri(g, A, C, D, tint, true, N(a0), N(a1), N(a0));
    }
  }
}

void sphereCap(Geo& g, float r, float yScale, float yOff, int segs, int rings, simd_float3 tint) {
  // profile runs equator -> top (inward and up) so the lathe's perpendicular points outward/up
  std::vector<std::pair<float, float>> prof;
  for (int i = rings; i >= 0; i--) {
    float t = float(i) / rings * float(M_PI) / 2;  // 0 = top, pi/2 = equator
    prof.emplace_back(sinf(t) * r, cosf(t) * r * yScale + yOff);
  }
  lathe(g, prof, segs, tint);
}

void torus(Geo& g, float R, float r, int segs, int tube, float yOff, simd_float3 tint) {
  for (int i = 0; i < segs; i++) {
    float a0 = float(i) / segs * 2 * float(M_PI), a1 = float(i + 1) / segs * 2 * float(M_PI);
    for (int j = 0; j < tube; j++) {
      float b0 = float(j) / tube * 2 * float(M_PI), b1 = float(j + 1) / tube * 2 * float(M_PI);
      auto P = [&](float a, float b) { return simd_make_float3(cosf(a) * (R + cosf(b) * r), sinf(b) * r + yOff, sinf(a) * (R + cosf(b) * r)); };
      auto N = [&](float a, float b) { return simd_make_float3(cosf(a) * cosf(b), sinf(b), sinf(a) * cosf(b)); };
      addTri(g, P(a0, b0), P(a1, b0), P(a1, b1), tint, true, N(a0, b0), N(a1, b0), N(a1, b1));
      addTri(g, P(a0, b0), P(a1, b1), P(a0, b1), tint, true, N(a0, b0), N(a1, b1), N(a0, b1));
    }
  }
}

void box(Geo& g, float w, float h, float d, float yOff, simd_float3 tint) {
  float x = w / 2, y = h / 2, z = d / 2;
  simd_float3 v[8] = {{-x, -y + yOff, -z}, {x, -y + yOff, -z}, {x, y + yOff, -z}, {-x, y + yOff, -z}, {-x, -y + yOff, z}, {x, -y + yOff, z}, {x, y + yOff, z}, {-x, y + yOff, z}};
  int f[6][4] = {{0, 1, 2, 3}, {5, 4, 7, 6}, {4, 0, 3, 7}, {1, 5, 6, 2}, {3, 2, 6, 7}, {4, 5, 1, 0}};
  for (auto& q : f) {
    addTri(g, v[q[0]], v[q[2]], v[q[1]], tint);
    addTri(g, v[q[0]], v[q[3]], v[q[2]], tint);
  }
}

void star(Geo& g, float outer, float inner, float y0, float y1, simd_float3 tint) {
  simd_float3 pts[10];
  for (int i = 0; i < 10; i++) {
    float r = i % 2 == 0 ? outer : inner, a = float(i) / 10 * 2 * float(M_PI) - float(M_PI) / 2;
    pts[i] = simd_make_float3(cosf(a) * r, 0, sinf(a) * r);
  }
  simd_float3 top = simd_make_float3(0, y1, 0), bottom = simd_make_float3(0, y0, 0);
  for (int i = 0; i < 10; i++) {
    simd_float3 a = pts[i], b = pts[(i + 1) % 10];
    simd_float3 aT = a + top * 1.f, bT = b + top;
    aT.y = y1 * 0.92f; bT.y = y1 * 0.92f;
    simd_float3 aB = a, bB = b; aB.y = y0; bB.y = y0;
    // slightly domed top: centre raised
    addTri(g, top, bT, aT, tint);
    addTri(g, aB, aT, bT, tint);
    addTri(g, aB, bT, bB, tint);
    (void)bottom;
  }
}
}  // namespace

Renderer::Renderer(id<MTLDevice> device) : device_(device) {
  queue_ = [device newCommandQueue];
  inflight_ = dispatch_semaphore_create(kFrames);
  for (uint32_t c : FRET_COLORS) colors_.push_back(rgba(c));
}

Renderer::Mesh Renderer::upload(const std::vector<simd_float3>& pos, const std::vector<simd_float3>& nrm, const std::vector<simd_float3>& tint) {
  Mesh m;
  m.pos = [device_ newBufferWithBytes:pos.data() length:pos.size() * sizeof(simd_float3) options:MTLResourceStorageModeShared];
  m.normal = [device_ newBufferWithBytes:nrm.data() length:nrm.size() * sizeof(simd_float3) options:MTLResourceStorageModeShared];
  m.tint = [device_ newBufferWithBytes:tint.data() length:tint.size() * sizeof(simd_float3) options:MTLResourceStorageModeShared];
  m.count = uint32_t(pos.size());
  return m;
}

void Renderer::buildGeometry() {
  const simd_float3 dark = simd_make_float3(0.05f, 0.05f, 0.06f), white = simd_make_float3(1, 1, 1);
  {
    Geo g;
    lathe(g, {{0, 0}, {GEM_R * 1.02f, 0}, {GEM_R * 1.06f, 0.06f}, {GEM_R * 1.02f, 0.13f}, {GEM_R * 0.9f, 0.17f}, {GEM_R * 0.84f, 0.17f}}, 40, dark);
    sphereCap(g, GEM_R * 0.82f, 0.56f, 0.16f, 40, 12, white);
    gemBody_ = upload(g.pos, g.nrm, g.tint);
  }
  {
    Geo g;
    lathe(g, {{0, 0}, {GEM_R * 1.02f, 0}, {GEM_R * 1.06f, 0.06f}, {GEM_R * 1.02f, 0.13f}, {GEM_R * 0.9f, 0.17f}, {0, 0.17f}}, 40, dark);
    star(g, GEM_R * 0.92f, GEM_R * 0.46f, 0.17f, 0.36f, white);
    starGem_ = upload(g.pos, g.nrm, g.tint);
  }
  { Geo g; sphereCap(g, GEM_R * 0.4f, 0.5f, 0.3f, 28, 8, white); hopoCap_ = upload(g.pos, g.nrm, g.tint); }
  { Geo g; lathe(g, {{GEM_R * 0.5f, 0.31f}, {GEM_R * 0.5f, 0.36f}, {0, 0.36f}}, 32, simd_make_float3(0.05f, 0.05f, 0.06f)); tapCap_ = upload(g.pos, g.nrm, g.tint); }
  { Geo g; torus(g, GEM_R * 0.52f, 0.028f, 40, 8, 0.36f, white); tapRing_ = upload(g.pos, g.nrm, g.tint); }
  { Geo g; box(g, HIGHWAY_W * 0.86f, 0.18f, 0.32f, 0.1f, white); openBar_ = upload(g.pos, g.nrm, g.tint); }
  { Geo g; box(g, HIGHWAY_W * 0.8f, 0.04f, 0.1f, 0.2f, white); openHopo_ = upload(g.pos, g.nrm, g.tint); }
  {
    const float R = GEM_R * 1.08f;
    Geo g; lathe(g, {{0, 0}, {R, 0}, {R * 1.04f, 0.05f}, {R * 0.98f, 0.1f}, {R * 0.8f, 0.1f}, {0, 0.1f}}, 44, simd_make_float3(0.12f, 0.12f, 0.13f));
    receptorBase_ = upload(g.pos, g.nrm, g.tint);
  }
  { Geo g; torus(g, GEM_R * 0.88f, 0.055f, 48, 12, 0.11f, white); receptorRing_ = upload(g.pos, g.nrm, g.tint); }
  { Geo g; sphereCap(g, GEM_R * 0.74f, 0.22f, 0.1f, 36, 8, white); receptorDisc_ = upload(g.pos, g.nrm, g.tint); }
  // highway quad (two triangles), z from NEAR_Z to -HIGHWAY_LEN
  const float hw = HIGHWAY_W / 2;
  simd_float3 hp[6] = {{-hw, 0, NEAR_Z}, {hw, 0, NEAR_Z}, {hw, 0, -HIGHWAY_LEN}, {-hw, 0, NEAR_Z}, {hw, 0, -HIGHWAY_LEN}, {-hw, 0, -HIGHWAY_LEN}};
  simd_float2 huv[6] = {{0, 1}, {1, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 0}};
  highwayPos_ = [device_ newBufferWithBytes:hp length:sizeof hp options:MTLResourceStorageModeShared];
  highwayUv_ = [device_ newBufferWithBytes:huv length:sizeof huv options:MTLResourceStorageModeShared];
  for (int i = 0; i < kFrames; i++) {
    uniforms_[i] = [device_ newBufferWithLength:sizeof(FrameUniforms) options:MTLResourceStorageModeShared];
    instBuf_[i] = [device_ newBufferWithLength:sizeof(GemInstance) * MAX_INST options:MTLResourceStorageModeShared];
    flatBuf_[i] = [device_ newBufferWithLength:sizeof(FlatVertex) * MAX_FLAT options:MTLResourceStorageModeShared];
    trailBuf_[i] = [device_ newBufferWithLength:sizeof(TrailInstance) * MAX_TRAILS options:MTLResourceStorageModeShared];
    flameBuf_[i] = [device_ newBufferWithLength:sizeof(FlameInstance) * MAX_FLAMES options:MTLResourceStorageModeShared];
    sparkBuf_[i] = [device_ newBufferWithLength:sizeof(SparkInstance) * MAX_SPARKS options:MTLResourceStorageModeShared];
    ringBuf_[i] = [device_ newBufferWithLength:sizeof(RingInstance) * MAX_RINGS options:MTLResourceStorageModeShared];
    glowBuf_[i] = [device_ newBufferWithLength:sizeof(RingInstance) * MAX_GLOWS options:MTLResourceStorageModeShared];
  }
  sparks_.resize(MAX_SPARKS);
  rings_.resize(MAX_RINGS);
}

namespace {
struct PsoCache {
  std::mutex mutex;
  bool built = false, ok = false;
  std::string error;
  id<MTLDevice> device;
  id<MTLRenderPipelineState> highway, lit, litRefl, flat, trail, flame, spark, ring, glow, bg, bgImg, bgPlain, bright, blur, composite;
  id<MTLDepthStencilState> depthWrite, depthTest, depthNone;
};
PsoCache& psoCache() { static PsoCache c; return c; }

bool buildCache(PsoCache& c, id<MTLDevice> device, id<MTLLibrary> lib, std::string* error) {
  auto make = [&](const char* vs, const char* fs, MTLPixelFormat fmt, bool depth, int blend) -> id<MTLRenderPipelineState> {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.rasterSampleCount = depth ? 4 : 1;
    d.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:vs]];
    d.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:fs]];
    if (!d.vertexFunction || !d.fragmentFunction) { if (error) *error = std::string("missing shader ") + vs + "/" + fs; return nil; }
    d.colorAttachments[0].pixelFormat = fmt;
    if (depth) d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    if (blend) {
      d.colorAttachments[0].blendingEnabled = YES;
      d.colorAttachments[0].sourceRGBBlendFactor = blend == 2 ? MTLBlendFactorOne : MTLBlendFactorSourceAlpha;
      d.colorAttachments[0].destinationRGBBlendFactor = blend == 2 ? MTLBlendFactorOne : MTLBlendFactorOneMinusSourceAlpha;
      d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso && error) *error = err.localizedDescription.UTF8String;
    return pso;
  };
  const MTLPixelFormat hdr = MTLPixelFormatRGBA16Float;
  c.highway = make("highway_vs", "highway_fs", hdr, true, 0);
  c.lit = make("lit_vs", "lit_fs", hdr, true, 0);
  c.litRefl = make("lit_vs", "lit_fs", hdr, true, 2);
  c.flat = make("flat_vs", "flat_fs", hdr, true, 1);
  c.trail = make("trail_vs", "trail_fs", hdr, true, 2);
  c.flame = make("flame_vs", "flame_fs", hdr, true, 2);
  c.spark = make("spark_vs", "spark_fs", hdr, true, 2);
  c.ring = make("ring_vs", "ring_fs", hdr, true, 2);
  c.glow = make("ring_vs", "glow_fs", hdr, true, 2);
  c.bg = make("bg_vs", "bg_fs", hdr, true, 0);
  c.bgImg = make("bg_vs", "bg_img_fs", hdr, true, 0);
  c.bgPlain = make("bg_vs", "bg_plain_fs", hdr, true, 0);
  c.bright = make("post_vs", "bright_fs", hdr, false, 0);
  c.blur = make("post_vs", "blur_fs", hdr, false, 0);
  c.composite = make("post_vs", "composite_fs", MTLPixelFormatBGRA8Unorm, false, 0);
  if (!c.highway || !c.lit || !c.litRefl || !c.flat || !c.trail || !c.flame || !c.spark || !c.ring || !c.glow || !c.bg || !c.bgImg || !c.bgPlain || !c.bright || !c.blur || !c.composite) return false;
  MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
  ds.depthCompareFunction = MTLCompareFunctionLess;
  ds.depthWriteEnabled = YES;
  c.depthWrite = [device newDepthStencilStateWithDescriptor:ds];
  ds.depthWriteEnabled = NO;
  c.depthTest = [device newDepthStencilStateWithDescriptor:ds];
  ds.depthCompareFunction = MTLCompareFunctionAlways;
  c.depthNone = [device newDepthStencilStateWithDescriptor:ds];
  c.device = device;
  return true;
}
bool ensureCache(id<MTLDevice> device, const std::string& metallibPath, std::string* error) {
  PsoCache& c = psoCache();
  std::lock_guard<std::mutex> lock(c.mutex);
  if (c.built && c.device == device) { if (!c.ok && error) *error = c.error; return c.ok; }
  NSError* err = nil;
  id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:metallibPath.c_str()]] error:&err];
  c.built = true;
  if (!lib) { c.ok = false; c.error = std::string("cannot load metallib: ") + (err ? err.localizedDescription.UTF8String : "?"); if (error) *error = c.error; return false; }
  std::string e;
  c.ok = buildCache(c, device, lib, &e);
  c.error = e;
  if (!c.ok && error) *error = e;
  return c.ok;
}
}  // namespace

void Renderer::preload(id<MTLDevice> device, const std::string& metallibPath) { ensureCache(device, metallibPath, nullptr); }

bool Renderer::buildPipelinesUnused(id<MTLLibrary> lib, std::string* error) {
  auto make = [&](const char* vs, const char* fs, MTLPixelFormat fmt, bool depth, int blend) -> id<MTLRenderPipelineState> {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.rasterSampleCount = depth ? kSamples : 1;  // scene passes are multisampled, post passes are not
    d.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:vs]];
    d.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:fs]];
    if (!d.vertexFunction || !d.fragmentFunction) { if (error) *error = std::string("missing shader ") + vs + "/" + fs; return nil; }
    d.colorAttachments[0].pixelFormat = fmt;
    if (depth) d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    if (blend) {
      d.colorAttachments[0].blendingEnabled = YES;
      d.colorAttachments[0].sourceRGBBlendFactor = blend == 2 ? MTLBlendFactorOne : MTLBlendFactorSourceAlpha;
      d.colorAttachments[0].destinationRGBBlendFactor = blend == 2 ? MTLBlendFactorOne : MTLBlendFactorOneMinusSourceAlpha;
      d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso && error) *error = err.localizedDescription.UTF8String;
    return pso;
  };
  const MTLPixelFormat hdr = MTLPixelFormatRGBA16Float;
  highwayPso_ = make("highway_vs", "highway_fs", hdr, true, 0);
  litPso_ = make("lit_vs", "lit_fs", hdr, true, 0);
  flatPso_ = make("flat_vs", "flat_fs", hdr, true, 1);
  trailPso_ = make("trail_vs", "trail_fs", hdr, true, 2);
  flamePso_ = make("flame_vs", "flame_fs", hdr, true, 2);
  sparkPso_ = make("spark_vs", "spark_fs", hdr, true, 2);
  ringPso_ = make("ring_vs", "ring_fs", hdr, true, 2);
  glowPso_ = make("ring_vs", "glow_fs", hdr, true, 2);
  bgPso_ = make("bg_vs", "bg_fs", hdr, true, 0);
  bgImgPso_ = make("bg_vs", "bg_img_fs", hdr, true, 0);
  bgPlainPso_ = make("bg_vs", "bg_plain_fs", hdr, true, 0);
  brightPso_ = make("post_vs", "bright_fs", hdr, false, 0);
  blurPso_ = make("post_vs", "blur_fs", hdr, false, 0);
  compositePso_ = make("post_vs", "composite_fs", MTLPixelFormatBGRA8Unorm, false, 0);
  if (!highwayPso_ || !litPso_ || !flatPso_ || !trailPso_ || !flamePso_ || !sparkPso_ || !ringPso_ || !glowPso_ || !bgPso_ || !bgImgPso_ || !bgPlainPso_ || !brightPso_ || !blurPso_ || !compositePso_) return false;
  MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
  ds.depthCompareFunction = MTLCompareFunctionLess;
  ds.depthWriteEnabled = YES;
  depthWrite_ = [device_ newDepthStencilStateWithDescriptor:ds];
  ds.depthWriteEnabled = NO;
  depthTest_ = [device_ newDepthStencilStateWithDescriptor:ds];
  ds.depthCompareFunction = MTLCompareFunctionAlways;
  depthNone_ = [device_ newDepthStencilStateWithDescriptor:ds];
  return true;
}

bool Renderer::init(const std::string& metallibPath, std::string* error) {
  if (!ensureCache(device_, metallibPath, error)) return false;
  buildGeometry();
  const PsoCache& c = psoCache();
  highwayPso_ = c.highway; litPso_ = c.lit; litReflPso_ = c.litRefl; flatPso_ = c.flat; trailPso_ = c.trail; flamePso_ = c.flame; sparkPso_ = c.spark; ringPso_ = c.ring; glowPso_ = c.glow;
  bgPso_ = c.bg; bgImgPso_ = c.bgImg; bgPlainPso_ = c.bgPlain; brightPso_ = c.bright; blurPso_ = c.blur; compositePso_ = c.composite;
  depthWrite_ = c.depthWrite; depthTest_ = c.depthTest; depthNone_ = c.depthNone;
  return true;
}

void Renderer::setChart(const Chart* chart, const Track* track) { chart_ = chart; track_ = track; }

void Renderer::resize(int w, int h) {
  width_ = std::max(1, w);
  height_ = std::max(1, h);
  sceneTex_ = nil;
}

void Renderer::ensureTargets() {
  const float rs = std::max(0.25f, std::min(1.f, settings_.renderScale));
  targetW_ = std::max(1, int(std::lround(width_ * rs)));
  targetH_ = std::max(1, int(std::lround(height_ * rs)));
  if (sceneTex_ && int(sceneTex_.width) == targetW_ && int(sceneTex_.height) == targetH_) return;
  auto tex = [&](MTLPixelFormat f, int w, int h, bool depth, int samples = 1) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:std::max(1, w) height:std::max(1, h) mipmapped:NO];
    d.usage = depth || samples > 1 ? MTLTextureUsageRenderTarget : (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    d.storageMode = MTLStorageModePrivate;
    if (samples > 1) { d.textureType = MTLTextureType2DMultisample; d.sampleCount = samples; }
    return [device_ newTextureWithDescriptor:d];
  };
  const int w = targetW_, h = targetH_;
  sceneTex_ = tex(MTLPixelFormatRGBA16Float, w, h, false);
  msaaTex_ = tex(MTLPixelFormatRGBA16Float, w, h, false, kSamples);
  depthTex_ = tex(MTLPixelFormatDepth32Float, w, h, true, kSamples);
  brightTex_ = tex(MTLPixelFormatRGBA16Float, w / 2, h / 2, false);
  blurA_ = tex(MTLPixelFormatRGBA16Float, w / 4, h / 4, false);
  blurB_ = tex(MTLPixelFormatRGBA16Float, w / 4, h / 4, false);
  blurC_ = tex(MTLPixelFormatRGBA16Float, w / 8, h / 8, false);
  blurD_ = tex(MTLPixelFormatRGBA16Float, w / 8, h / 8, false);
}

float Renderer::beatPulse(double songTime) const {
  if (!chart_ || chart_->beats.empty()) return 0;
  const auto& beats = chart_->beats;
  size_t lo = 0, hi = beats.size();
  while (lo < hi) { size_t mid = (lo + hi) / 2; if (beats[mid].time < songTime) lo = mid + 1; else hi = mid; }
  size_t i = lo ? lo - 1 : 0;
  const double len = i + 1 < beats.size() ? beats[i + 1].time - beats[i].time : 0.5;
  const double phase = len > 0 ? (songTime - beats[i].time) / len : 0;
  if (phase < 0 || phase > 1) return 0;
  return float(std::max(0.0, std::min(1.0, 1 - phase * 1.6)));
}

void Renderer::lightingEvent(const std::string& name) {
  if (name.rfind("flare", 0) == 0) { lightFlash_ = 1; lightFlashDecay_ = name.find("slow") != std::string::npos ? 2.5f : 7.f; blackoutTarget_ = 0; }
  else if (name.rfind("strobe", 0) == 0) { strobeLeft_ = name.find("slow") != std::string::npos ? 1.6f : 0.8f; strobeRate_ = name.find("slow") != std::string::npos ? 6.f : 14.f; blackoutTarget_ = 0; }
  else if (name.rfind("blackout", 0) == 0) blackoutTarget_ = 1;
  else if (name == "bre_start" || name == "bigrockending") { lightFlash_ = 1; lightFlashDecay_ = 3; strobeLeft_ = 2.f; strobeRate_ = 8.f; blackoutTarget_ = 0; }
  else if (name == "bre_end") blackoutTarget_ = 0;
  else if (name.rfind("crowd_", 0) == 0) { /* crowd cues: nothing visual yet */ }
  else {
    blackoutTarget_ = 0;
    if (name == "chorus" || name == "frenzy" || name == "loop_cool" || name == "dischord" || name == "searchlights" || name == "stomp") warmthTarget_ = 0.15f;
    else if (name == "verse" || name == "loop_warm" || name == "harmony" || name == "silhouettes" || name == "sweep") warmthTarget_ = 0.85f;
    else warmthTarget_ = 0.6f;
  }
}

void Renderer::hitEffect(int frets, float quality) {
  static std::mt19937 rng(7);
  std::uniform_real_distribution<float> u(0.f, 1.f);
  auto spawn = [&](int lane, float scale, simd_float4 color) {
    Flame* slot = nullptr;
    for (auto& f : flames_) if (f.life <= 0) { slot = &f; break; }
    if (!slot) { if (flames_.size() >= size_t(MAX_FLAMES)) return; flames_.push_back({}); slot = &flames_.back(); }
    slot->pos = simd_make_float3(laneX(lane), 0.02f, 0.05f);
    slot->scale = scale * settings_.effects * (0.95f + u(rng) * 0.2f);
    slot->life = 1;
    slot->seed = u(rng) * 100;
    slot->flip = u(rng) < 0.5f ? -1.f : 1.f;
    slot->color = color;
  };
  const float fx = settings_.effects;
  const float q = std::max(0.f, std::min(1.f, quality));
  // a tight hit gets a compact bright burst; a hit at the edge of the window a wider, duller one
  const float ringScale = fx * (0.85f + (1 - q) * 0.75f), ringGlow = 0.35f + 0.65f * q, flameScale = 0.8f + 0.3f * q;
  const int sparks = int(std::lround((8 + 16 * q) * fx));
  for (int f = 0; f < 6; f++) {
    if (!(frets & (1 << f))) continue;
    if (f == 5) {
      for (int k = 0; k < 5; k++) { spawn(k, 0.8f * flameScale, colors_[5]); ring(laneX(k), 0, colors_[5] * simd_make_float4(ringGlow, ringGlow, ringGlow, 1), 0.9f * ringScale); }
      burst(0, 0, colors_[5], int(sparks * 1.8f), 1.3f * fx);
      continue;
    }
    spawn(f, flameScale, colors_[f]);
    ring(laneX(f), 0, colors_[f] * simd_make_float4(ringGlow, ringGlow, ringGlow, 1), ringScale);
    burst(laneX(f), 0, colors_[f], sparks, fx * (0.7f + 0.5f * q));
    receptors_[f].flash = 0.6f + 0.4f * q;
  }
}

void Renderer::burst(float x, float z, simd_float4 color, int n, float strength) {
  static std::mt19937 rng(3);
  std::uniform_real_distribution<float> u(0.f, 1.f);
  int spawned = 0;
  for (auto& s : sparks_) {
    if (spawned >= n) break;
    if (s.life > 0) continue;
    s.maxLife = s.life = 0.35f + u(rng) * 0.35f;
    s.pos = simd_make_float3(x + (u(rng) - 0.5f) * 0.35f, 0.25f, z + (u(rng) - 0.5f) * 0.3f);
    const float a = u(rng) * 2 * float(M_PI), sp = (1.f + u(rng) * 2.2f) * strength;
    s.vel = simd_make_float3(cosf(a) * sp, 2.5f + u(rng) * 5 * strength, sinf(a) * sp * 0.6f + 1.2f);
    const float k = u(rng) * 0.6f;
    simd_float3 warm = simd_make_float3(1.f, 0.88f, 0.55f);
    s.col = simd_mix(simd_make_float3(color.x, color.y, color.z), warm, simd_make_float3(k, k, k)) * 1.6f;
    spawned++;
  }
}

void Renderer::ring(float x, float z, simd_float4 color, float scale) {
  Ring* slot = nullptr;
  for (auto& r : rings_) if (r.life <= 0) { slot = &r; break; }
  if (!slot) slot = &rings_[0];
  slot->pos = simd_make_float3(x, 0.03f, z);
  slot->life = 1;
  slot->scale = scale;
  slot->color = color * simd_make_float4(1.1f, 1.1f, 1.1f, 1);
}

void Renderer::setBackgroundImage(id<MTLTexture> tex) { bgImage_ = tex; }

void Renderer::missEffect() {
  for (auto& r : receptors_) r.miss = 1;
  if (!settings_.reducedMotion) shake_ = std::max(shake_, 0.04f);
}
void Renderer::starPowerActivated() {
  spTarget_ = 1;
  spFlash_ = 1;
  if (!settings_.reducedMotion) sweep_ = 0;
  for (int k = 0; k < 5; k++) burst(laneX(k), 0, rgba(0x9ad0ff), 24, 1.4f);
  if (!settings_.reducedMotion) shake_ = std::max(shake_, 0.32f);
}
void Renderer::starPowerEnded() { spTarget_ = 0; }

void Renderer::update(const FrameInput& in) {
  const float dt = in.dt;
  clock_ += dt;
  const float speed = BASE_SPEED * settings_.noteSpeed;
  sp_ += (spTarget_ - sp_) * std::min(1.f, dt * 5);
  spFlash_ = std::max(0.f, spFlash_ - dt * 2.2f);
  const float ready = in.engine && !in.engine->stats().spActive && in.engine->stats().starPower >= 0.5 ? 1.f : 0.f;
  spReady_ += (ready - spReady_) * std::min(1.f, dt * 4);
  for (int i = 0; i < 5; i++) held_[i] += (((in.heldFrets >> i) & 1) - held_[i]) * std::min(1.f, dt * 14);
  introT_ = std::min(1.f, introT_ + dt / 1.4f);
  shakeT_ += dt;
  shake_ *= expf(-dt * 5.5f);

  // camera
  const float ease = 1 - powf(1 - introT_, 3);
  const float lift = settings_.reducedMotion ? 0 : (1 - ease) * 2.2f;
  simd_float3 shk = simd_make_float3(sinf(shakeT_ * 47) * shake_ * 0.35f, sinf(shakeT_ * 61 + 1) * shake_ * 0.25f, cosf(shakeT_ * 53) * shake_ * 0.15f);
  simd_float3 base = settings_.cameraPreset == 1 ? simd_make_float3(0, 3.9f, 4.4f) : settings_.cameraPreset == 2 ? simd_make_float3(0, 6.0f, 6.2f) : simd_make_float3(0, 4.6f, 5.4f);
  simd_float3 look = settings_.cameraPreset == 1 ? simd_make_float3(0, 0.3f, -8.0f) : settings_.cameraPreset == 2 ? simd_make_float3(0, 0.0f, -9.5f) : simd_make_float3(0, 0.3f, -8.5f);
  simd_float3 eye = simd_make_float3(base.x + shk.x, base.y + lift + shk.y + sp_ * 0.15f, base.z + (1 - ease) * 1.5f + shk.z);
  simd_float3 at = simd_make_float3(look.x, look.y + shk.y * 0.5f, look.z);
  const float aspect = float(width_) / float(height_);
  const float fov = (aspect < 1.2f ? 68.f : 54.f) * float(M_PI) / 180.f;
  simd_float4x4 vp = simd_mul(perspective(fov, aspect, 0.1f, 80.f), lookAt(eye, at, simd_make_float3(0, 1, 0)));

  dispatch_semaphore_wait(inflight_, DISPATCH_TIME_FOREVER);
  frame_ = (frame_ + 1) % kFrames;
  auto* u = static_cast<FrameUniforms*>(uniforms_[frame_].contents);
  u->viewProj = vp;
  u->cameraPos = eye;
  u->time = clock_;
  u->scroll = float(in.songTime) * speed;
  u->starPower = sp_;
  u->flash = spFlash_ * 0.7f;
  u->beat = beatPulse(in.songTime);
  u->held = simd_make_float4(held_[0], held_[1], held_[2], held_[3]);
  u->heldExtra = simd_make_float4(held_[4], 0, 0, 0);
  for (int i = 0; i < 5; i++) u->laneColors[i] = colors_[i];
  u->highwayWidth = HIGHWAY_W;
  u->highwayLen = HIGHWAY_LEN;
  u->laneSign = settings_.leftHanded ? -1.f : 1.f;
  u->pad0 = aspect;
  whammySmooth_ += (std::max(0.f, std::min(1.f, in.whammy)) - whammySmooth_) * std::min(1.f, dt * (in.whammy > whammySmooth_ ? 9.f : 5.f));
  u->whammy = whammySmooth_;
  u->bgAspect = bgImage_ ? float(bgImage_.width) / float(std::max<NSUInteger>(1, bgImage_.height)) : 1.6f;
  u->bgMode = float(bgMode_ == 1 && bgImage_ ? 1 : bgMode_ == 2 ? 2 : 0);
  lightFlash_ = std::max(0.f, lightFlash_ - dt * lightFlashDecay_);
  blackout_ += (blackoutTarget_ - blackout_) * std::min(1.f, dt * 6);
  warmth_ += (warmthTarget_ - warmth_) * std::min(1.f, dt * 1.5f);
  float strobe = 0;
  if (strobeLeft_ > 0) { strobeLeft_ -= dt; strobePhase_ += dt * strobeRate_; strobe = fmodf(strobePhase_, 1.f) < 0.5f ? 1.f : 0.f; }
  if (settings_.reducedMotion) { strobe = 0; lightFlash_ = std::min(lightFlash_, 0.3f); }
  u->lighting = simd_make_float4(lightFlash_, blackout_, warmth_, strobe);

  // ---- flat geometry: rails, strike line, beat lines
  auto* flat = static_cast<FlatVertex*>(flatBuf_[frame_].contents);
  uint32_t fv = 0;
  auto quad = [&](float x0, float x1, float z0, float z1, float y, simd_float4 c) {
    if (fv + 6 > uint32_t(MAX_FLAT)) return;
    flat[fv++] = {{x0, y, z0}, c}; flat[fv++] = {{x1, y, z0}, c}; flat[fv++] = {{x1, y, z1}, c};
    flat[fv++] = {{x0, y, z0}, c}; flat[fv++] = {{x1, y, z1}, c}; flat[fv++] = {{x0, y, z1}, c};
  };
  const float readyPulse = 1 + spReady_ * (0.35f + 0.35f * sinf(clock_ * 6));
  simd_float4 railCol = simd_mix(rgba(0xffd335), rgba(0x9ad0ff), simd_make_float4(sp_, sp_, sp_, 0));
  railCol.w = 1;
  const float railI = (0.8f + sp_ * 0.9f) * readyPulse * 2.4f;  // HDR so the rails bloom like the web's emissive rails + glow strips
  const simd_float4 railBright = railCol * simd_make_float4(railI, railI, railI, 1);
  const float hw = HIGHWAY_W / 2;
  for (float s : {-1.f, 1.f}) {
    quad(s * (hw + 0.04f) - 0.03f, s * (hw + 0.04f) + 0.03f, NEAR_Z, -HIGHWAY_LEN, 0.03f, railBright);
    simd_float4 glow = railCol * simd_make_float4(1, 1, 1, 0) + simd_make_float4(0, 0, 0, (0.09f + sp_ * 0.12f) * readyPulse);
    quad(s * (hw + 0.04f) - 0.22f, s * (hw + 0.04f) + 0.22f, NEAR_Z, -HIGHWAY_LEN, 0.012f, glow);
  }
  quad(-hw, hw, 0.03f, -0.03f, 0.015f, simd_make_float4(0.9f, 0.9f, 0.88f, 0.6f));
  if (chart_) {
    const double tMin = in.songTime - NEAR_Z / speed, tMax = in.songTime + HIGHWAY_LEN / speed;
    const auto& beats = chart_->beats;
    size_t lo = 0, hi = beats.size();
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (beats[mid].time < tMin) lo = mid + 1; else hi = mid; }
    for (size_t i = lo; i < beats.size() && beats[i].time <= tMax; i++) {
      const float z = -float(beats[i].time - in.songTime) * speed;
      if (beats[i].measure) quad(-hw, hw, z + 0.03f, z - 0.03f, 0.011f, simd_make_float4(0.5f, 0.5f, 0.55f, 0.42f));
      else quad(-hw, hw, z + 0.015f, z - 0.015f, 0.01f, simd_make_float4(0.3f, 0.3f, 0.33f, 0.18f));
    }
  }
  flatVertCount_ = fv;

  // ---- notes
  auto* inst = static_cast<GemInstance*>(instBuf_[frame_].contents);
  auto* trails = static_cast<TrailInstance*>(trailBuf_[frame_].contents);
  uint32_t ni = 0, ti = 0;
  std::vector<GemInstance> body, bodyDim, starI, starDim, hopo, tap, tapRing, open, openDim, openHopo;
  if (chart_ && track_) {
    const double tMin = in.songTime - NEAR_Z / speed, tMax = in.songTime + HIGHWAY_LEN / speed;
    const auto& notes = track_->notes;
    const auto* state = in.engine ? &in.engine->state() : nullptr;
    size_t lo = 0, hi = notes.size();
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (notes[mid].time < tMin) lo = mid + 1; else hi = mid; }
    // include earlier notes whose sustain still reaches the window
    size_t start = lo;
    for (size_t j = lo, back = 0; j > 0 && back < 200; j--, back++) if (notes[j - 1].endTime >= tMin) start = j - 1;
    for (size_t i = start; i < notes.size() && notes[i].time <= tMax; i++) {
      const ChartNote& note = notes[i];
      const NoteState st = state ? (*state)[i] : NoteState::Pending;
      if (st == NoteState::Skipped) continue;
      const float z = -float(note.time - in.songTime) * speed;
      const bool isSp = note.spPhrase >= 0;
      for (int f = 0; f < 6; f++) {
        if (note.lengths[f] <= 0) continue;
        const float endZ = -float(note.endTimes[f] - in.songTime) * speed;
        if (endZ > NEAR_Z) continue;
        float startZ = z;
        float active = 0, dropped = 0;
        if (st == NoteState::Hit) {
          const bool held = in.engine ? (in.engine->sustainHeld()[i] & (1 << f)) != 0 : true;
          const bool drp = in.engine ? (in.engine->sustainDropped()[i] & (1 << f)) != 0 : false;
          if (held) { startZ = 0; active = 1; }
          else if (drp) { startZ = std::min(0.f, z); dropped = 1; }
          else continue;
          if (startZ <= endZ) continue;
        } else if (st == NoteState::Missed) dropped = 1;
        if (ti >= uint32_t(MAX_TRAILS)) break;
        TrailInstance t;
        const bool openNote = f == 5;
        t.pos = simd_make_float3(openNote ? 0 : laneX(f), 0.04f, (startZ + endZ) / 2);
        t.length = startZ - endZ;
        t.width = openNote ? HIGHWAY_W * 0.8f : 0.46f;
        t.active = active;
        t.dropped = dropped;
        t.sp = sp_;
        simd_float4 c = colors_[f];
        if (isSp && dropped < 0.5f) c = simd_mix(c, simd_make_float4(1, 1, 1, 1), simd_make_float4(0.12f, 0.12f, 0.12f, 0));
        t.color = c;
        trails[ti++] = t;
      }
      if (st == NoteState::Hit || z > NEAR_Z) continue;
      const bool dim = st == NoteState::Missed;
      const float nearScale = 1 + std::max(0.f, 1 - fabsf(z) / 1.2f) * 0.06f;
      auto tint = [&](int f) {
        simd_float4 c = colors_[f];
        if (dim) return c * simd_make_float4(0.22f, 0.22f, 0.22f, 1);
        if (isSp) c = simd_mix(c, simd_make_float4(1, 1, 1, 1), simd_make_float4(0.12f, 0.12f, 0.12f, 0));
        return c;
      };
      if (note.frets & kOpenBit) {
        simd_float4 c = tint(5); c.w = dim ? 0.f : 0.6f;
        (dim ? openDim : open).push_back({translateScale(0, 0, z, 1, 1), c});
        if (!dim && note.type != NoteType::Strum) openHopo.push_back({translateScale(0, 0, z, 1, 1), simd_make_float4(1, 1, 1, 0.5f)});
      }
      for (int f = 0; f < 5; f++) {
        if (!(note.frets & (1 << f))) continue;
        const float x = laneX(f);
        simd_float4 c = tint(f); c.w = 0;
        auto m = translateScale(x, 0, z, dim ? 1 : nearScale, dim ? 1 : nearScale);
        if (dim) { (isSp ? starDim : bodyDim).push_back({m, c}); continue; }
        (isSp ? starI : body).push_back({m, c});
        const float capY = isSp ? 0.08f : 0.f;
        if (note.type == NoteType::Hopo) hopo.push_back({translateScale(x, capY, z, 1, 1), simd_make_float4(1, 1, 1, 0.25f)});
        else if (note.type == NoteType::Tap) {
          tap.push_back({translateScale(x, capY, z, 1, 1), simd_make_float4(1, 1, 1, 0)});
          tapRing.push_back({translateScale(x, capY, z, 1, 1), simd_make_float4(1, 1, 1, 0.6f)});
        }
      }
    }
  }
  trailCount_ = ti;
  // receptors
  std::vector<GemInstance> recBase, recRing, recDisc;
  for (int f = 0; f < 5; f++) {
    Receptor& r = receptors_[f];
    const bool pressed = (in.heldFrets >> f) & 1;
    r.press += ((pressed ? 1.f : 0.f) - r.press) * std::min(1.f, dt * 22);
    r.flash = std::max(0.f, r.flash - dt * 6);
    r.miss = std::max(0.f, r.miss - dt * 4);
    const float y = -0.045f * r.press;
    const float x = laneX(f);
    simd_float4 c = colors_[f];
    simd_float4 red = rgba(0xff3020);
    simd_float4 ringC = simd_mix(c, red, simd_make_float4(r.miss * 0.9f, r.miss * 0.9f, r.miss * 0.9f, 0));
    ringC.w = 0.4f + r.press * 0.4f + r.flash * 1.0f + sp_ * 0.2f;
    simd_float4 discC = simd_mix(c, red, simd_make_float4(r.miss * 0.8f, r.miss * 0.8f, r.miss * 0.8f, 0)) * simd_make_float4(0.5f, 0.5f, 0.5f, 1);
    discC.w = 0.05f + r.press * 0.5f + r.flash * 0.9f + r.miss * 0.5f;
    recBase.push_back({translateScale(x, y, 0, 1, 1), simd_make_float4(1, 1, 1, 0)});
    recRing.push_back({translateScale(x, y, 0, 1, 1), ringC});
    recDisc.push_back({translateScale(x, y, 0, 1, 1), discC});
  }
  auto put = [&](std::vector<GemInstance>& v, InstRange& r) {
    r.offset = ni;
    r.count = uint32_t(std::min<size_t>(v.size(), size_t(MAX_INST) - ni));
    for (uint32_t k = 0; k < r.count; k++) inst[ni++] = v[k];
  };
  put(body, rGemBody_); put(bodyDim, rGemDim_); put(starI, rStar_); put(starDim, rStarDim_); put(hopo, rHopo_); put(tap, rTap_); put(tapRing, rTapRing_);
  put(open, rOpen_); put(openDim, rOpenDim_); put(openHopo, rOpenHopo_); put(recBase, rRecBase_); put(recRing, rRecRing_); put(recDisc, rRecDisc_);

  // flames
  auto* fl = static_cast<FlameInstance*>(flameBuf_[frame_].contents);
  uint32_t fc = 0;
  for (auto& f : flames_) {
    if (f.life <= 0) continue;
    f.life -= dt * 2.4f;
    if (f.life <= 0) continue;
    if (fc >= uint32_t(MAX_FLAMES)) break;
    fl[fc++] = {f.pos, f.scale, f.life, f.seed, f.flip, 0, f.color};
  }
  flameCount_ = fc;

  // sparks (gravity, bounce, fade)
  auto* spk = static_cast<SparkInstance*>(sparkBuf_[frame_].contents);
  uint32_t sc = 0;
  for (auto& s : sparks_) {
    if (s.life <= 0) continue;
    s.life -= dt;
    if (s.life <= 0) continue;
    s.vel.y -= 16 * dt;
    s.pos += s.vel * dt;
    if (s.pos.y < 0.02f) { s.pos.y = 0.02f; s.vel.y *= -0.35f; s.vel.x *= 0.7f; }
    s.col *= simd_make_float3(powf(0.97f, dt * 60), powf(0.96f, dt * 60), powf(0.95f, dt * 60));
    const float f = s.life / s.maxLife;
    const float k = f < 0.25f ? f / 0.25f : 1.f;
    if (sc >= uint32_t(MAX_SPARKS)) break;
    spk[sc++] = {s.pos, 0.11f, simd_make_float4(s.col.x * k, s.col.y * k, s.col.z * k, 1)};
  }
  sparkCount_ = sc;
  auto* rg = static_cast<RingInstance*>(ringBuf_[frame_].contents);
  uint32_t rc = 0;
  for (auto& r : rings_) {
    if (r.life <= 0) continue;
    r.life -= dt * 3.5f;
    if (r.life <= 0) continue;
    const float t = 1 - r.life, sz = r.scale * (0.9f + t * 2.4f);
    if (rc >= uint32_t(MAX_RINGS)) break;
    rg[rc++] = {r.pos, sz, sz * 0.75f, r.life * r.life, {0, 0}, r.color};
  }
  ringCount_ = rc;
  // lane lights (per held/flashing lane) and the strike-line glow
  auto* gl = static_cast<RingInstance*>(glowBuf_[frame_].contents);
  uint32_t gc = 0;
  for (int f = 0; f < 5; f++) {
    const float op = receptors_[f].press * 0.14f + receptors_[f].flash * 0.12f;
    if (op <= 0.002f || gc >= uint32_t(MAX_GLOWS)) continue;
    gl[gc++] = {simd_make_float3(laneX(f), 0.008f, -3.3f), LANE_W * 1.1f, 7.f, op, {1, 0}, colors_[f]};
  }
  if (gc < uint32_t(MAX_GLOWS)) gl[gc++] = {simd_make_float3(0, 0.005f, 0.15f), HIGHWAY_W, 1.6f, 0.04f + 0.05f * u->beat + 0.1f * sp_, {0, 0}, simd_make_float4(1, 1, 1, 1)};
  if (sweep_ >= 0) {
    sweep_ += dt / 0.55f;
    if (sweep_ >= 1) sweep_ = -1;
    else if (gc < uint32_t(MAX_GLOWS)) {
      const float z = 0.5f - sweep_ * (HIGHWAY_LEN + 1.f);
      gl[gc++] = {simd_make_float3(0, 0.02f, z), HIGHWAY_W * 1.15f, 3.2f, (1 - sweep_) * 0.75f, {2, 0}, simd_make_float4(0.75f, 0.9f, 1.6f, 1)};
    }
  }
  glowCount_ = gc;
}

void Renderer::draw(id<MTLCommandBuffer> cmd, id<MTLTexture> target) {
  ensureTargets();
  dispatch_semaphore_t sem = inflight_;
  static const bool gpuLog = getenv("GC_CLOCKLOG") != nullptr;
  [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
    if (gpuLog) { const double gpu = cb.GPUEndTime - cb.GPUStartTime, sched = cb.GPUStartTime - cb.kernelStartTime; if (gpu > 0.03 || sched > 0.05) fprintf(stderr, "slow gpu frame: gpu %.1f ms, queued %.1f ms, status %ld\n", gpu * 1000, sched * 1000, (long)cb.status); }
    dispatch_semaphore_signal(sem);
  }];
  // ---- scene pass (HDR)
  MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = msaaTex_;
  rp.colorAttachments[0].resolveTexture = sceneTex_;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.015, 0.012, 1);
  rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
  rp.depthAttachment.texture = depthTex_;
  rp.depthAttachment.loadAction = MTLLoadActionClear;
  rp.depthAttachment.storeAction = MTLStoreActionDontCare;
  rp.depthAttachment.clearDepth = 1.0;
  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
  [enc setFragmentBuffer:uniforms_[frame_] offset:0 atIndex:2];
  [enc setVertexBuffer:uniforms_[frame_] offset:0 atIndex:2];
  // background
  const bool useImage = bgMode_ == 1 && bgImage_;
  [enc setRenderPipelineState:useImage ? bgImgPso_ : bgMode_ == 2 ? bgPlainPso_ : bgPso_];
  if (useImage) [enc setFragmentTexture:bgImage_ atIndex:0];
  [enc setDepthStencilState:depthNone_];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  // highway
  [enc setRenderPipelineState:highwayPso_];
  [enc setDepthStencilState:depthWrite_];
  [enc setVertexBuffer:highwayPos_ offset:0 atIndex:0];
  [enc setVertexBuffer:highwayUv_ offset:0 atIndex:1];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  // gem reflections in the board (mirrored instances, additive, no depth so the board does not occlude them)
  {
    [enc setRenderPipelineState:litReflPso_];
    [enc setDepthStencilState:depthNone_];
    [enc setCullMode:MTLCullModeNone];
    const float refl = settings_.reflections * 0.55f;
    auto drawRefl = [&](const Mesh& m, const InstRange& r, LitMaterial mat) {
      if (!r.count || !m.count || refl <= 0.01f) return;
      mat.mirror = 1; mat.reflect = refl;
      [enc setVertexBuffer:m.pos offset:0 atIndex:0];
      [enc setVertexBuffer:m.normal offset:0 atIndex:1];
      [enc setVertexBuffer:m.tint offset:0 atIndex:3];
      [enc setVertexBuffer:instBuf_[frame_] offset:r.offset * sizeof(GemInstance) atIndex:4];
      [enc setVertexBytes:&mat length:sizeof mat atIndex:5];
      [enc setFragmentBytes:&mat length:sizeof mat atIndex:5];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:m.count instanceCount:r.count];
    };
    const LitMaterial gemR{0.32f, 0.15f, 1.f, settings_.reflections, 0, 0, 0, 0};
    drawRefl(gemBody_, rGemBody_, gemR); drawRefl(starGem_, rStar_, gemR); drawRefl(openBar_, rOpen_, gemR);
  }
  // flat (rails, lines)
  if (flatVertCount_) {
    [enc setRenderPipelineState:flatPso_];
    [enc setDepthStencilState:depthTest_];
    [enc setVertexBuffer:flatBuf_[frame_] offset:0 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:flatVertCount_];
  }
  // trails
  if (trailCount_) {
    [enc setRenderPipelineState:trailPso_];
    [enc setDepthStencilState:depthTest_];
    [enc setVertexBuffer:trailBuf_[frame_] offset:0 atIndex:4];
    [enc setFragmentBuffer:trailBuf_[frame_] offset:0 atIndex:4];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:2 * (64 + 1) instanceCount:trailCount_];  // matches TRAIL_SEGMENTS
  }
  // hit rings (flat on the board)
  if (ringCount_) {
    [enc setRenderPipelineState:ringPso_];
    [enc setDepthStencilState:depthTest_];
    [enc setVertexBuffer:ringBuf_[frame_] offset:0 atIndex:4];
    [enc setFragmentBuffer:ringBuf_[frame_] offset:0 atIndex:4];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:ringCount_];
  }
  // soft glows (lane lights, strike glow)
  if (glowCount_) {
    [enc setRenderPipelineState:glowPso_];
    [enc setDepthStencilState:depthTest_];
    [enc setVertexBuffer:glowBuf_[frame_] offset:0 atIndex:4];
    [enc setFragmentBuffer:glowBuf_[frame_] offset:0 atIndex:4];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:glowCount_];
  }
  // lit instanced meshes (materials mirror the web build's MeshPhysical/MeshStandard settings)
  [enc setRenderPipelineState:litPso_];
  [enc setDepthStencilState:depthWrite_];
  [enc setCullMode:MTLCullModeNone];
  auto drawMesh = [&](const Mesh& m, const InstRange& r, LitMaterial mat) {
    if (!r.count || !m.count) return;
    [enc setVertexBuffer:m.pos offset:0 atIndex:0];
    [enc setVertexBuffer:m.normal offset:0 atIndex:1];
    [enc setVertexBuffer:m.tint offset:0 atIndex:3];
    [enc setVertexBuffer:instBuf_[frame_] offset:r.offset * sizeof(GemInstance) atIndex:4];
    [enc setVertexBytes:&mat length:sizeof mat atIndex:5];
    [enc setFragmentBytes:&mat length:sizeof mat atIndex:5];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:m.count instanceCount:r.count];
  };
  static const int shadeDbg = getenv("GC_SHADE") ? atoi(getenv("GC_SHADE")) : 0;  // 1: no clearcoat, 2: no env, 3: neither
  const float env = (shadeDbg & 2) ? 0.f : settings_.reflections;
  const float ccOn = (shadeDbg & 1) ? 0.f : 1.f;
  const LitMaterial gem{0.32f, 0.15f, ccOn, env}, gemDim{0.8f, 0.1f, 0.f, env * 0.5f}, cap{0.2f, 0.f, ccOn, env}, tapM{0.25f, 0.f, ccOn, env};
  const LitMaterial recBase{0.5f, 0.6f, 0.f, env * 2.f}, recRing{0.3f, 0.2f, 0.f, env}, recDisc{0.3f, 0.f, ccOn, env}, openM{0.3f, 0.f, 0.8f * ccOn, env}, plain{0.9f, 0.f, 0.f, 0.f};
  drawMesh(receptorBase_, rRecBase_, recBase); drawMesh(receptorRing_, rRecRing_, recRing); drawMesh(receptorDisc_, rRecDisc_, recDisc);
  drawMesh(gemBody_, rGemBody_, gem); drawMesh(gemBody_, rGemDim_, gemDim); drawMesh(starGem_, rStar_, gem); drawMesh(starGem_, rStarDim_, gemDim);
  drawMesh(hopoCap_, rHopo_, cap); drawMesh(tapCap_, rTap_, tapM); drawMesh(tapRing_, rTapRing_, cap);
  drawMesh(openBar_, rOpen_, openM); drawMesh(openBar_, rOpenDim_, gemDim); drawMesh(openHopo_, rOpenHopo_, plain);
  // flames
  if (flameCount_) {
    [enc setRenderPipelineState:flamePso_];
    [enc setDepthStencilState:depthTest_];
    [enc setVertexBuffer:flameBuf_[frame_] offset:0 atIndex:4];
    [enc setFragmentBuffer:flameBuf_[frame_] offset:0 atIndex:4];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:flameCount_];
  }
  // sparks
  if (sparkCount_) {
    [enc setRenderPipelineState:sparkPso_];
    [enc setDepthStencilState:depthTest_];
    [enc setVertexBuffer:sparkBuf_[frame_] offset:0 atIndex:4];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:sparkCount_];
  }
  [enc endEncoding];

  // ---- bloom
  PostParams pp{};
  pp.threshold = 0.85f;
  pp.strength = settings_.bloom;
  pp.saturation = settings_.saturation;
  pp.contrast = settings_.contrast;
  pp.exposure = settings_.exposure;
  pp.tone = float(settings_.toneMapping);
  auto post = [&](id<MTLRenderPipelineState> pso, id<MTLTexture> dst, id<MTLTexture> src0, id<MTLTexture> src1, PostParams p) {
    MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
    d.colorAttachments[0].texture = dst;
    d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    d.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:d];
    [e setRenderPipelineState:pso];
    [e setFragmentTexture:src0 atIndex:0];
    if (src1) [e setFragmentTexture:src1 atIndex:1];
    [e setFragmentBytes:&p length:sizeof p atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
  };
  if (settings_.bloom > 0) {
    PostParams br = pp;
    br.texel = simd_make_float2(1.f / sceneTex_.width, 1.f / sceneTex_.height);
    post(brightPso_, brightTex_, sceneTex_, nil, br);
    PostParams b = pp;
    b.texel = simd_make_float2(1.f / blurA_.width, 1.f / blurA_.height);
    b.dir = simd_make_float2(1, 0);
    post(blurPso_, blurA_, brightTex_, nil, b);
    b.dir = simd_make_float2(0, 1);
    post(blurPso_, blurB_, blurA_, nil, b);
    b.dir = simd_make_float2(1, 0);
    post(blurPso_, blurA_, blurB_, nil, b);
    b.dir = simd_make_float2(0, 1);
    post(blurPso_, blurB_, blurA_, nil, b);
    // wide scale (1/8 res) for the soft halo around bright things
    PostParams w = pp;
    w.texel = simd_make_float2(1.f / blurC_.width, 1.f / blurC_.height);
    w.dir = simd_make_float2(1, 0);
    post(blurPso_, blurC_, blurB_, nil, w);
    w.dir = simd_make_float2(0, 1);
    post(blurPso_, blurD_, blurC_, nil, w);
    w.dir = simd_make_float2(1, 0);
    post(blurPso_, blurC_, blurD_, nil, w);
    w.dir = simd_make_float2(0, 1);
    post(blurPso_, blurD_, blurC_, nil, w);
  }
  {
    MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
    d.colorAttachments[0].texture = target;
    d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    d.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:d];
    PostParams c = pp;
    if (settings_.bloom <= 0) c.strength = 0;
    [e setRenderPipelineState:compositePso_];
    [e setFragmentTexture:sceneTex_ atIndex:0];
    [e setFragmentTexture:settings_.bloom > 0 ? blurB_ : sceneTex_ atIndex:1];
    [e setFragmentTexture:settings_.bloom > 0 ? blurD_ : sceneTex_ atIndex:2];
    [e setFragmentBytes:&c length:sizeof c atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
  }
}

}  // namespace gc::render

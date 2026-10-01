// Shared between C++ and Metal shaders.
#pragma once
#include <simd/simd.h>

namespace gc::shader {

struct FrameUniforms {
  simd_float4x4 viewProj;
  simd_float3 cameraPos;
  float time;
  float scroll;      // highway scroll in world units
  float starPower;   // 0..1
  float flash;
  float beat;
  simd_float4 held;  // per-lane held amount (lanes 0..3), lane 4 in heldExtra.x
  simd_float4 heldExtra;
  simd_float4 laneColors[5];
  float highwayWidth;
  float highwayLen;
  float laneSign;
  float pad0;        // viewport aspect
  float whammy;      // 0..1 sustain wobble
  float bgAspect;    // background image aspect (w/h)
  float bgMode;      // 0 stage lights, 1 song image, 2 plain
  float pad3;
  simd_float4 lighting;  // x flash, y blackout, z warmth (1 warm .. 0 cool), w strobe
};

struct SparkInstance {
  simd_float3 pos;
  float size;
  simd_float4 color;
};

struct RingInstance {
  simd_float3 pos;
  float scaleX;
  float scaleZ;
  float alpha;
  simd_float2 pad;
  simd_float4 color;
};

struct LitMaterial {
  float roughness;
  float metalness;
  float clearcoat;
  float envIntensity;
  float mirror;      // 1 = draw mirrored below the board as a reflection
  float reflect;     // reflection strength
  float pad0, pad1;
};

struct GemInstance {
  simd_float4x4 model;
  simd_float4 color;   // rgb + emissive boost in w
};

struct TrailInstance {
  simd_float3 pos;     // x, y, z-centre
  float length;
  float width;
  float active;
  float dropped;
  float sp;
  simd_float4 color;
};

struct FlatVertex {
  simd_float3 pos;
  simd_float4 color;
};

struct FlameInstance {
  simd_float3 pos;
  float scale;
  float life;
  float seed;
  float flip;
  float pad;
  simd_float4 color;
};

struct PostParams {
  float threshold;
  float strength;
  float saturation;
  float contrast;
  simd_float2 texel;
  simd_float2 dir;
  float exposure;
  float tone;
  simd_float2 pad;
};

}  // namespace gc::shader

// Metal renderer for the note highway.
#pragma once
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <string>
#include <vector>
#include "core/engine.h"
#include "core/types.h"

namespace gc::render {

struct RenderSettings {
  float noteSpeed = 1.f;
  bool leftHanded = false;
  float exposure = 1.f;
  float saturation = 1.15f;
  float contrast = 1.05f;
  int toneMapping = 0;     // 0 none, 1 neutral, 2 aces
  float bloom = 0.22f;     // 0 = off
  float effects = 1.f;
  bool reducedMotion = false;
  float reflections = 0.4f;  // environment reflection intensity on gems
  float renderScale = 1.f;   // internal resolution relative to the drawable
  int cameraPreset = 0;    // 0 classic, 1 close, 2 high
};

struct FrameInput {
  double songTime = 0;
  float dt = 0;
  int heldFrets = 0;
  float whammy = 0;
  const GameEngine* engine = nullptr;
};

class Renderer {
 public:
  Renderer(id<MTLDevice> device);
  bool init(const std::string& metallibPath, std::string* error);
  static void preload(id<MTLDevice> device, const std::string& metallibPath);  // builds the pipeline cache off the main thread
  void setChart(const Chart* chart, const Track* track);
  void resize(int width, int height);
  void update(const FrameInput& in);
  void draw(id<MTLCommandBuffer> cmd, id<MTLTexture> target);
  RenderSettings& settings() { return settings_; }

  // effects
  void hitEffect(int frets, float quality = 1.f);  // quality 1 = perfect hit, 0 = edge of the window
  void lightingEvent(const std::string& name);     // chart venue cue (flare_fast, strobe_slow, blackout_fast, verse, chorus, ...)
  void missEffect();
  void setBackgroundImage(id<MTLTexture> tex);  // nil = none
  void setBackgroundMode(int mode) { bgMode_ = mode; }  // 0 stage, 1 song image, 2 plain
  void starPowerActivated();
  void starPowerEnded();

  float laneX(int fret) const { return float(fret - 2) * (settings_.leftHanded ? -1.f : 1.f); }

 private:
  struct Mesh { id<MTLBuffer> pos, normal, tint; uint32_t count = 0; };
  struct Flame { simd_float3 pos; float scale, life, seed, flip; simd_float4 color; };
  struct Spark { simd_float3 pos, vel; float life = 0, maxLife = 1; simd_float3 col; };
  struct Ring { simd_float3 pos; float life = 0, scale = 1; simd_float4 color; };
  void burst(float x, float z, simd_float4 color, int n, float strength);
  void ring(float x, float z, simd_float4 color, float scale);
  Mesh upload(const std::vector<simd_float3>& pos, const std::vector<simd_float3>& nrm, const std::vector<simd_float3>& tint);
  void buildGeometry();
  bool buildPipelinesUnused(id<MTLLibrary> lib, std::string* error);
  void ensureTargets();
  float beatPulse(double songTime) const;

  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  RenderSettings settings_;
  const Chart* chart_ = nullptr;
  const Track* track_ = nullptr;
  int width_ = 1, height_ = 1;  // drawable size
  int targetW_ = 1, targetH_ = 1;  // internal render size (renderScale)
  float clock_ = 0, sp_ = 0, spTarget_ = 0, spFlash_ = 0, spReady_ = 0, introT_ = 0, shake_ = 0, shakeT_ = 0;
  float held_[5] = {0, 0, 0, 0, 0};
  float whammySmooth_ = 0;  // eased whammy amount so the wobble fades in and out
  float sweep_ = -1;        // star power sweep progress (0..1 while running)
  float lightFlash_ = 0, lightFlashDecay_ = 6, blackout_ = 0, blackoutTarget_ = 0, warmth_ = 0.7f, warmthTarget_ = 0.7f, strobeLeft_ = 0, strobeRate_ = 12, strobePhase_ = 0;
  struct Receptor { float press = 0, flash = 0, miss = 0; } receptors_[5];
  std::vector<Flame> flames_;
  std::vector<Spark> sparks_;
  std::vector<Ring> rings_;
  id<MTLTexture> bgImage_;
  int bgMode_ = 0;
  std::vector<simd_float4> colors_;

  // pipelines
  id<MTLRenderPipelineState> litReflPso_;
  id<MTLRenderPipelineState> highwayPso_, litPso_, flatPso_, trailPso_, flamePso_, sparkPso_, ringPso_, glowPso_, bgPso_, bgImgPso_, bgPlainPso_, brightPso_, blurPso_, compositePso_;
  id<MTLDepthStencilState> depthWrite_, depthTest_, depthNone_;
  // geometry
  Mesh gemBody_, starGem_, hopoCap_, tapCap_, tapRing_, openBar_, openHopo_, receptorBase_, receptorRing_, receptorDisc_;
  id<MTLBuffer> highwayPos_, highwayUv_;
  // per-frame buffers (triple buffered)
  static constexpr int kFrames = 3;
  int frame_ = 0;
  dispatch_semaphore_t inflight_;  // CPU waits before reusing a frame's buffers the GPU may still read
  id<MTLBuffer> uniforms_[kFrames], instBuf_[kFrames], flatBuf_[kFrames], trailBuf_[kFrames], flameBuf_[kFrames], sparkBuf_[kFrames], ringBuf_[kFrames], glowBuf_[kFrames];
  struct InstRange { uint32_t offset = 0, count = 0; };
  InstRange rGemBody_, rGemDim_, rStar_, rStarDim_, rHopo_, rTap_, rTapRing_, rOpen_, rOpenDim_, rOpenHopo_, rRecBase_, rRecRing_, rRecDisc_;
  uint32_t flatVertCount_ = 0, trailCount_ = 0, flameCount_ = 0, sparkCount_ = 0, ringCount_ = 0, glowCount_ = 0;
  // render targets
  id<MTLTexture> sceneTex_, msaaTex_, depthTex_, brightTex_, blurA_, blurB_, blurC_, blurD_;
  static constexpr int kSamples = 4;
};

}  // namespace gc::render

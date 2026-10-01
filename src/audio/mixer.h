// Sample-accurate stem mixer on a CoreAudio output unit.
#pragma once
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>
#include "decoder.h"

namespace gc::audio {

class Mixer {
 public:
  Mixer();
  ~Mixer();
  bool start(std::string* error = nullptr);
  void stop();

  // stems (call while stopped or paused; buffers are copied into the mixer)
  int addStem(PcmBuffer buffer);
  int addStem(std::shared_ptr<StreamingStem> stem);  // plays what has been decoded so far
  void clearStems();
  void setStemGain(int stem, float gain, float rampSeconds = 0.02f);
  void setStemDetune(int stem, float cents);  // whammy: pitch offset, drifts then resyncs to the transport when released

  // transport: song time = offset + elapsed * rate (offset may be negative for a lead-in)
  void play(double songOffset, double rate = 1.0);
  void pause();
  bool playing() const { return playing_.load(); }
  double time() const;             // current song time (interpolated between callbacks)
  double outputLatency() const { return outputLatency_; }
  double duration() const;

  // one-shot sound effects (mixed at the SFX gain)
  void playOneShot(std::shared_ptr<const PcmBuffer> buffer, float gain = 1.f);
  int playLoop(std::shared_ptr<const PcmBuffer> buffer, float gain = 0.f);  // seamless loop at the SFX gain; returns an id
  void setLoopGain(int id, float gain);
  void setMusicGain(float g) { musicGain_ = g; }
  void setSfxGain(float g) { sfxGain_ = g; }

 private:
  struct Stem {
    std::shared_ptr<PcmBuffer> buffer;
    std::shared_ptr<StreamingStem> stream;  // null when fully decoded up front
    std::atomic<float> gain{1.f};
    std::atomic<float> detune{0.f};
    float current = 1.f;
    float rampStep = 0.f;
    double drift = 0;  // frames ahead/behind the transport while detuned
  };
  struct OneShot {
    std::shared_ptr<const PcmBuffer> buffer;
    size_t frame = 0;
    float gain = 1.f;
    bool loop = false;
    std::atomic<float> target{1.f};
    OneShot() = default;
    OneShot(std::shared_ptr<const PcmBuffer> b, size_t f, float g, bool l) : buffer(std::move(b)), frame(f), gain(g), loop(l), target(g) {}
    OneShot(OneShot&& o) noexcept : buffer(std::move(o.buffer)), frame(o.frame), gain(o.gain), loop(o.loop), target(o.target.load()) {}
    OneShot& operator=(OneShot&& o) noexcept { buffer = std::move(o.buffer); frame = o.frame; gain = o.gain; loop = o.loop; target = o.target.load(); return *this; }
  };
  std::vector<std::shared_ptr<OneShot>> loops_;
  void render(float* out, uint32_t frames, uint64_t hostTime);
  static int renderThunk(void* self, void* flags, const void* ts, uint32_t bus, uint32_t frames, void* list);

  void* unit_ = nullptr;  // AudioComponentInstance
  double outputRate_ = 48000;
  double outputLatency_ = 0;
  std::vector<std::unique_ptr<Stem>> stems_;
  std::mutex stemMutex_;
  std::vector<OneShot> oneShots_;
  std::mutex sfxMutex_;
  std::atomic<bool> playing_{false};
  std::atomic<double> rate_{1.0};
  std::atomic<double> startOffset_{0};
  std::atomic<double> pausedAt_{0};
  std::atomic<uint64_t> framesRendered_{0};
  // clock anchor published by the render callback (seqlock so readers never see a half-updated pair)
  struct Anchor { uint64_t frames = 0; uint64_t host = 0; };
  Anchor anchor_;
  std::atomic<uint32_t> anchorSeq_{0};
  mutable std::atomic<double> lastTime_{-1e300};
  std::atomic<float> musicGain_{0.9f};
  std::atomic<float> sfxGain_{0.8f};
  double hostToSeconds_ = 1e-9;
};

}  // namespace gc::audio

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <cmath>
#include "mixer.h"

namespace gc::audio {

Mixer::Mixer() {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  hostToSeconds_ = double(tb.numer) / double(tb.denom) * 1e-9;
}

Mixer::~Mixer() { stop(); }

int Mixer::renderThunk(void* self, void* /*flags*/, const void* ts, uint32_t /*bus*/, uint32_t frames, void* list) {
  auto* m = static_cast<Mixer*>(self);
  auto* abl = static_cast<AudioBufferList*>(list);
  auto* out = static_cast<float*>(abl->mBuffers[0].mData);
  m->render(out, frames, static_cast<const AudioTimeStamp*>(ts)->mHostTime);
  return noErr;
}

bool Mixer::start(std::string* error) {
  if (unit_) return true;
  AudioComponentDescription desc{};
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_DefaultOutput;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
  AudioComponentInstance unit = nullptr;
  if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) { if (error) *error = "no default output unit"; return false; }
  AudioStreamBasicDescription fmt{};
  fmt.mSampleRate = 48000;
  UInt32 sz = sizeof fmt;
  AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, &sz);
  outputRate_ = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000;
  fmt.mSampleRate = outputRate_;
  fmt.mFormatID = kAudioFormatLinearPCM;
  fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  fmt.mBitsPerChannel = 32;
  fmt.mChannelsPerFrame = 2;
  fmt.mBytesPerFrame = 8;
  fmt.mFramesPerPacket = 1;
  fmt.mBytesPerPacket = 8;
  if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt) != noErr) { if (error) *error = "cannot set stream format"; return false; }
  AURenderCallbackStruct cb{};
  cb.inputProc = reinterpret_cast<AURenderCallback>(&Mixer::renderThunk);
  cb.inputProcRefCon = this;
  AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
  if (AudioUnitInitialize(unit) != noErr || AudioOutputUnitStart(unit) != noErr) { if (error) *error = "cannot start output unit"; return false; }
  Float64 latency = 0;
  sz = sizeof latency;
  if (AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &sz) == noErr) outputLatency_ = latency;
  unit_ = unit;
  return true;
}

void Mixer::stop() {
  if (!unit_) return;
  auto unit = static_cast<AudioComponentInstance>(unit_);
  AudioOutputUnitStop(unit);
  AudioUnitUninitialize(unit);
  AudioComponentInstanceDispose(unit);
  unit_ = nullptr;
}

int Mixer::addStem(PcmBuffer buffer) {
  std::lock_guard<std::mutex> lock(stemMutex_);
  auto s = std::make_unique<Stem>();
  s->buffer = std::make_shared<PcmBuffer>(std::move(buffer));
  stems_.push_back(std::move(s));
  return int(stems_.size()) - 1;
}
int Mixer::addStem(std::shared_ptr<StreamingStem> stem) {
  std::lock_guard<std::mutex> lock(stemMutex_);
  auto s = std::make_unique<Stem>();
  s->buffer = stem->pcm;
  s->stream = std::move(stem);
  stems_.push_back(std::move(s));
  return int(stems_.size()) - 1;
}

void Mixer::clearStems() {
  std::lock_guard<std::mutex> lock(stemMutex_);
  stems_.clear();
}

void Mixer::setStemGain(int stem, float gain, float /*rampSeconds*/) {
  // lock-free: the stem list only changes on the main thread while nothing plays, and the gain is atomic
  if (stem >= 0 && stem < int(stems_.size())) stems_[stem]->gain = gain;
}

void Mixer::setStemDetune(int stem, float cents) {
  if (stem >= 0 && stem < int(stems_.size())) stems_[stem]->detune = cents;
}

void Mixer::play(double songOffset, double rate) {
  rate_ = rate;
  startOffset_ = songOffset;
  framesRendered_ = 0;
  anchorSeq_.fetch_add(1);
  anchor_ = {0, mach_absolute_time()};
  anchorSeq_.fetch_add(1);
  lastTime_ = -1e300;
  playing_ = true;
}

void Mixer::pause() {
  if (!playing_) return;
  pausedAt_ = time();
  playing_ = false;
}

double Mixer::time() const {
  if (!playing_) return pausedAt_.load();
  Anchor a;
  for (int tries = 0; tries < 64; tries++) {
    const uint32_t s0 = anchorSeq_.load(std::memory_order_acquire);
    a = anchor_;
    const uint32_t s1 = anchorSeq_.load(std::memory_order_acquire);
    if (s0 == s1 && (s0 & 1) == 0) break;
  }
  // the anchor's host time is when the anchored frame reaches the output; the delta may be slightly negative
  const double since = std::max(-0.05, std::min(0.05, double(int64_t(mach_absolute_time()) - int64_t(a.host)) * hostToSeconds_));
  double t = startOffset_.load() + (double(a.frames) / outputRate_ + since) * rate_.load();
  // never step backwards between reads while playing
  const double last = lastTime_.load();
  if (t < last) t = last;
  lastTime_ = t;
  return t;
}

double Mixer::duration() const {
  double d = 0;
  for (const auto& s : stems_) d = std::max(d, s->buffer->duration());
  return d;
}

void Mixer::playOneShot(std::shared_ptr<const PcmBuffer> buffer, float gain) {
  std::lock_guard<std::mutex> lock(sfxMutex_);
  oneShots_.emplace_back(std::move(buffer), 0, gain, false);
}

int Mixer::playLoop(std::shared_ptr<const PcmBuffer> buffer, float gain) {
  std::lock_guard<std::mutex> lock(sfxMutex_);
  loops_.push_back(std::make_shared<OneShot>(std::move(buffer), 0, gain, true));
  return int(loops_.size()) - 1;
}
void Mixer::setLoopGain(int id, float gain) {
  if (id >= 0 && id < int(loops_.size())) loops_[id]->target = gain;
}

void Mixer::render(float* out, uint32_t frames, uint64_t hostTime) {
  std::fill(out, out + frames * 2, 0.f);
  anchorSeq_.fetch_add(1, std::memory_order_release);
  anchor_ = {framesRendered_.load(), hostTime ? hostTime : mach_absolute_time()};
  anchorSeq_.fetch_add(1, std::memory_order_release);
  if (playing_) {
    const double rate = rate_.load();
    const double startOffset = startOffset_.load();
    const uint64_t startFrame = framesRendered_.load();
    const float music = musicGain_.load();
    std::unique_lock<std::mutex> lock(stemMutex_, std::try_to_lock);
    if (lock.owns_lock()) {
      for (auto& stem : stems_) {
        const PcmBuffer& b = *stem->buffer;
        if (b.samples.empty()) continue;
        const size_t avail = stem->stream ? stem->stream->ready.load(std::memory_order_acquire) : b.frames();
        if (avail < 2) continue;
        const double step = (b.sampleRate / outputRate_) * rate;
        const float target = stem->gain.load();
        const double pitch = pow(2.0, stem->detune.load() / 1200.0);
        for (uint32_t i = 0; i < frames; i++) {
          stem->current += (target - stem->current) * 0.002f;
          const double songT = startOffset + double(startFrame + i) / outputRate_ * rate;
          if (songT < 0) continue;
          if (pitch != 1.0) stem->drift += (pitch - 1.0) * step;
          else if (stem->drift != 0) { const double pull = std::min(fabs(stem->drift), 0.005 * step); stem->drift += stem->drift > 0 ? -pull : pull; }  // ~9 cents, inaudible
          const double pos = songT * b.sampleRate + stem->drift;
          if (pos < 0) continue;
          const size_t f0 = size_t(pos);
          if (f0 + 1 >= avail) continue;
          const float frac = float(pos - double(f0));
          for (int c = 0; c < 2; c++) {
            const int sc = std::min(c, b.channels - 1);
            const float a = b.samples[f0 * b.channels + sc];
            const float bb = b.samples[(f0 + 1) * b.channels + sc];
            out[i * 2 + c] += (a + (bb - a) * frac) * stem->current * music;
          }
        }
      }
    }
    framesRendered_ += frames;
  }
  // one-shots
  std::unique_lock<std::mutex> lock(sfxMutex_, std::try_to_lock);
  if (lock.owns_lock()) {
    const float sfx = sfxGain_.load();
    for (auto& os : oneShots_) {
      const PcmBuffer& b = *os.buffer;
      const double step = b.sampleRate / outputRate_;
      for (uint32_t i = 0; i < frames; i++) {
        const double pos = double(os.frame) * step;
        const size_t f0 = size_t(pos);
        if (f0 + 1 >= b.frames()) { os.frame = size_t(-1); break; }
        for (int c = 0; c < 2; c++) {
          const int sc = std::min(c, b.channels - 1);
          out[i * 2 + c] += b.samples[f0 * b.channels + sc] * os.gain * sfx;
        }
        os.frame++;
      }
    }
    oneShots_.erase(std::remove_if(oneShots_.begin(), oneShots_.end(), [](const OneShot& o) { return o.frame == size_t(-1); }), oneShots_.end());
    for (auto& lp : loops_) {
      const PcmBuffer& b = *lp->buffer;
      if (b.frames() < 2) continue;
      const double step = b.sampleRate / outputRate_;
      const float target = lp->target.load();
      for (uint32_t i = 0; i < frames; i++) {
        lp->gain += (target - lp->gain) * 0.0005f;
        if (lp->gain < 0.0005f && target <= 0.f) { lp->frame = (lp->frame + 1) % size_t(double(b.frames()) / step); continue; }
        const double pos = fmod(double(lp->frame) * step, double(b.frames() - 1));
        const size_t f0 = size_t(pos);
        const float frac = float(pos - double(f0));
        for (int c = 0; c < 2; c++) {
          const int sc = std::min(c, b.channels - 1);
          const float a = b.samples[f0 * b.channels + sc], bb = b.samples[(f0 + 1) * b.channels + sc];
          out[i * 2 + c] += (a + (bb - a) * frac) * lp->gain * sfx;
        }
        lp->frame++;
      }
    }
  }
  for (uint32_t i = 0; i < frames * 2; i++) out[i] = std::max(-1.f, std::min(1.f, out[i]));
}

}  // namespace gc::audio

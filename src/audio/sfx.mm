#include "sfx.h"
#include <cmath>
#include <random>

namespace gc::audio {

namespace {
constexpr int SR = 48000;

// RBJ biquad
struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
  void set(int type, double f, double q) {  // 0 lowpass, 1 highpass, 2 bandpass
    const double w = 2 * M_PI * std::min(f, SR * 0.45) / SR, c = cos(w), s = sin(w), al = s / (2 * q);
    double a0;
    if (type == 0) { b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; }
    else if (type == 1) { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; }
    else { b0 = al; b1 = 0; b2 = -al; }
    a0 = 1 + al; a1 = -2 * c; a2 = 1 - al;
    b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0;
  }
  float process(float x) { const double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return float(y); }
};

double expRamp(double t, double t0, double v0, double t1, double v1) {
  if (t <= t0) return v0;
  if (t >= t1) return v1;
  return v0 * pow(v1 / v0, (t - t0) / (t1 - t0));
}
float distort(float x, float amount) { return float(((3 + amount) * x * 20 * (M_PI / 180)) / (M_PI + amount * fabsf(x))); }

struct Osc {
  double phase = 0;
  float next(double freq, int type) {  // 0 saw, 1 square, 2 triangle
    phase += freq / SR;
    if (phase >= 1) phase -= floor(phase);
    if (type == 0) return float(2 * phase - 1);
    if (type == 1) return phase < 0.5 ? 1.f : -1.f;
    return float(phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase);
  }
};

std::shared_ptr<PcmBuffer> buffer(double seconds) {
  auto b = std::make_shared<PcmBuffer>();
  b->sampleRate = SR; b->channels = 1;
  b->samples.assign(size_t(seconds * SR), 0.f);
  return b;
}
std::mt19937 rng(11);
float noise() { return std::uniform_real_distribution<float>(-1.f, 1.f)(rng); }

std::shared_ptr<PcmBuffer> makeMiss(int variant) {
  auto b = buffer(0.22);
  Biquad bp; bp.set(2, 500 + variant * 300, 0.8);
  Osc o;
  for (size_t i = 0; i < b->samples.size(); i++) {
    const double t = double(i) / SR;
    float v = 0;
    if (t < 0.2) v += bp.process(noise()) * float(expRamp(t, 0, 0.5, 0.18, 0.001));
    if (t < 0.16) v += distort(o.next(expRamp(t, 0, 140 + variant * 25, 0.15, 60), 0), 40) * float(expRamp(t, 0, 0.25, 0.15, 0.001));
    b->samples[i] = v;
  }
  return b;
}
std::shared_ptr<PcmBuffer> makeSpOn() {
  auto b = buffer(1.0);
  Biquad lp, hp; hp.set(1, 4000, 0.7);
  Osc o;
  for (size_t i = 0; i < b->samples.size(); i++) {
    const double t = double(i) / SR;
    if (i % 32 == 0) lp.set(0, expRamp(t, 0, 600, 0.5, 6000), 0.9);
    float v = lp.process(o.next(expRamp(t, 0, 220, 0.5, 1760), 0)) * float(t < 0.05 ? expRamp(t, 0, 0.0001, 0.05, 0.35) : expRamp(t, 0.05, 0.35, 0.9, 0.0001));
    if (t < 0.85) v += hp.process(noise()) * float(t < 0.2 ? expRamp(t, 0, 0.0001, 0.2, 0.2) : expRamp(t, 0.2, 0.2, 0.8, 0.0001));
    b->samples[i] = v;
  }
  return b;
}
std::shared_ptr<PcmBuffer> makeSpOff() {
  auto b = buffer(0.5);
  Osc o;
  for (size_t i = 0; i < b->samples.size(); i++) {
    const double t = double(i) / SR;
    b->samples[i] = o.next(expRamp(t, 0, 900, 0.4, 200), 2) * float(expRamp(t, 0, 0.25, 0.45, 0.0001));
  }
  return b;
}
void blipInto(PcmBuffer& b, double at, double freq, double dur, double vol) {
  Osc o;
  for (size_t i = size_t(at * SR); i < b.samples.size(); i++) {
    const double t = double(i) / SR - at;
    if (t > dur + 0.01) break;
    b.samples[i] += o.next(freq, 1) * float(expRamp(t, 0, vol, dur, 0.0001));
  }
}
std::shared_ptr<PcmBuffer> makeBlip(double freq, double dur, double vol) { auto b = buffer(dur + 0.02); blipInto(*b, 0, freq, dur, vol); return b; }
std::shared_ptr<PcmBuffer> makeConfirm() { auto b = buffer(0.2); blipInto(*b, 0, 520, 0.08, 0.2); blipInto(*b, 0.06, 780, 0.12, 0.2); return b; }
std::shared_ptr<PcmBuffer> makeFail() {
  auto b = buffer(1.4);
  for (int k = 0; k < 3; k++) {
    Osc o;
    const double t0 = k * 0.3;
    for (size_t i = size_t(t0 * SR); i < b->samples.size(); i++) {
      const double t = double(i) / SR - t0;
      if (t > 0.75) break;
      b->samples[i] += distort(o.next(expRamp(t, 0, 160 - k * 30, 0.6, 40), 0), 60) * float(expRamp(t, 0, 0.3, 0.7, 0.0001));
    }
  }
  return b;
}
std::shared_ptr<PcmBuffer> makeCrowd() {
  auto b = buffer(2.6);
  Biquad bp; bp.set(2, 1200, 0.3);
  for (size_t i = 0; i < b->samples.size(); i++) {
    const double t = double(i) / SR;
    b->samples[i] = bp.process(noise()) * float(t < 0.4 ? expRamp(t, 0, 0.0001, 0.4, 0.25) : expRamp(t, 0.4, 0.25, 2.5, 0.0001));
  }
  return b;
}
std::shared_ptr<PcmBuffer> makeFanfare() {
  auto b = buffer(1.1);
  const double notes[4] = {523.25, 659.25, 783.99, 1046.5};
  for (int k = 0; k < 4; k++) {
    Osc o1, o2;
    const double t0 = k * 0.11;
    for (size_t i = size_t(t0 * SR); i < b->samples.size(); i++) {
      const double t = double(i) / SR - t0;
      if (t > 0.6) break;
      const float env = float(expRamp(t, 0, 0.22, 0.6, 0.0005));
      b->samples[i] += (o1.next(notes[k], 1) * 0.6f + o2.next(notes[k] * 2.0, 2) * 0.4f) * env;
    }
  }
  return b;
}
std::shared_ptr<PcmBuffer> makeReady() {
  auto b = buffer(0.35);
  Osc o1, o2;
  for (size_t i = 0; i < b->samples.size(); i++) {
    const double t = double(i) / SR;
    b->samples[i] = (o1.next(880, 2) * 0.6f + o2.next(1320, 2) * 0.3f) * float(t < 0.02 ? t / 0.02 : expRamp(t, 0.02, 0.18, 0.33, 0.0005));
  }
  return b;
}
// a 4 s seamless crowd murmur: band-passed noise with slow swells, cross-faded at the loop point
std::shared_ptr<PcmBuffer> makeCrowdBed() {
  const double len = 4.0;
  auto b = buffer(len);
  Biquad bp; bp.set(2, 900, 0.25);
  Biquad lp; lp.set(0, 2600, 0.7);
  const size_t n = b->samples.size();
  for (size_t i = 0; i < n; i++) {
    const double t = double(i) / SR;
    const float swell = 0.7f + 0.3f * float(sin(2 * M_PI * t / len * 2) * 0.5 + sin(2 * M_PI * t / len * 3 + 1.3) * 0.5);
    b->samples[i] = lp.process(bp.process(noise())) * swell * 0.9f;
  }
  const size_t fade = size_t(0.25 * SR);  // cross-fade the tail into the head
  for (size_t i = 0; i < fade; i++) { const float w = float(i) / fade; b->samples[i] = b->samples[i] * w + b->samples[n - fade + i] * (1 - w); }
  b->samples.resize(n - fade);
  return b;
}
}  // namespace

Sfx& Sfx::instance() { static Sfx s; return s; }

void Sfx::start() {
  if (mixer_) return;
  mixer_ = std::make_unique<Mixer>();
  mixer_->start();
  for (int i = 0; i < 3; i++) miss_[i] = makeMiss(i);
  spOn_ = makeSpOn(); spOff_ = makeSpOff();
  move_ = makeBlip(700, 0.05, 0.12); confirm_ = makeConfirm(); back_ = makeBlip(400, 0.1, 0.15);
  fail_ = makeFail(); crowd_ = makeCrowd();
  fanfare_ = makeFanfare(); ready_ = makeReady(); crowdBed_ = makeCrowdBed();
  crowdLoop_ = mixer_->playLoop(crowdBed_, 0.f);
}
void Sfx::playFanfare() { play(fanfare_, 0.9f); play(crowd_, 1.f); }
void Sfx::playStarPowerReady() { play(ready_, 0.8f); }
void Sfx::setCrowdLevel(float level) { if (mixer_ && crowdLoop_ >= 0) mixer_->setLoopGain(crowdLoop_, std::max(0.f, std::min(1.f, level)) * 0.28f); }
void Sfx::setGain(float g) { if (mixer_) mixer_->setSfxGain(g); }
void Sfx::play(const std::shared_ptr<const PcmBuffer>& b, float gain) { if (mixer_ && b) mixer_->playOneShot(b, gain); }
void Sfx::playMiss() { missVariant_ = (missVariant_ + 1 + int(std::uniform_int_distribution<int>(0, 1)(rng))) % 3; play(miss_[missVariant_]); }
void Sfx::playStarPowerActivate() { play(spOn_); }
void Sfx::playStarPowerEnd() { play(spOff_); }
void Sfx::playMenuMove() { play(move_); }
void Sfx::playMenuConfirm() { play(confirm_); }
void Sfx::playMenuBack() { play(back_); }
void Sfx::playFail() { play(fail_); }
void Sfx::playCrowdCheer(float intensity) { play(crowd_, intensity); }

}  // namespace gc::audio

// Synthesized sound effects (GH3 style clank, star power, menu blips, fail, crowd), mixed on a
// dedicated output unit so they work on every screen. Buffers are rendered once at startup.
#pragma once
#include <memory>
#include <vector>
#include "mixer.h"

namespace gc::audio {

class Sfx {
 public:
  static Sfx& instance();
  void start();                 // creates the output unit and renders the buffers
  void setGain(float g);        // sfx * master volume (0 in screenshot mode)
  void playMiss();
  void playStarPowerActivate();
  void playStarPowerEnd();
  void playMenuMove();
  void playMenuConfirm();
  void playMenuBack();
  void playFail();
  void playCrowdCheer(float intensity = 1.f);
  void playFanfare();                 // full combo / new record
  void playStarPowerReady();          // soft chime when the bar reaches half
  void setCrowdLevel(float level);    // 0..1 continuous crowd bed (rock meter / streak)
  Mixer* mixer() { return mixer_.get(); }

 private:
  void play(const std::shared_ptr<const PcmBuffer>& b, float gain = 1.f);
  std::unique_ptr<Mixer> mixer_;
  std::shared_ptr<const PcmBuffer> miss_[3], spOn_, spOff_, move_, confirm_, back_, fail_, crowd_, fanfare_, ready_, crowdBed_;
  int crowdLoop_ = -1;
  int missVariant_ = 0;
};

}  // namespace gc::audio

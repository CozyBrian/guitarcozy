#pragma once
#include <vector>
#include "tempo.h"
#include "types.h"

namespace gc {

struct RawNote { int tick; int fret; int length; };     // fret 0..4, 5 = open
struct RawRange { int tick; int length; };              // length 0 = exact tick only

struct RawTrackData {
  std::vector<RawNote> notes;
  std::vector<RawRange> forced, taps, starPower, solos;
};

struct BuildOptions {
  int hopoThreshold = 0;   // ticks, 0 = default (65 * res / 192)
  int sustainCutoff = 0;   // sustains <= this many ticks are dropped
  double timeOffset = 0;   // seconds added to every time value
};

int defaultHopoThreshold(int resolution);
Track buildTrack(Instrument instrument, Difficulty difficulty, const RawTrackData& raw, const TempoMap& tempo, const BuildOptions& opts = {});

}  // namespace gc

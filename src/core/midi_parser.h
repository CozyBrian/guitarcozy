#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include "types.h"

namespace gc {

struct MidiParseOptions {
  int hopoThreshold = 0;      // ticks (0 = default)
  int sustainCutoff = -1;     // ticks; -1 = default floor(resolution / 3)
  double timeOffset = 0;      // seconds added to every time
  int multiplierNote = 116;   // 116, or 103 for old Rock Band charts
};

// Parses a Guitar Hero / Rock Band / Clone Hero notes.mid. Throws std::runtime_error for non-MIDI data.
Chart parseMidiChart(const std::vector<uint8_t>& data, const MidiParseOptions& opts = {});

}  // namespace gc

// Quick metadata scan of a .chart file for the library: song fields, note counts per track and the
// length, without building tracks (no HOPO resolution, no note objects).
#pragma once
#include <string>
#include <vector>
#include "types.h"

namespace gc {

struct ChartScanTrack { Instrument instrument; Difficulty difficulty; int noteCount; };
struct ChartScan {
  SongMeta meta;
  std::vector<ChartScanTrack> tracks;
  double lengthSeconds = 0;
};

ChartScan scanChartQuick(const std::string& text);

}  // namespace gc

#pragma once
#include <string>
#include "types.h"

namespace gc {

struct ChartParseOptions {
  int hopoThreshold = 0;   // ticks (0 = default)
  int sustainCutoff = 0;   // ticks (0 = keep as charted)
  double timeOffset = 0;   // extra seconds (song.ini delay) on top of [Song] Offset
};

// Parses a Clone Hero / Moonscraper `.chart` file.
Chart parseChart(const std::string& text, const ChartParseOptions& opts = {});

}  // namespace gc

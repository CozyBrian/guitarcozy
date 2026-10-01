#pragma once
#include <string>
#include "types.h"

namespace gc {

// Parses a Clone Hero style song.ini into SongMeta. Unknown keys are kept in `raw`.
SongMeta parseSongIni(const std::string& text);

// HOPO threshold in ticks for a chart of the given resolution, honouring song.ini overrides (0 = default).
int hopoThresholdFor(const SongMeta& meta, int resolution);

}  // namespace gc

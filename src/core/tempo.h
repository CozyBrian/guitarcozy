#pragma once
#include <vector>
#include "types.h"

namespace gc {

// Converts between ticks and seconds using a list of tempo changes.
class TempoMap {
 public:
  TempoMap(int resolution, const std::vector<TempoEvent>& tempos);
  double tickToTime(double tick) const;
  double timeToTick(double time) const;
  double bpmAtTime(double time) const;
  double bpmAtTick(double tick) const;
  int resolution() const { return resolution_; }
  const std::vector<TempoEvent>& tempos() const { return tempos_; }

 private:
  size_t indexByTick(double tick) const;
  size_t indexByTime(double time) const;
  int resolution_;
  std::vector<TempoEvent> tempos_;
};

// Generates beat lines up to endTick from time signatures (quarter-note based).
std::vector<Beat> generateBeats(const TempoMap& tempo, std::vector<TimeSigEvent> timeSigs, int endTick);

}  // namespace gc

#include "tempo.h"
#include <algorithm>

namespace gc {

TempoMap::TempoMap(int resolution, const std::vector<TempoEvent>& in) : resolution_(resolution) {
  std::vector<TempoEvent> sorted = in;
  std::stable_sort(sorted.begin(), sorted.end(), [](const TempoEvent& a, const TempoEvent& b) { return a.tick < b.tick; });
  if (sorted.empty() || sorted.front().tick != 0) {
    TempoEvent first;
    first.tick = 0;
    first.bpm = sorted.empty() ? 120 : sorted.front().bpm;
    sorted.insert(sorted.begin(), first);
  }
  std::vector<TempoEvent> dedup;
  for (const auto& t : sorted) {
    if (!dedup.empty() && dedup.back().tick == t.tick) dedup.back() = t;
    else dedup.push_back(t);
  }
  double time = 0;
  for (size_t i = 0; i < dedup.size(); i++) {
    TempoEvent t = dedup[i];
    if (i > 0) {
      const TempoEvent& prev = tempos_[i - 1];
      time = prev.time + (double(t.tick - prev.tick) / resolution) * (60.0 / prev.bpm);
    }
    t.time = time;
    if (t.bpm <= 0) t.bpm = 120;
    tempos_.push_back(t);
  }
}

size_t TempoMap::indexByTick(double tick) const {
  size_t lo = 0, hi = tempos_.size() - 1;
  while (lo < hi) {
    size_t mid = (lo + hi + 1) / 2;
    if (tempos_[mid].tick <= tick) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

size_t TempoMap::indexByTime(double time) const {
  size_t lo = 0, hi = tempos_.size() - 1;
  while (lo < hi) {
    size_t mid = (lo + hi + 1) / 2;
    if (tempos_[mid].time <= time) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

double TempoMap::tickToTime(double tick) const {
  const TempoEvent& t = tempos_[indexByTick(tick)];
  return t.time + ((tick - t.tick) / resolution_) * (60.0 / t.bpm);
}

double TempoMap::timeToTick(double time) const {
  const TempoEvent& t = tempos_[indexByTime(time)];
  return t.tick + ((time - t.time) / (60.0 / t.bpm)) * resolution_;
}

double TempoMap::bpmAtTime(double time) const { return tempos_[indexByTime(time)].bpm; }
double TempoMap::bpmAtTick(double tick) const { return tempos_[indexByTick(tick)].bpm; }

std::vector<Beat> generateBeats(const TempoMap& tempo, std::vector<TimeSigEvent> sigs, int endTick) {
  const int res = tempo.resolution();
  std::stable_sort(sigs.begin(), sigs.end(), [](const TimeSigEvent& a, const TimeSigEvent& b) { return a.tick < b.tick; });
  if (sigs.empty() || sigs.front().tick != 0) sigs.insert(sigs.begin(), TimeSigEvent{0, 4, 4, 0});
  std::vector<Beat> beats;
  for (size_t i = 0; i < sigs.size(); i++) {
    const TimeSigEvent& sig = sigs[i];
    const int next = i + 1 < sigs.size() ? sigs[i + 1].tick : endTick;
    const int num = std::max(1, sig.numerator ? sig.numerator : 4);
    const int den = std::max(1, sig.denominator ? sig.denominator : 4);
    const double beatTicks = double(res * 4) / den;
    double tick = sig.tick;
    int beatInMeasure = 0;
    while (tick < next || (i == sigs.size() - 1 && tick <= endTick)) {
      if (tick > endTick) break;
      beats.push_back(Beat{int(tick), tempo.tickToTime(tick), beatInMeasure == 0});
      beatInMeasure = (beatInMeasure + 1) % num;
      tick += beatTicks;
      if (beatTicks <= 0) break;
    }
  }
  return beats;
}

}  // namespace gc

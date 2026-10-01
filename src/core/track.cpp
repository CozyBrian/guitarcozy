#include "track.h"
#include <algorithm>
#include <cmath>

namespace gc {

int defaultHopoThreshold(int resolution) { return int(std::lround(65.0 * resolution / 192.0)); }

static bool rangeContains(const RawRange& r, int tick) {
  if (r.length <= 0) return tick == r.tick;
  return tick >= r.tick && tick < r.tick + r.length;
}

static bool anyContains(const std::vector<RawRange>& ranges, int tick) {
  for (const auto& r : ranges) if (rangeContains(r, tick)) return true;
  return false;
}

static int popcount5(int v) { return __builtin_popcount(unsigned(v) & 0b11111u); }

static size_t lowerBound(const std::vector<ChartNote>& notes, int tick) {
  size_t lo = 0, hi = notes.size();
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    if (notes[mid].tick < tick) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

Track buildTrack(Instrument instrument, Difficulty difficulty, const RawTrackData& raw, const TempoMap& tempo, const BuildOptions& opts) {
  const int res = tempo.resolution();
  const int hopoThreshold = opts.hopoThreshold > 0 ? opts.hopoThreshold : defaultHopoThreshold(res);
  const int sustainCutoff = opts.sustainCutoff;
  const double timeOffset = opts.timeOffset;

  std::vector<RawNote> sorted = raw.notes;
  std::stable_sort(sorted.begin(), sorted.end(), [](const RawNote& a, const RawNote& b) { return a.tick != b.tick ? a.tick < b.tick : a.fret < b.fret; });

  Track track;
  track.instrument = instrument;
  track.difficulty = difficulty;
  auto& notes = track.notes;
  for (const auto& n : sorted) {
    if (n.fret < 0 || n.fret > 5) continue;
    int length = n.length > 0 ? n.length : 0;
    if (sustainCutoff > 0 && length <= sustainCutoff) length = 0;
    if (!notes.empty() && notes.back().tick == n.tick) {
      ChartNote& last = notes.back();
      last.frets |= 1 << n.fret;
      last.lengths[n.fret] = std::max(last.lengths[n.fret], length);
    } else {
      ChartNote note;
      note.tick = n.tick;
      note.frets = 1 << n.fret;
      note.lengths[n.fret] = length;
      notes.push_back(note);
    }
  }

  for (size_t i = 0; i < notes.size(); i++) {
    ChartNote& note = notes[i];
    const int fretCount = popcount5(note.frets);
    note.isChord = fretCount + ((note.frets >> 5) & 1) > 1;
    note.forced = anyContains(raw.forced, note.tick);
    note.tap = anyContains(raw.taps, note.tick);
    note.time = tempo.tickToTime(note.tick) + timeOffset;
    double maxEnd = note.time;
    for (int f = 0; f < 6; f++) {
      const int len = note.lengths[f];
      note.endTimes[f] = len > 0 ? tempo.tickToTime(note.tick + len) + timeOffset : note.time;
      maxEnd = std::max(maxEnd, note.endTimes[f]);
    }
    note.endTime = maxEnd;

    bool natural = false;
    if (!note.isChord && i > 0) {
      const ChartNote& prev = notes[i - 1];
      if (note.tick - prev.tick <= hopoThreshold) natural = prev.isChord || prev.frets != note.frets;
    }
    bool hopo = natural;
    if (note.forced) hopo = !hopo;
    note.type = note.tap ? NoteType::Tap : (hopo ? NoteType::Hopo : NoteType::Strum);
  }

  auto makePhrases = [&](std::vector<RawRange> ranges) {
    std::vector<Phrase> out;
    std::stable_sort(ranges.begin(), ranges.end(), [](const RawRange& a, const RawRange& b) { return a.tick < b.tick; });
    for (const auto& r : ranges) {
      const int length = std::max(r.length, 1);
      const size_t start = lowerBound(notes, r.tick);
      size_t end = start;
      while (end < notes.size() && notes[end].tick < r.tick + length) end++;
      out.push_back(Phrase{r.tick, length, tempo.tickToTime(r.tick) + timeOffset, tempo.tickToTime(r.tick + length) + timeOffset, int(start), int(end)});
    }
    return out;
  };
  track.starPower = makePhrases(raw.starPower);
  track.solos = makePhrases(raw.solos);
  for (size_t p = 0; p < track.starPower.size(); p++)
    for (int i = track.starPower[p].noteStart; i < track.starPower[p].noteEnd; i++) notes[i].spPhrase = int(p);
  for (const auto& p : track.solos)
    for (int i = p.noteStart; i < p.noteEnd; i++) notes[i].solo = true;
  return track;
}

}  // namespace gc

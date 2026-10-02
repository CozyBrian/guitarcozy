#include "engine.h"
#include <algorithm>
#include <cmath>

namespace gc {

namespace {
constexpr double NOTE_POINTS = 50;
constexpr double SUSTAIN_POINTS_PER_BEAT = 25;
constexpr double SP_PHRASE_VALUE = 0.25;
constexpr double SP_BEATS_PER_FULL_BAR = 32;
constexpr double SP_WHAMMY_PER_BEAT = 0.03;
constexpr double ROCK_START = 0.5;
constexpr double ROCK_HIT = 0.014;
constexpr double ROCK_MISS = -0.045;
constexpr double ROCK_OVERSTRUM = -0.03;

int gemCount(const ChartNote& n) {
  int c = 0;
  for (int f = 0; f < 6; f++) if (n.frets & (1 << f)) c++;
  return std::max(1, c);
}
double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
double bpmAt(const Chart& chart, double time) {
  const auto& t = chart.tempos;
  if (t.empty()) return 120;
  size_t lo = 0, hi = t.size() - 1;
  while (lo < hi) {
    size_t mid = (lo + hi + 1) / 2;
    if (t[mid].time <= time) lo = mid;
    else hi = mid - 1;
  }
  return t[lo].bpm;
}
}  // namespace

GameEngine::GameEngine(const Chart& chart, const Track& track, const EngineOptions& opts) : chart_(chart), track_(track), opts_(opts) {
  const size_t n = track.notes.size();
  state_.assign(n, NoteState::Pending);
  hitOffset_.assign(n, 0.f);
  sustainHeld_.assign(n, 0);
  sustainDropped_.assign(n, 0);
  lastSustainScoreTime_.assign(n, 0);
  phraseBroken_.assign(track.starPower.size(), false);
  phraseDone_.assign(track.starPower.size(), false);
  stats_.notesTotal = int(n);
  stats_.spPhrasesTotal = int(track.starPower.size());
  stats_.rockMeter = ROCK_START;
}

double GameEngine::maxBaseScore() const {
  double total = 0;
  const int res = chart_.resolution;
  for (size_t i = 0; i < track_.notes.size(); i++) {
    if (state_[i] == NoteState::Skipped) continue;
    const ChartNote& n = track_.notes[i];
    total += NOTE_POINTS * gemCount(n);
    for (int f = 0; f < 6; f++) if (n.lengths[f] > 0) total += (double(n.lengths[f]) / res) * SUSTAIN_POINTS_PER_BEAT;
  }
  return total;
}

std::string GameEngine::currentSectionName() const { return currentSection_ >= 0 ? chart_.sections[currentSection_].name : ""; }

double GameEngine::accuracy() const {
  const int judged = stats_.notesHit + stats_.notesMissed;
  return judged ? double(stats_.notesHit) / judged : 1.0;
}

// ------------------------------------------------------------------ input

void GameEngine::setFrets(int mask, double time) {
  const int prev = held_;
  held_ = mask & 0b11111;
  if (stats_.failed) return;
  if (held_ != prev) {
    tryFretHit(time);
    if (hasPendingStrum_) tryStrumHit(pendingStrum_, true);
  }
}

void GameEngine::strum(double time) {
  if (stats_.failed) return;
  tryStrumHit(time, false);
}

bool GameEngine::activateStarPower() {
  if (stats_.spActive || stats_.starPower < 0.5 || stats_.failed) return false;
  stats_.spActive = true;
  updateMultiplier();
  emit(EngineEvent{EngineEvent::Type::SpActivated});
  return true;
}

// ------------------------------------------------------------------ core

bool GameEngine::inWindow(const ChartNote& n, double t) const { return std::fabs(n.time - t) <= opts_.hitWindow; }

bool GameEngine::matches(const ChartNote& note) const {
  const int req = note.frets & 0b11111;
  int sustainMask = 0;
  for (int i : activeSustains_) sustainMask |= sustainHeld_[i];
  int h = held_ & ~(sustainMask & ~req);
  if (req == 0) return (note.frets & kOpenBit) != 0 && h == 0;
  const int lowest = h == 0 ? 0 : (req & -req);
  h &= ~(lowest - 1);  // anchoring: ignore frets below the lowest required one
  return h == req;
}

void GameEngine::tryStrumHit(double time, bool fromFretChange) {
  const int idx = nextPending_;
  const int n = int(track_.notes.size());
  if (!fromFretChange && time - lastHopoFretHitTime_ < 0.065 && !(idx < n && inWindow(track_.notes[idx], time))) return;
  if (idx < n) {
    const ChartNote& note = track_.notes[idx];
    if (inWindow(note, time)) {
      if (matches(note)) {
        hasPendingStrum_ = false;
        hitNote(idx, time);
        return;
      }
      if (!fromFretChange) { hasPendingStrum_ = true; pendingStrum_ = time; }
      return;
    }
  }
  if (!fromFretChange) { hasPendingStrum_ = true; pendingStrum_ = time; }
}

void GameEngine::resolveExpiredStrum() {
  if (!hasPendingStrum_) return;
  if (time_ - pendingStrum_ < opts_.strumLeniency) return;
  const double strumTime = pendingStrum_;
  hasPendingStrum_ = false;
  const int idx = nextPending_;
  if (idx < int(track_.notes.size()) && inWindow(track_.notes[idx], strumTime)) missNote(idx, true);
  else overstrum();
}

void GameEngine::tryFretHit(double time) {
  const int idx = nextPending_;
  if (idx >= int(track_.notes.size())) return;
  const ChartNote& note = track_.notes[idx];
  if (note.type == NoteType::Strum) return;
  if (!inWindow(note, time)) return;
  if (note.type == NoteType::Hopo && stats_.streak == 0 && stats_.notesHit + stats_.notesMissed > 0) return;
  if (!matches(note)) return;
  lastHopoFretHitTime_ = time;
  hasPendingStrum_ = false;
  hitNote(idx, time);
}

void GameEngine::hitNote(int idx, double time) {
  const ChartNote& note = track_.notes[idx];
  state_[idx] = NoteState::Hit;
  hitOffset_[idx] = float(time - note.time);
  advancePending();
  stats_.notesHit++;
  stats_.streak++;
  stats_.longestStreak = std::max(stats_.longestStreak, stats_.streak);
  if (note.solo) soloHit_++;
  updateMultiplier();
  const double points = NOTE_POINTS * gemCount(note);
  stats_.baseScore += points;
  addScore(points);
  stats_.rockMeter = clamp01(stats_.rockMeter + ROCK_HIT * (stats_.spActive ? 2 : 1));
  muted_ = false;
  int mask = 0;
  for (int f = 0; f < 6; f++) if (note.lengths[f] > 0) mask |= 1 << f;
  if (mask) {
    sustainHeld_[idx] = uint8_t(mask);
    activeSustains_.insert(idx);
    lastSustainScoreTime_[idx] = std::max(time, note.time);
  }
  if (note.spPhrase >= 0) {
    const Phrase& p = track_.starPower[note.spPhrase];
    if (idx == p.noteEnd - 1 && !phraseBroken_[note.spPhrase] && !phraseDone_[note.spPhrase]) {
      phraseDone_[note.spPhrase] = true;
      stats_.spPhrasesHit++;
      stats_.starPower = std::min(1.0, stats_.starPower + SP_PHRASE_VALUE);
      EngineEvent e{EngineEvent::Type::SpPhraseComplete};
      e.phrase = note.spPhrase;
      emit(e);
    }
  }
  EngineEvent e{EngineEvent::Type::Hit};
  e.index = idx;
  e.time = time;
  emit(e);
}

void GameEngine::missNote(int idx, bool over) {
  const ChartNote& note = track_.notes[idx];
  state_[idx] = NoteState::Missed;
  advancePending();
  stats_.notesMissed++;
  breakCombo();
  stats_.rockMeter = clamp01(stats_.rockMeter + ROCK_MISS);
  muted_ = true;
  if (note.spPhrase >= 0 && !phraseBroken_[note.spPhrase]) {
    phraseBroken_[note.spPhrase] = true;
    EngineEvent e{EngineEvent::Type::SpPhraseFailed};
    e.phrase = note.spPhrase;
    emit(e);
  }
  EngineEvent e{EngineEvent::Type::Miss};
  e.index = idx;
  e.time = time_;
  e.overstrum = over;
  emit(e);
  checkFail();
}

void GameEngine::overstrum() {
  stats_.overstrums++;
  breakCombo();
  stats_.rockMeter = clamp01(stats_.rockMeter + ROCK_OVERSTRUM);
  muted_ = true;
  std::vector<int> active(activeSustains_.begin(), activeSustains_.end());
  for (int i : active)
    for (int f = 0; f < 6; f++) if (sustainHeld_[i] & (1 << f)) dropSustain(i, f);
  EngineEvent e{EngineEvent::Type::Overstrum};
  e.time = time_;
  emit(e);
  checkFail();
}

void GameEngine::breakCombo() {
  stats_.streak = 0;
  updateMultiplier();
}

void GameEngine::advancePending() {
  while (nextPending_ < int(track_.notes.size()) && state_[nextPending_] != NoteState::Pending) nextPending_++;
}

void GameEngine::updateMultiplier() {
  const int s = stats_.streak;
  int m = s >= 30 ? 4 : s >= 20 ? 3 : s >= 10 ? 2 : 1;
  if (stats_.spActive) m *= 2;
  if (m != stats_.multiplier) {
    stats_.multiplier = m;
    EngineEvent e{EngineEvent::Type::Multiplier};
    e.multiplier = m;
    emit(e);
  }
}

void GameEngine::addScore(double points) {
  const int add = int(std::lround(points * stats_.multiplier));
  stats_.score += add;
  if (currentSolo_ >= 0) stats_.soloScore += add;
}

void GameEngine::checkFail() {
  if (opts_.noFail || stats_.failed) return;
  if (stats_.rockMeter <= 0) {
    stats_.failed = true;
    emit(EngineEvent{EngineEvent::Type::Fail});
  }
}

void GameEngine::dropSustain(int idx, int fret) {
  sustainHeld_[idx] &= uint8_t(~(1 << fret));
  sustainDropped_[idx] |= uint8_t(1 << fret);
  if (sustainHeld_[idx] == 0) activeSustains_.erase(idx);
  EngineEvent e{EngineEvent::Type::SustainDrop};
  e.index = idx;
  e.fret = fret;
  emit(e);
}

// ------------------------------------------------------------------ frame update

void GameEngine::update(double time) {
  lastTime_ = time_;
  time_ = time;
  const double dt = std::max(0.0, time - lastTime_);
  if (ended_) return;
  const auto& notes = track_.notes;
  const int n = int(notes.size());

  resolveExpiredStrum();

  while (nextPending_ < n) {
    if (time - notes[nextPending_].time > opts_.hitWindow) missNote(nextPending_, false);
    else break;
  }

  const double beatsPerSec = bpmAt(chart_, time) / 60.0;
  std::vector<int> active(activeSustains_.begin(), activeSustains_.end());
  for (int idx : active) {
    const ChartNote& note = notes[idx];
    const int req = note.frets & 0b11111;
    for (int f = 0; f < 6; f++) {
      if (!(sustainHeld_[idx] & (1 << f))) continue;
      const double end = note.endTimes[f];
      const bool heldOk = f == 5 || (held_ & (1 << f)) != 0 || (req != 0 && (held_ & ~((req & -req) - 1)) == req);
      if (!heldOk) { dropSustain(idx, f); continue; }
      const double last = lastSustainScoreTime_[idx];
      const double until = std::min(time, end);
      if (until > last) {
        const double beats = (until - last) * beatsPerSec;
        const double pts = beats * SUSTAIN_POINTS_PER_BEAT;
        stats_.baseScore += pts;
        sustainAcc_ += pts * stats_.multiplier;
        if (note.spPhrase >= 0 && whammy_ > 0.15) stats_.starPower = std::min(1.0, stats_.starPower + beats * SP_WHAMMY_PER_BEAT * whammy_);
      }
      if (time >= end) {
        sustainHeld_[idx] &= uint8_t(~(1 << f));
        if (sustainHeld_[idx] == 0) activeSustains_.erase(idx);
        EngineEvent e{EngineEvent::Type::SustainEnd};
        e.index = idx;
        e.fret = f;
        emit(e);
      }
    }
    lastSustainScoreTime_[idx] = time;
  }
  if (sustainAcc_ >= 1) {
    const int whole = int(std::floor(sustainAcc_));
    stats_.score += whole;
    if (currentSolo_ >= 0) stats_.soloScore += whole;
    sustainAcc_ -= whole;
  }

  if (stats_.spActive) {
    stats_.starPower -= (dt * beatsPerSec) / SP_BEATS_PER_FULL_BAR;
    if (stats_.starPower <= 0) {
      stats_.starPower = 0;
      stats_.spActive = false;
      updateMultiplier();
      emit(EngineEvent{EngineEvent::Type::SpEnded});
    }
  }

  const auto& sections = chart_.sections;
  int sec = currentSection_;
  while (sec + 1 < int(sections.size()) && sections[sec + 1].time <= time) sec++;
  if (sec != currentSection_) {
    currentSection_ = sec;
    if (sec >= 0) {
      EngineEvent e{EngineEvent::Type::Section};
      e.section = sections[sec].name;
      emit(e);
    }
  }
  while (sectionCounter_ < n && notes[sectionCounter_].time <= time) sectionCounter_++;

  const auto& solos = track_.solos;
  if (currentSolo_ < 0) {
    int next = -1;
    for (int i = lastSolo_ + 1; i < int(solos.size()); i++) if (time >= solos[i].time - 0.001) { next = i; break; }
    if (next >= 0 && time < solos[next].endTime) {
      currentSolo_ = next;
      soloHit_ = 0;
      soloTotalNotes_ = solos[next].noteEnd - solos[next].noteStart;
      EngineEvent e{EngineEvent::Type::SoloStart};
      e.soloTotal = soloTotalNotes_;
      emit(e);
    }
  } else {
    const Phrase& s = solos[currentSolo_];
    if (time > s.endTime + opts_.hitWindow) {
      const int pct = soloTotalNotes_ ? int(std::lround(100.0 * soloHit_ / soloTotalNotes_)) : 100;
      EngineEvent e{EngineEvent::Type::SoloEnd};
      e.soloHit = soloHit_;
      e.soloTotal = soloTotalNotes_;
      e.soloPercent = pct;
      emit(e);
      const int bonus = pct >= 100 ? 10000 : pct >= 95 ? 5000 : pct >= 90 ? 4000 : pct >= 80 ? 3000 : pct >= 70 ? 2000 : pct >= 60 ? 1000 : 0;
      stats_.score += bonus;
      lastSolo_ = currentSolo_;
      currentSolo_ = -1;
    }
  }

  const double endAt = rangeEnd_ < 1e299 ? rangeEnd_ : chart_.chartLength + 1.5;
  if (nextPending_ >= n && activeSustains_.empty() && time > endAt) {
    closeSection();
    ended_ = true;
    emit(EngineEvent{EngineEvent::Type::End});
  }
}

void GameEngine::closeSection() {
  const auto& sections = chart_.sections;
  stats_.sections.clear();
  if (sections.empty()) return;
  size_t ni = 0;
  for (size_t si = 0; si < sections.size(); si++) {
    const double end = si + 1 < sections.size() ? sections[si + 1].time : 1e300;
    int hit = 0, total = 0;
    while (ni < track_.notes.size() && track_.notes[ni].time < end) {
      if (state_[ni] != NoteState::Skipped) {
        total++;
        if (state_[ni] == NoteState::Hit) hit++;
      }
      ni++;
    }
    if (total > 0) stats_.sections.push_back(SectionStat{sections[si].name, hit, total});
  }
}

void GameEngine::reset(double startTime, double endTime) {
  std::fill(state_.begin(), state_.end(), NoteState::Pending);
  std::fill(hitOffset_.begin(), hitOffset_.end(), 0.f);
  std::fill(sustainHeld_.begin(), sustainHeld_.end(), 0);
  std::fill(sustainDropped_.begin(), sustainDropped_.end(), 0);
  activeSustains_.clear();
  std::fill(lastSustainScoreTime_.begin(), lastSustainScoreTime_.end(), 0.0);
  std::fill(phraseBroken_.begin(), phraseBroken_.end(), false);
  std::fill(phraseDone_.begin(), phraseDone_.end(), false);
  hasPendingStrum_ = false;
  lastHopoFretHitTime_ = -1e300;
  currentSection_ = -1;
  sectionCounter_ = 0;
  currentSolo_ = -1;
  lastSolo_ = -1;
  soloHit_ = 0;
  ended_ = false;
  sustainAcc_ = 0;
  muted_ = false;
  time_ = startTime < -1e299 ? 0 : startTime;
  lastTime_ = time_;
  rangeEnd_ = endTime;
  int total = 0;
  for (size_t i = 0; i < track_.notes.size(); i++) {
    const double t = track_.notes[i].time;
    if (t < startTime || t >= endTime) state_[i] = NoteState::Skipped;
    else total++;
  }
  nextPending_ = 0;
  advancePending();
  sectionCounter_ = nextPending_;
  lastSolo_ = -1;
  for (int i = 0; i < int(track_.solos.size()); i++) if (track_.solos[i].endTime < startTime) lastSolo_ = i;
  int spTotal = 0;
  for (const auto& p : track_.starPower) if (p.time >= startTime && p.time < endTime) spTotal++;
  EngineStats fresh;
  fresh.notesTotal = total;
  fresh.spPhrasesTotal = spTotal;
  fresh.rockMeter = ROCK_START;
  stats_ = fresh;
}

int starRating(double score, double maxBase, bool fullCombo, double accuracy) {
  if (fullCombo) return 6;
  const double ratio = maxBase > 0 ? score / maxBase : 0;
  const double acc = accuracy >= 0 ? accuracy : 0;
  if (ratio >= 4.4 || (acc >= 0.98 && ratio >= 4.0)) return 5;
  if (ratio >= 3.6 || (acc >= 0.95 && ratio >= 3.0)) return 4;
  if (ratio >= 2.8 || acc >= 0.85) return 3;
  if (ratio >= 2.0 || acc >= 0.70) return 2;
  if (ratio >= 1.0 || acc >= 0.50) return 1;
  return 0;
}

}  // namespace gc

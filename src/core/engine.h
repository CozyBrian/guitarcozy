// Pure gameplay logic (no rendering). Time values are song seconds.
#pragma once
#include <cstdint>
#include <functional>
#include <set>
#include <string>
#include <vector>
#include "types.h"

namespace gc {

enum class NoteState : uint8_t { Pending = 0, Hit = 1, Missed = 2, Skipped = 3 };

struct EngineOptions {
  double hitWindow = 0.09;     // seconds, each direction
  bool noFail = false;
  double strumLeniency = 0.05; // seconds a strum waits for a fret
};

struct EngineEvent {
  enum class Type { Hit, Miss, Overstrum, SustainDrop, SustainEnd, SpPhraseComplete, SpPhraseFailed, SpActivated, SpEnded, Multiplier, Fail, SoloStart, SoloEnd, Section, End };
  Type type;
  int index = -1;        // note index (Hit/Miss/SustainDrop/SustainEnd)
  int fret = -1;         // SustainDrop/SustainEnd
  int phrase = -1;       // SpPhrase*
  int multiplier = 1;    // Multiplier
  bool overstrum = false;// Miss: caused by a wrong-fret strum
  int soloHit = 0, soloTotal = 0, soloPercent = 0;
  std::string section;   // Section
  double time = 0;
};

struct SectionStat { std::string name; int hit = 0, total = 0; };

struct EngineStats {
  int score = 0;
  double baseScore = 0;
  int notesHit = 0, notesTotal = 0, notesMissed = 0, overstrums = 0;
  int streak = 0, longestStreak = 0, multiplier = 1;
  double starPower = 0;  // 0..1
  bool spActive = false;
  int spPhrasesHit = 0, spPhrasesTotal = 0;
  double rockMeter = 0.5;
  bool failed = false;
  int soloScore = 0;
  std::vector<SectionStat> sections;
};

class GameEngine {
 public:
  GameEngine(const Chart& chart, const Track& track, const EngineOptions& opts);

  using Listener = std::function<void(const EngineEvent&)>;
  void setListener(Listener l) { listener_ = std::move(l); }

  // ---- input
  void setFrets(int mask, double time);
  void strum(double time);
  void setWhammy(double v) { whammy_ = v; }
  bool activateStarPower();

  // ---- per frame
  void update(double time);

  // ---- practice mode: reset and skip notes outside [startTime, endTime)
  void reset(double startTime = -1e300, double endTime = 1e300);

  // ---- state
  const Chart& chart() const { return chart_; }
  const Track& track() const { return track_; }
  const std::vector<ChartNote>& notes() const { return track_.notes; }
  const std::vector<NoteState>& state() const { return state_; }
  const std::vector<float>& hitOffset() const { return hitOffset_; }
  const std::vector<uint8_t>& sustainHeld() const { return sustainHeld_; }
  const std::vector<uint8_t>& sustainDropped() const { return sustainDropped_; }
  const EngineStats& stats() const { return stats_; }
  EngineStats& mutableStats() { return stats_; }
  double currentTime() const { return time_; }
  int fretsHeld() const { return held_; }
  int firstPending() const { return nextPending_; }
  bool ended() const { return ended_; }
  bool muted() const { return muted_; }
  double maxBaseScore() const;
  std::string currentSectionName() const;
  bool soloActive() const { return currentSolo_ >= 0; }
  int soloHit() const { return soloHit_; }
  int soloTotal() const { return soloTotalNotes_; }
  double accuracy() const;

 private:
  void emit(const EngineEvent& e) { if (listener_) listener_(e); }
  bool inWindow(const ChartNote& n, double t) const;
  bool matches(const ChartNote& n) const;
  void tryStrumHit(double time, bool fromFretChange);
  void resolveExpiredStrum();
  void tryFretHit(double time);
  void hitNote(int idx, double time);
  void missNote(int idx, bool overstrum);
  void overstrum();
  void breakCombo();
  void advancePending();
  void updateMultiplier();
  void addScore(double points);
  void checkFail();
  void dropSustain(int idx, int fret);
  void closeSection();

  const Chart& chart_;
  const Track& track_;
  EngineOptions opts_;
  Listener listener_;
  std::vector<NoteState> state_;
  std::vector<float> hitOffset_;
  std::vector<uint8_t> sustainHeld_, sustainDropped_;
  EngineStats stats_;
  int nextPending_ = 0;
  int held_ = 0;
  double whammy_ = 0;
  double time_ = 0, lastTime_ = 0;
  bool hasPendingStrum_ = false;
  double pendingStrum_ = 0;
  double lastHopoFretHitTime_ = -1e300;
  std::vector<bool> phraseBroken_, phraseDone_;
  int currentSection_ = -1;
  int sectionCounter_ = 0;
  int currentSolo_ = -1, lastSolo_ = -1, soloHit_ = 0, soloTotalNotes_ = 0;
  bool ended_ = false;
  bool muted_ = false;
  std::set<int> activeSustains_;
  std::vector<double> lastSustainScoreTime_;
  double sustainAcc_ = 0;
  double rangeEnd_ = 1e300;
};

// Star rating 0..6 (6 = gold, full combo), balancing the GH3 average-multiplier ladder with accuracy:
//   1-3 stars: multiplier 1.0 / 2.0 / 2.8x, OR accuracy 50% / 70% / 85%  (hitting the notes gets you to 3)
//   4 stars:   3.6x, or 95% accuracy with at least 3.0x
//   5 stars:   4.4x, or 98% accuracy with at least 4.0x  (the top needs star power and streaks)
int starRating(double score, double maxBase, bool fullCombo, double accuracy = -1);

}  // namespace gc

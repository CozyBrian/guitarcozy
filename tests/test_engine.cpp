#include "core/chart_parser.h"
#include "core/engine.h"
#include "test.h"

static const char* CHART = R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = TS 4
  0 = B 120000
}
[ExpertSingle]
{
  0 = N 0 0
  0 = S 2 300
  48 = N 1 0
  192 = N 0 192
  192 = N 1 192
  576 = N 2 0
  576 = N 6 0
  768 = N 7 0
  960 = N 3 0
}
)";

struct Fixture {
  gc::Chart chart = gc::parseChart(CHART);
  const gc::Track& track = *chart.track(gc::Instrument::Guitar, gc::Difficulty::Expert);
  gc::GameEngine e;
  std::vector<gc::EngineEvent::Type> events;
  Fixture() : e(chart, track, gc::EngineOptions{0.09, true, 0.05}) {
    e.setListener([this](const gc::EngineEvent& ev) { events.push_back(ev.type); });
  }
  bool saw(gc::EngineEvent::Type t) const { for (auto x : events) if (x == t) return true; return false; }
};

TEST(engine_hits_strums_hopos_chords_and_taps) {
  Fixture f;
  auto& e = f.e;
  using S = gc::NoteState;
  e.update(-0.5);
  e.setFrets(0b00001, -0.02);
  e.strum(0.01);
  e.update(0.02);
  CHECK(e.state()[0] == S::Hit);
  CHECK_EQ(e.stats().streak, 1);
  e.setFrets(0b00011, 0.12);
  e.update(0.13);
  CHECK(e.state()[1] == S::Hit);
  e.strum(0.14);
  e.update(0.2);
  CHECK_EQ(e.stats().overstrums, 0);
  e.setFrets(0b00011, 0.49);
  e.strum(0.5);
  e.update(0.51);
  CHECK(e.state()[2] == S::Hit);
  CHECK_NEAR(e.stats().starPower, 0.25, 1e-9);
  CHECK(f.saw(gc::EngineEvent::Type::SpPhraseComplete));
  const int before = e.stats().score;
  e.update(0.8);
  e.update(1.05);
  CHECK(e.stats().score > before);
  e.setFrets(0b00100, 1.48);
  e.update(1.5);
  CHECK(e.state()[3] == S::Hit);
  e.setFrets(0, 1.9);
  e.strum(2.0);
  e.update(2.01);
  CHECK(e.state()[4] == S::Hit);
  e.update(2.7);
  CHECK(e.state()[5] == S::Missed);
  CHECK_EQ(e.stats().streak, 0);
  CHECK_EQ(e.stats().notesHit, 5);
  CHECK_EQ(e.stats().notesMissed, 1);
}

TEST(engine_counts_overstrums_and_wrong_fret_strums) {
  Fixture f;
  auto& e = f.e;
  e.update(-1);
  e.strum(-0.9);
  e.update(-0.8);
  CHECK_EQ(e.stats().overstrums, 1);
  e.setFrets(0b00010, -0.05);
  e.strum(0);
  e.update(0.1);
  CHECK(e.state()[0] == gc::NoteState::Missed);
}

TEST(engine_activates_and_drains_star_power) {
  Fixture f;
  auto& e = f.e;
  e.mutableStats().starPower = 0.5;
  CHECK(e.activateStarPower());
  CHECK_EQ(e.stats().multiplier, 2);
  e.update(0);
  e.update(10);
  CHECK(!e.stats().spActive);
  CHECK_EQ(e.stats().multiplier, 1);
}

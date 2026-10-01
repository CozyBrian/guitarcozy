#include <fstream>
#include <sstream>
#include "core/chart_parser.h"
#include "core/engine.h"
#include "test.h"

// Simulates the autoplay bot at 60 fps through the whole demo chart (same as the web build's test).
static void botPlay(gc::Difficulty diff, int fps, bool expectFullCombo) {
  std::ifstream in(std::string(GC_ASSETS_DIR) + "/demo/notes.chart");
  CHECK(in.good());
  std::stringstream ss;
  ss << in.rdbuf();
  gc::Chart chart = gc::parseChart(ss.str());
  const gc::Track* track = chart.track(gc::Instrument::Guitar, diff);
  CHECK(track != nullptr);
  if (!track) return;
  gc::GameEngine e(chart, *track, gc::EngineOptions{0.09, false, 0.05});
  double botStrumAt = -1e300;
  const double dt = 1.0 / fps;
  for (double t = -3; t < chart.chartLength + 2; t += dt) {
    const int idx = e.firstPending();
    if (idx < int(track->notes.size())) {
      const auto& note = track->notes[idx];
      if (t >= note.time - 0.004) {
        if (e.fretsHeld() != (note.frets & 0b11111)) e.setFrets(note.frets & 0b11111, t);
        if (e.firstPending() == idx && t - botStrumAt > 0.01) { e.strum(t); botStrumAt = t; }
        if (e.stats().starPower >= 0.5 && !e.stats().spActive) e.activateStarPower();
      }
    }
    e.update(t);
  }
  if (expectFullCombo) {
    CHECK_EQ(e.stats().notesMissed, 0);
    CHECK_EQ(e.stats().overstrums, 0);
    CHECK_EQ(e.stats().spPhrasesHit, int(track->starPower.size()));
  }
  CHECK_EQ(e.stats().notesHit, int(track->notes.size()));
  CHECK(!e.stats().failed);
  CHECK(e.ended());
  CHECK(!e.stats().sections.empty());
}

TEST(bot_full_combos_demo_expert) { botPlay(gc::Difficulty::Expert, 60, true); }
TEST(bot_full_combos_demo_easy_at_30fps) { botPlay(gc::Difficulty::Easy, 30, false); }

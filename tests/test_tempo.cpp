#include "core/tempo.h"
#include "test.h"

TEST(tempo_map_converts_ticks_and_time) {
  gc::TempoMap tm(192, {{0, 120, 0}, {768, 240, 0}});
  CHECK_NEAR(tm.tickToTime(192), 0.5, 1e-9);
  CHECK_NEAR(tm.tickToTime(768), 2.0, 1e-9);
  CHECK_NEAR(tm.tickToTime(768 + 192), 2.25, 1e-9);
  CHECK_NEAR(tm.timeToTick(2.25), 960, 1e-6);
  CHECK_NEAR(tm.bpmAtTime(3.0), 240, 1e-9);
}

TEST(beats_follow_time_signatures) {
  gc::TempoMap tm(192, {{0, 120, 0}});
  auto beats = gc::generateBeats(tm, {{0, 4, 4, 0}, {768, 3, 4, 0}}, 768 * 2);
  CHECK(beats[0].measure);
  CHECK(!beats[1].measure);
  CHECK(beats[4].measure);   // second 4/4 measure
  CHECK(beats[7].measure);   // 3/4 starts at tick 768 -> 5th beat index 4..: 4 beats + 3 beats
  CHECK_NEAR(beats[4].time, 2.0, 1e-9);
}

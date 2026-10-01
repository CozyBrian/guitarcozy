#include "core/chart_parser.h"
#include "core/song_ini.h"
#include "test.h"

static const char* CHART = R"([Song]
{
  Name = "Test Song"
  Artist = "Tester"
  Offset = 0.5
  Resolution = 192
}
[SyncTrack]
{
  0 = TS 4
  0 = B 120000
  768 = B 240000
}
[Events]
{
  0 = E "section Intro"
  768 = E "section Verse"
}
[ExpertSingle]
{
  0 = N 0 0
  0 = S 2 400
  48 = N 1 0
  96 = N 1 0
  192 = N 0 0
  192 = N 1 192
  240 = N 2 0
  384 = N 3 0
  384 = N 5 0
  480 = N 4 0
  480 = N 6 0
  576 = N 7 0
  576 = E solo
  768 = N 0 0
  768 = E soloend
}
)";

TEST(chart_parser_metadata_sync_and_notes) {
  gc::Chart chart = gc::parseChart(CHART);
  CHECK(chart.meta.name == "Test Song");
  CHECK_EQ(chart.resolution, 192);
  CHECK_NEAR(chart.offset, 0.5, 1e-9);
  const gc::Track* track = chart.track(gc::Instrument::Guitar, gc::Difficulty::Expert);
  CHECK(track != nullptr);
  if (!track) return;
  const auto& n = track->notes;
  CHECK_EQ(n.size(), size_t(9));
  CHECK_NEAR(n[0].time, 0.5, 1e-9);
  CHECK(n[0].type == gc::NoteType::Strum);
  CHECK(n[1].type == gc::NoteType::Hopo);   // red after green within 65 ticks
  CHECK(n[2].type == gc::NoteType::Strum);  // red after red
  CHECK(n[3].isChord);
  CHECK_EQ(n[3].frets, 0b11);
  CHECK_EQ(n[3].lengths[1], 192);
  CHECK_NEAR(n[3].endTimes[1], 1.5, 1e-9);
  CHECK(n[4].type == gc::NoteType::Hopo);   // after chord
  CHECK(n[5].type == gc::NoteType::Hopo);   // forced
  CHECK(n[6].type == gc::NoteType::Tap);
  CHECK_EQ(n[7].frets, gc::kOpenBit);
  CHECK(n[7].solo);
  CHECK_EQ(n[0].spPhrase, 0);
  CHECK_EQ(n[5].spPhrase, 0);
  CHECK_EQ(n[6].spPhrase, -1);
  CHECK_NEAR(n[8].time, 2.5, 1e-9);
  CHECK_NEAR(chart.sections[1].time, 2.5, 1e-9);
  CHECK(chart.beats[0].measure);
  CHECK(!chart.beats[1].measure);
  CHECK(chart.beats[4].measure);
}

TEST(song_ini_parses_common_keys) {
  gc::SongMeta m = gc::parseSongIni("[song]\nname = Highway Burn\nartist = GuitarCozy\ndiff_guitar = 3\ndelay = 120\nyear = , 2026\nhopo_frequency = 170\neighthnote_hopo = 1\n");
  CHECK(m.name == "Highway Burn");
  CHECK(m.artist == "GuitarCozy");
  CHECK_EQ(m.diff[gc::Instrument::Guitar], 3);
  CHECK_NEAR(m.delay, 120, 1e-9);
  CHECK(m.year == "2026");
  CHECK_EQ(gc::hopoThresholdFor(m, 480), 170);
  m.hopoFrequency = 0;
  CHECK_EQ(gc::hopoThresholdFor(m, 480), 241);
}

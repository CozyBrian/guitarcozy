#include "core/midi_parser.h"
#include <algorithm>
#include "test.h"

// Minimal in-memory MIDI writer for the test fixture.
namespace {
struct Track {
  std::vector<std::pair<int, std::vector<uint8_t>>> events;  // (tick, raw event bytes)
  static void vlqTo(std::vector<uint8_t>& out, int v) {
    uint8_t buf[5]; int n = 0;
    do { buf[n++] = uint8_t(v & 0x7F); v = int(unsigned(v) >> 7); } while (v && n < 5);
    for (int i = n - 1; i >= 0; i--) out.push_back(uint8_t(buf[i] | (i ? 0x80 : 0)));
  }
  void meta(int tick, int type, const std::vector<uint8_t>& d) { std::vector<uint8_t> e = {0xFF, uint8_t(type)}; vlqTo(e, int(d.size())); e.insert(e.end(), d.begin(), d.end()); events.emplace_back(tick, e); }
  void text(int tick, int type, const std::string& s) { meta(tick, type, std::vector<uint8_t>(s.begin(), s.end())); }
  void on(int tick, int note) { events.emplace_back(tick, std::vector<uint8_t>{0x90, uint8_t(note), 100}); }
  void off(int tick, int note) { events.emplace_back(tick, std::vector<uint8_t>{0x80, uint8_t(note), 0}); }
  void end(int tick) { meta(tick, 0x2F, {}); }
  std::vector<uint8_t> bytes() const {
    auto sorted = events;
    std::stable_sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    std::vector<uint8_t> out;
    int last = 0;
    for (const auto& [tick, e] : sorted) { vlqTo(out, tick - last); last = tick; out.insert(out.end(), e.begin(), e.end()); }
    return out;
  }
};
void be32(std::vector<uint8_t>& o, uint32_t v) { for (int i = 3; i >= 0; i--) o.push_back(uint8_t(v >> (8 * i))); }
void be16(std::vector<uint8_t>& o, uint16_t v) { o.push_back(uint8_t(v >> 8)); o.push_back(uint8_t(v)); }
std::vector<uint8_t> file(const std::vector<Track>& tracks) {
  std::vector<uint8_t> o = {'M', 'T', 'h', 'd'};
  be32(o, 6); be16(o, 1); be16(o, uint16_t(tracks.size())); be16(o, 480);
  for (const auto& t : tracks) { auto b = t.bytes(); o.insert(o.end(), {'M', 'T', 'r', 'k'}); be32(o, uint32_t(b.size())); o.insert(o.end(), b.begin(), b.end()); }
  return o;
}
}  // namespace

TEST(midi_parser_guitar_track) {
  Track tempo; tempo.meta(0, 0x51, {0x07, 0xA1, 0x20}); tempo.meta(0, 0x58, {4, 2, 24, 8}); tempo.end(1920);
  Track events; events.text(0, 0x03, "EVENTS"); events.text(0, 0x01, "[section Verse 1]"); events.text(960, 0x01, "[prc_chorus_a]"); events.end(1920);
  Track g; g.text(0, 0x03, "PART GUITAR");
  g.on(0, 116); g.on(0, 96); g.off(240, 96); g.on(100, 97); g.off(110, 97); g.off(200, 116);
  g.on(480, 96); g.on(480, 97); g.off(490, 96); g.off(490, 97);
  g.on(580, 98); g.on(580, 102); g.off(590, 98); g.off(600, 102);   // natural hopo + force strum
  g.on(960, 99); g.on(960, 104); g.off(970, 99); g.off(980, 104);   // tap
  g.end(1920);
  gc::Chart chart = gc::parseMidiChart(file({tempo, events, g}));
  CHECK_EQ(chart.resolution, 480);
  CHECK_EQ(chart.sections.size(), size_t(2));
  CHECK(chart.sections[0].name == "Verse 1");
  CHECK(chart.sections[1].name == "chorus a");
  const gc::Track* t = chart.track(gc::Instrument::Guitar, gc::Difficulty::Expert);
  CHECK(t != nullptr);
  if (!t) return;
  CHECK_EQ(t->notes.size(), size_t(5));
  CHECK_EQ(t->notes[0].lengths[0], 240);
  CHECK(t->notes[1].type == gc::NoteType::Hopo);
  CHECK(t->notes[2].isChord);
  CHECK(t->notes[3].type == gc::NoteType::Strum);
  CHECK(t->notes[4].type == gc::NoteType::Tap);
  CHECK_EQ(t->starPower.size(), size_t(1));
  CHECK_EQ(t->notes[0].spPhrase, 0);
  CHECK_EQ(t->notes[2].spPhrase, -1);
  CHECK_NEAR(t->notes[2].time, 0.5, 1e-9);
}

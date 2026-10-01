// Core data model shared by parsers, gameplay engine and renderer.
// Ticks are chart-resolution ticks; "time" fields are seconds relative to the
// audio start (already including chart Offset / song.ini delay).
#pragma once
#include <array>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace gc {

enum class Instrument { Guitar, Bass, Rhythm, Keys, Coop };
enum class Difficulty { Easy, Medium, Hard, Expert };
enum class NoteType { Strum, Hopo, Tap };

constexpr int kFretGreen = 0, kFretRed = 1, kFretYellow = 2, kFretBlue = 3, kFretOrange = 4, kFretOpen = 5;
constexpr int kOpenBit = 1 << 5;
constexpr int kAllFretsMask = 0b11111;

inline const char* instrumentName(Instrument i) {
  switch (i) {
    case Instrument::Guitar: return "guitar";
    case Instrument::Bass: return "bass";
    case Instrument::Rhythm: return "rhythm";
    case Instrument::Keys: return "keys";
    case Instrument::Coop: return "coop";
  }
  return "guitar";
}
inline const char* difficultyName(Difficulty d) {
  switch (d) {
    case Difficulty::Easy: return "easy";
    case Difficulty::Medium: return "medium";
    case Difficulty::Hard: return "hard";
    case Difficulty::Expert: return "expert";
  }
  return "expert";
}
inline std::string trackKey(Instrument i, Difficulty d) { return std::string(instrumentName(i)) + ":" + difficultyName(d); }

// One note event (a single gem or a chord).
struct ChartNote {
  int tick = 0;
  double time = 0;
  int frets = 0;                       // bitmask: bits 0..4 = GRYBO, bit 5 = open
  std::array<int, 6> lengths{};        // sustain length per fret in ticks
  std::array<double, 6> endTimes{};    // sustain end time per fret (== time when none)
  double endTime = 0;                  // longest sustain end
  bool forced = false;
  bool tap = false;
  NoteType type = NoteType::Strum;
  int spPhrase = -1;
  bool solo = false;
  bool isChord = false;
};

struct Phrase {
  int tick = 0, length = 0;
  double time = 0, endTime = 0;
  int noteStart = 0, noteEnd = 0;  // [start, end)
};

struct Track {
  Instrument instrument = Instrument::Guitar;
  Difficulty difficulty = Difficulty::Expert;
  std::vector<ChartNote> notes;
  std::vector<Phrase> starPower;
  std::vector<Phrase> solos;
};

struct TempoEvent { int tick = 0; double bpm = 120; double time = 0; };
struct TimeSigEvent { int tick = 0; int numerator = 4, denominator = 4; double time = 0; };
struct Section { int tick = 0; double time = 0; std::string name; };
struct Beat { int tick = 0; double time = 0; bool measure = false; };
struct LyricEvent { int tick = 0; double time = 0; std::string text; };
struct LightEvent { int tick = 0; double time = 0; std::string name; };  // lighting (xxx) venue cues

struct SongMeta {
  std::string name = "Unknown Song";
  std::string artist = "Unknown Artist";
  std::string album, genre, year, charter;
  double delay = 0;           // ms
  double previewStart = 0;    // ms
  double songLength = 0;      // ms
  std::map<Instrument, int> diff;
  int hopoFrequency = 0;      // ticks (0 = default)
  bool eighthNoteHopo = false;
  int sustainCutoff = 0;      // ticks (0 = none)
  std::string loadingPhrase, icon;
  int multiplierNote = 116;
  std::map<std::string, std::string> raw;
  // set when the chart file itself supplied a value (used as fallback)
  bool hasName = false, hasArtist = false, hasAlbum = false, hasCharter = false;
};

struct Chart {
  int resolution = 192;
  double offset = 0;  // seconds ([Song] Offset)
  std::vector<TempoEvent> tempos;
  std::vector<TimeSigEvent> timeSigs;
  std::vector<Section> sections;
  std::vector<Beat> beats;
  std::vector<LyricEvent> lyrics;
  std::vector<LightEvent> lighting;
  std::map<std::string, Track> tracks;  // keyed by trackKey()
  SongMeta meta;                        // from the chart file (fallback)
  double chartLength = 0;               // seconds, end of last note/sustain

  const Track* track(Instrument i, Difficulty d) const {
    auto it = tracks.find(trackKey(i, d));
    return it == tracks.end() ? nullptr : &it->second;
  }
};

}  // namespace gc

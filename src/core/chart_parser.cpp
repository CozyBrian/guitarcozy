#include "chart_parser.h"
#include <algorithm>
#include <cmath>
#include <optional>
#include "tempo.h"
#include "text_util.h"
#include "track.h"

namespace gc {

std::string decodeText(const std::vector<uint8_t>& d) {
  auto utf16 = [&](bool le) {
    std::string out;
    for (size_t i = 2; i + 1 < d.size(); i += 2) {
      uint32_t cp = le ? (d[i] | (d[i + 1] << 8)) : ((d[i] << 8) | d[i + 1]);
      if (cp >= 0xD800 && cp <= 0xDBFF && i + 3 < d.size()) {
        uint32_t lo = le ? (d[i + 2] | (d[i + 3] << 8)) : ((d[i + 2] << 8) | d[i + 3]);
        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
        i += 2;
      }
      if (cp < 0x80) out += char(cp);
      else if (cp < 0x800) { out += char(0xC0 | (cp >> 6)); out += char(0x80 | (cp & 0x3F)); }
      else if (cp < 0x10000) { out += char(0xE0 | (cp >> 12)); out += char(0x80 | ((cp >> 6) & 0x3F)); out += char(0x80 | (cp & 0x3F)); }
      else { out += char(0xF0 | (cp >> 18)); out += char(0x80 | ((cp >> 12) & 0x3F)); out += char(0x80 | ((cp >> 6) & 0x3F)); out += char(0x80 | (cp & 0x3F)); }
    }
    return out;
  };
  if (d.size() >= 2 && d[0] == 0xFF && d[1] == 0xFE) return utf16(true);
  if (d.size() >= 2 && d[0] == 0xFE && d[1] == 0xFF) return utf16(false);
  size_t start = (d.size() >= 3 && d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF) ? 3 : 0;
  return std::string(d.begin() + start, d.end());
}

namespace {

struct RawSection {
  std::string name;
  std::vector<std::string> lines;
};

std::vector<RawSection> splitSections(const std::string& text) {
  std::vector<RawSection> sections;
  RawSection* current = nullptr;
  for (const auto& rawLine : splitLines(text)) {
    std::string line = trim(rawLine);
    if (line.empty()) continue;
    if (line.front() == '[' && line.back() == ']') {
      sections.push_back(RawSection{trim(line.substr(1, line.size() - 2)), {}});
      current = &sections.back();
      continue;
    }
    if (line == "{" || line == "}") continue;
    if (current) current->lines.push_back(line);
  }
  return sections;
}

std::optional<std::pair<std::string, std::string>> keyValue(const std::string& line) {
  size_t eq = line.find('=');
  if (eq == std::string::npos) return std::nullopt;
  return std::make_pair(trim(line.substr(0, eq)), trim(line.substr(eq + 1)));
}

std::optional<Difficulty> diffFromName(const std::string& s) {
  if (s == "Easy") return Difficulty::Easy;
  if (s == "Medium") return Difficulty::Medium;
  if (s == "Hard") return Difficulty::Hard;
  if (s == "Expert") return Difficulty::Expert;
  return std::nullopt;
}

std::optional<Instrument> instFromName(const std::string& s) {
  if (s == "Single") return Instrument::Guitar;
  if (s == "DoubleGuitar") return Instrument::Coop;
  if (s == "DoubleBass") return Instrument::Bass;
  if (s == "DoubleRhythm") return Instrument::Rhythm;
  if (s == "Keyboard") return Instrument::Keys;
  return std::nullopt;
}

int toInt(const std::string& s, int fallback = 0) {
  try { return std::stoi(s); } catch (...) { return fallback; }
}
double toDouble(const std::string& s, double fallback = 0) {
  try { return std::stod(s); } catch (...) { return fallback; }
}

}  // namespace

Chart parseChart(const std::string& text, const ChartParseOptions& opts) {
  Chart chart;
  auto sections = splitSections(text);
  auto find = [&](const char* name) -> const RawSection* {
    for (const auto& s : sections) if (s.name == name) return &s;
    return nullptr;
  };

  int resolution = 192;
  double offset = 0;
  if (const RawSection* song = find("Song")) {
    for (const auto& line : song->lines) {
      auto kv = keyValue(line);
      if (!kv) continue;
      const auto& [key, value] = *kv;
      chart.meta.raw[toLower(key)] = stripQuotes(value);
      if (key == "Resolution") resolution = toInt(value, 192) ? toInt(value, 192) : 192;
      else if (key == "Offset") offset = toDouble(value);
      else if (key == "Name") { chart.meta.name = stripQuotes(value); chart.meta.hasName = true; }
      else if (key == "Artist") { chart.meta.artist = stripQuotes(value); chart.meta.hasArtist = true; }
      else if (key == "Album") { chart.meta.album = stripQuotes(value); chart.meta.hasAlbum = true; }
      else if (key == "Charter") { chart.meta.charter = stripQuotes(value); chart.meta.hasCharter = true; }
      else if (key == "Genre") chart.meta.genre = stripQuotes(value);
      else if (key == "Year") { chart.meta.year = stripQuotes(value); if (startsWith(chart.meta.year, ",")) chart.meta.year = trim(chart.meta.year.substr(1)); }
      else if (key == "PreviewStart") chart.meta.previewStart = toDouble(value) * 1000;
    }
  }

  std::vector<TempoEvent> tempos;
  std::vector<TimeSigEvent> timeSigs;
  if (const RawSection* sync = find("SyncTrack")) {
    for (const auto& line : sync->lines) {
      auto kv = keyValue(line);
      if (!kv) continue;
      const int tick = toInt(kv->first, -1);
      if (tick < 0) continue;
      auto parts = splitWs(kv->second);
      if (parts.empty()) continue;
      if (parts[0] == "B" && parts.size() > 1) {
        const double bpm = toInt(parts[1]) / 1000.0;
        if (bpm > 0) tempos.push_back(TempoEvent{tick, bpm, 0});
      } else if (parts[0] == "TS" && parts.size() > 1) {
        const int num = toInt(parts[1], 4) ? toInt(parts[1], 4) : 4;
        const int denExp = parts.size() > 2 ? toInt(parts[2], 2) : 2;
        timeSigs.push_back(TimeSigEvent{tick, num, 1 << denExp, 0});
      }
    }
  }
  TempoMap tempo(resolution, tempos);
  const double timeOffset = offset + opts.timeOffset;

  if (const RawSection* events = find("Events")) {
    for (const auto& line : events->lines) {
      auto kv = keyValue(line);
      if (!kv) continue;
      const int tick = toInt(kv->first, -1);
      if (tick < 0 || !startsWith(kv->second, "E ")) continue;
      const std::string ev = stripQuotes(trim(kv->second.substr(2)));
      if (startsWith(ev, "section ")) chart.sections.push_back(Section{tick, tempo.tickToTime(tick) + timeOffset, trim(ev.substr(8))});
      else if (startsWith(ev, "prc_")) {
        std::string name = ev.substr(4);
        std::replace(name.begin(), name.end(), '_', ' ');
        chart.sections.push_back(Section{tick, tempo.tickToTime(tick) + timeOffset, trim(name)});
      } else if (startsWith(ev, "lyric ")) chart.lyrics.push_back(LyricEvent{tick, tempo.tickToTime(tick) + timeOffset, ev.substr(6)});
      else if (startsWith(ev, "lighting")) {
        const size_t a = ev.find('('), b = ev.find(')');
        std::string name = a != std::string::npos && b != std::string::npos && b > a ? ev.substr(a + 1, b - a - 1) : "";
        chart.lighting.push_back(LightEvent{tick, tempo.tickToTime(tick) + timeOffset, trim(name)});
      } else if (ev == "bre_start" || ev == "bre_end" || startsWith(ev, "crowd_")) chart.lighting.push_back(LightEvent{tick, tempo.tickToTime(tick) + timeOffset, ev});
    }
  }

  int lastTick = 0;
  double chartLength = 0;
  for (const auto& sec : sections) {
    // "<Difficulty><Instrument>"
    std::optional<Difficulty> diff;
    std::string rest;
    for (const char* d : {"Expert", "Medium", "Hard", "Easy"}) {
      if (startsWith(sec.name, d)) { diff = diffFromName(d); rest = sec.name.substr(strlen(d)); break; }
    }
    if (!diff) continue;
    auto inst = instFromName(rest);
    if (!inst) continue;
    RawTrackData raw;
    int soloStart = -1;
    for (const auto& line : sec.lines) {
      auto kv = keyValue(line);
      if (!kv) continue;
      const int tick = toInt(kv->first, -1);
      if (tick < 0) continue;
      auto parts = splitWs(kv->second);
      if (parts.empty()) continue;
      if (parts[0] == "N" && parts.size() >= 3) {
        const int fret = toInt(parts[1], -1);
        const int length = toInt(parts[2]);
        if (fret >= 0 && fret <= 4) raw.notes.push_back(RawNote{tick, fret, length});
        else if (fret == 5) raw.forced.push_back(RawRange{tick, 0});
        else if (fret == 6) raw.taps.push_back(RawRange{tick, 0});
        else if (fret == 7) raw.notes.push_back(RawNote{tick, 5, length});
        lastTick = std::max(lastTick, tick + length);
      } else if (parts[0] == "S" && parts.size() >= 3) {
        if (toInt(parts[1]) == 2) raw.starPower.push_back(RawRange{tick, toInt(parts[2])});
      } else if (parts[0] == "E" && parts.size() >= 2) {
        if (parts[1] == "solo") soloStart = tick;
        else if (parts[1] == "soloend" && soloStart >= 0) {
          raw.solos.push_back(RawRange{soloStart, std::max(1, tick - soloStart + 1)});
          soloStart = -1;
        }
      }
    }
    if (soloStart >= 0) raw.solos.push_back(RawRange{soloStart, std::max(1, lastTick - soloStart + 1)});
    if (raw.notes.empty()) continue;
    BuildOptions bo;
    bo.hopoThreshold = opts.hopoThreshold;
    bo.sustainCutoff = opts.sustainCutoff;
    bo.timeOffset = timeOffset;
    Track track = buildTrack(*inst, *diff, raw, tempo, bo);
    for (const auto& n : track.notes) chartLength = std::max(chartLength, n.endTime);
    chart.tracks[trackKey(*inst, *diff)] = std::move(track);
  }

  const int endTick = int(std::max<double>(lastTick, tempo.timeToTick(chartLength - timeOffset))) + resolution * 8;
  chart.beats = generateBeats(tempo, timeSigs, endTick);
  for (auto& b : chart.beats) b.time += timeOffset;
  chart.resolution = resolution;
  chart.offset = offset;
  chart.tempos = tempo.tempos();
  for (auto& t : chart.tempos) t.time += timeOffset;
  chart.timeSigs = timeSigs;
  for (auto& ts : chart.timeSigs) ts.time = tempo.tickToTime(ts.tick) + timeOffset;
  chart.chartLength = chartLength;
  return chart;
}

}  // namespace gc

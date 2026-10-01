#include "chart_scan.h"
#include <cstdlib>
#include <cstring>
#include <optional>
#include <unordered_set>
#include "tempo.h"
#include "text_util.h"

namespace gc {

namespace {
std::optional<Difficulty> diffOf(const std::string& s) {
  if (s == "Easy") return Difficulty::Easy;
  if (s == "Medium") return Difficulty::Medium;
  if (s == "Hard") return Difficulty::Hard;
  if (s == "Expert") return Difficulty::Expert;
  return std::nullopt;
}
std::optional<Instrument> instOf(const std::string& s) {
  if (s == "Single") return Instrument::Guitar;
  if (s == "DoubleGuitar") return Instrument::Coop;
  if (s == "DoubleBass") return Instrument::Bass;
  if (s == "DoubleRhythm") return Instrument::Rhythm;
  if (s == "Keyboard") return Instrument::Keys;
  return std::nullopt;
}
std::string unquote(std::string s) { s = trim(s); if (s.size() >= 2 && s.front() == '"' && s.back() == '"') s = s.substr(1, s.size() - 2); return s; }
}  // namespace

ChartScan scanChartQuick(const std::string& text) {
  ChartScan out;
  int resolution = 192;
  double offset = 0;
  std::vector<TempoEvent> tempos;
  std::string section;
  std::optional<Instrument> inst; std::optional<Difficulty> diff;
  std::unordered_set<int> ticks;
  int lastTick = 0;
  auto flush = [&]() {
    if (inst && diff && !ticks.empty()) out.tracks.push_back({*inst, *diff, int(ticks.size())});
    ticks.clear(); inst.reset(); diff.reset();
  };
  size_t pos = 0;
  while (pos < text.size()) {
    size_t eol = text.find('\n', pos);
    if (eol == std::string::npos) eol = text.size();
    std::string line = trim(text.substr(pos, eol - pos));
    pos = eol + 1;
    if (line.empty() || line == "{" || line == "}") continue;
    if (line.front() == '[' && line.back() == ']') {
      flush();
      section = line.substr(1, line.size() - 2);
      for (const char* d : {"Easy", "Medium", "Hard", "Expert"}) {
        if (section.rfind(d, 0) == 0) { diff = diffOf(d); inst = instOf(section.substr(strlen(d))); break; }
      }
      continue;
    }
    const size_t eq = line.find('=');
    if (eq == std::string::npos) continue;
    const std::string key = trim(line.substr(0, eq)), val = trim(line.substr(eq + 1));
    if (section == "Song") {
      if (key == "Name") { out.meta.name = unquote(val); out.meta.hasName = true; }
      else if (key == "Artist") { out.meta.artist = unquote(val); out.meta.hasArtist = true; }
      else if (key == "Charter") { out.meta.charter = unquote(val); out.meta.hasCharter = true; }
      else if (key == "Album") { out.meta.album = unquote(val); out.meta.hasAlbum = true; }
      else if (key == "Genre") out.meta.genre = unquote(val);
      else if (key == "Year") { std::string y = unquote(val); if (y.rfind(", ", 0) == 0) y = y.substr(2); out.meta.year = y; }
      else if (key == "Resolution") resolution = std::max(1, atoi(val.c_str()));
      else if (key == "Offset") offset = atof(val.c_str());
    } else if (section == "SyncTrack") {
      if (val.size() > 2 && val[0] == 'B' && val[1] == ' ') tempos.push_back(TempoEvent{atoi(key.c_str()), atoi(val.c_str() + 2) / 1000.0, 0});
    } else if (inst && diff) {
      if (val.size() > 2 && val[0] == 'N' && val[1] == ' ') {
        const int fret = atoi(val.c_str() + 2);
        if (fret <= 4 || fret == 7) {
          const int tick = atoi(key.c_str());
          ticks.insert(tick);
          const char* sp = strchr(val.c_str() + 2, ' ');
          const int len = sp ? atoi(sp + 1) : 0;
          lastTick = std::max(lastTick, tick + len);
        }
      }
    }
  }
  flush();
  if (tempos.empty()) tempos.push_back(TempoEvent{0, 0, 120});
  TempoMap tempo(resolution, tempos);
  out.lengthSeconds = lastTick > 0 ? tempo.tickToTime(lastTick) + offset : 0;
  return out;
}

}  // namespace gc

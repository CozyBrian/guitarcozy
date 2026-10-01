#include "song_ini.h"
#include <cmath>
#include "text_util.h"

namespace gc {

static double num(const std::map<std::string, std::string>& raw, const char* key, double fallback) {
  auto it = raw.find(key);
  if (it == raw.end()) return fallback;
  try { return std::stod(it->second); } catch (...) { return fallback; }
}
static bool flag(const std::map<std::string, std::string>& raw, const char* key) {
  auto it = raw.find(key);
  if (it == raw.end()) return false;
  std::string s = toLower(trim(it->second));
  return s == "1" || s == "true" || s == "yes";
}
static std::string str(const std::map<std::string, std::string>& raw, const char* key) {
  auto it = raw.find(key);
  return it == raw.end() ? std::string() : it->second;
}

SongMeta parseSongIni(const std::string& text) {
  SongMeta meta;
  for (const auto& rawLine : splitLines(text)) {
    std::string line = trim(rawLine);
    if (line.empty() || line[0] == ';' || line[0] == '#' || line[0] == '[') continue;
    size_t eq = line.find('=');
    if (eq == std::string::npos) continue;
    meta.raw[toLower(trim(line.substr(0, eq)))] = trim(line.substr(eq + 1));
  }
  const auto& raw = meta.raw;
  if (!str(raw, "name").empty()) { meta.name = str(raw, "name"); meta.hasName = true; }
  if (!str(raw, "artist").empty()) { meta.artist = str(raw, "artist"); meta.hasArtist = true; }
  if (!str(raw, "album").empty()) { meta.album = str(raw, "album"); meta.hasAlbum = true; }
  meta.genre = str(raw, "genre");
  meta.year = str(raw, "year");
  if (startsWith(meta.year, ",")) meta.year = trim(meta.year.substr(1));
  meta.charter = !str(raw, "charter").empty() ? str(raw, "charter") : str(raw, "frets");
  meta.hasCharter = !meta.charter.empty();
  meta.delay = num(raw, "delay", 0);
  meta.previewStart = num(raw, "preview_start_time", num(raw, "preview_start", 0));
  meta.songLength = num(raw, "song_length", 0);
  meta.hopoFrequency = int(num(raw, "hopo_frequency", 0));
  meta.eighthNoteHopo = flag(raw, "eighthnote_hopo");
  meta.sustainCutoff = int(num(raw, "sustain_cutoff_threshold", 0));
  meta.loadingPhrase = str(raw, "loading_phrase");
  meta.icon = str(raw, "icon");
  meta.multiplierNote = int(num(raw, "multiplier_note", 116));
  const std::pair<const char*, Instrument> diffKeys[] = {
      {"diff_guitar", Instrument::Guitar}, {"diff_bass", Instrument::Bass}, {"diff_rhythm", Instrument::Rhythm}, {"diff_keys", Instrument::Keys}, {"diff_guitar_coop", Instrument::Coop}};
  for (const auto& [k, inst] : diffKeys)
    if (raw.count(k)) meta.diff[inst] = int(num(raw, k, -1));
  return meta;
}

int hopoThresholdFor(const SongMeta& meta, int resolution) {
  if (meta.hopoFrequency > 0) return meta.hopoFrequency;
  if (meta.eighthNoteHopo) return int(std::lround(resolution / 2.0)) + 1;
  auto it = meta.raw.find("hopofreq");
  if (it != meta.raw.end()) {
    int level = 0;
    try { level = std::stoi(it->second); } catch (...) { return 0; }
    static const double beats[] = {1.0 / 8, 1.0 / 6, 1.0 / 4, 1.0 / 3, 1.0 / 2, 2.0 / 3};
    level = std::max(0, std::min(5, level));
    return int(std::lround(beats[level] * resolution));
  }
  return 0;
}

}  // namespace gc

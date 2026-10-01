#include "song_loader.h"
#include <filesystem>
#include <fstream>
#include <iterator>
#include "core/chart_parser.h"
#include "core/midi_parser.h"
#include "core/song_ini.h"
#include "core/sng.h"
#include "core/text_util.h"
#include "app/Settings.h"

namespace fs = std::filesystem;

namespace gc {

static std::vector<uint8_t> readBytes(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}

std::unique_ptr<LoadedSong> loadSongFolder(const std::string& folder, std::string* error) {
  auto song = std::make_unique<LoadedSong>();
  song->folder = folder;
  fs::path dir(folder);
  if (!fs::is_directory(dir)) { if (error) *error = "not a folder: " + folder; return nullptr; }
  fs::path chartPath, midPath, iniPath;
  std::vector<fs::path> audio;
  static const char* stemNames[] = {"song", "guitar", "rhythm", "bass", "keys", "drums", "drums_1", "drums_2", "drums_3", "drums_4", "vocals", "vocals_1", "vocals_2", "crowd"};
  for (const auto& e : fs::directory_iterator(dir)) {
    const std::string name = toLower(e.path().filename().string());
    if (name == "notes.chart") chartPath = e.path();
    else if (name == "notes.mid") midPath = e.path();
    else if (name == "song.ini") iniPath = e.path();
    else {
      const std::string stem = toLower(e.path().stem().string());
      const std::string ext = toLower(e.path().extension().string());
      for (const char* s : stemNames) if (stem == s && (ext == ".ogg" || ext == ".opus" || ext == ".mp3" || ext == ".wav" || ext == ".flac" || ext == ".m4a")) audio.push_back(e.path());
    }
  }
  if (chartPath.empty() && midPath.empty()) { if (error) *error = "no notes.chart / notes.mid in " + folder; return nullptr; }
  if (!iniPath.empty()) song->meta = parseSongIni(decodeText(readBytes(iniPath)));
  const double delay = song->meta.delay / 1000.0;
  try {
    if (!chartPath.empty()) {
      const std::string text = decodeText(readBytes(chartPath));
      ChartParseOptions o;
      o.timeOffset = delay;
      o.sustainCutoff = song->meta.sustainCutoff;
      // resolution is needed for the hopo threshold override; parse cheaply
      size_t r = text.find("Resolution");
      int res = 192;
      if (r != std::string::npos) { size_t eq = text.find('=', r); if (eq != std::string::npos) res = std::atoi(text.c_str() + eq + 1); }
      o.hopoThreshold = hopoThresholdFor(song->meta, res ? res : 192);
      song->chart = parseChart(text, o);
    } else {
      MidiParseOptions o;
      o.timeOffset = delay;
      o.multiplierNote = song->meta.multiplierNote;
      if (song->meta.sustainCutoff > 0) o.sustainCutoff = song->meta.sustainCutoff;
      song->chart = parseMidiChart(readBytes(midPath), o);
      const int th = hopoThresholdFor(song->meta, song->chart.resolution);
      if (th) { o.hopoThreshold = th; song->chart = parseMidiChart(readBytes(midPath), o); }
    }
  } catch (const std::exception& ex) {
    if (error) *error = std::string("chart parse failed: ") + ex.what();
    return nullptr;
  }
  if (!song->meta.hasName && song->chart.meta.hasName) song->meta.name = song->chart.meta.name;
  if (!song->meta.hasArtist && song->chart.meta.hasArtist) song->meta.artist = song->chart.meta.artist;
  for (const auto& p : audio) {
    auto stream = audio::decodeAudioFileAsync(p.string());
    if (stream->failed) { fprintf(stderr, "stem %s: %s\n", p.filename().c_str(), stream->error.c_str()); continue; }
    song->stems.push_back({toLower(p.stem().string()), std::move(stream)});
  }
  return song;
}

bool isSngPath(const std::string& path) { return path.size() > 4 && toLower(path.substr(path.size() - 4)) == ".sng"; }

static std::string cacheId(const std::string& s) {
  uint64_t h = 1469598103934665603ull;
  for (unsigned char c : s) { h ^= c; h *= 1099511628211ull; }
  char buf[40];
  snprintf(buf, sizeof buf, "%016llx", (unsigned long long)h);
  return buf;
}

std::string resolveSongFolder(const std::string& path, std::string* error) {
  if (!isSngPath(path)) return path;
  std::error_code ec;
  const long long mtime = (long long)fs::last_write_time(path, ec).time_since_epoch().count();
  const fs::path dir = fs::path(supportDir()) / "sng" / cacheId(path + "@" + std::to_string(mtime));
  if (fs::exists(dir / ".unpacked", ec)) return dir.string();
  const std::vector<uint8_t> bytes = readBytes(path);
  try {
    const SngHeader h = parseSngHeader(bytes.data(), bytes.size());
    fs::create_directories(dir, ec);
    for (const auto& f : h.files) {
      const std::string name = fs::path(f.name).filename().string();  // no directory escapes
      if (name.empty() || f.offset + f.size > bytes.size()) continue;
      const auto out = unmaskSngFile(h, bytes.data() + f.offset, size_t(f.size));
      std::ofstream o(dir / name, std::ios::binary);
      o.write(reinterpret_cast<const char*>(out.data()), std::streamsize(out.size()));
    }
    std::ofstream ini(dir / "song.ini", std::ios::binary);
    const std::string text = sngMetadataToIni(h);
    ini.write(text.data(), std::streamsize(text.size()));
    ini.close();
    std::ofstream(dir / ".unpacked") << "ok";
  } catch (const std::exception& ex) {
    if (error) *error = std::string("sng: ") + ex.what();
    return "";
  }
  return dir.string();
}

std::unique_ptr<LoadedSong> loadSong(const std::string& path, std::string* error) {
  const std::string folder = resolveSongFolder(path, error);
  if (folder.empty()) return nullptr;
  auto song = loadSongFolder(folder, error);
  if (song) song->folder = folder;
  return song;
}

}  // namespace gc

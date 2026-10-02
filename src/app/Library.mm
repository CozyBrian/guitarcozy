#import <Foundation/Foundation.h>
#include <sqlite3.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include "Library.h"
#include "Settings.h"
#include "core/chart_parser.h"
#include "core/chart_scan.h"
#include "core/midi_parser.h"
#include "core/song_ini.h"
#include "core/sng.h"
#include "core/text_util.h"
#include "platform/song_loader.h"

namespace fs = std::filesystem;

namespace gc {

Library& Library::instance() { static Library l; return l; }

static std::string hashId(const std::string& s) {
  uint32_t h = 2166136261u;
  for (unsigned char c : s) { h ^= c; h *= 16777619u; }
  char buf[32];
  snprintf(buf, sizeof buf, "%08x%zx", h, s.size());
  return buf;
}
static std::vector<uint8_t> readBytes(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}
static std::string key(const std::string& id, Instrument i, Difficulty d) { return id + ":" + instrumentName(i) + ":" + difficultyName(d); }

void Library::setBuiltinFolder(const std::string& folder) { builtin_ = folder; }
const SongEntry* Library::byId(const std::string& id) const { for (const auto& e : entries_) if (e.id == id) return &e; return nullptr; }

// ------------------------------------------------------------ scanning (pure helpers, safe on a worker thread)
namespace {

std::string fileToken(const fs::path& p) {
  std::error_code ec;
  const auto t = fs::last_write_time(p, ec).time_since_epoch().count();
  const auto sz = fs::file_size(p, ec);
  return std::to_string((long long)t) + ":" + std::to_string((unsigned long long)sz);
}

std::vector<uint8_t> readRange(const fs::path& p, uint64_t offset, uint64_t size) {
  std::ifstream in(p, std::ios::binary);
  in.seekg(std::streamoff(offset));
  std::vector<uint8_t> out(static_cast<size_t>(size), uint8_t(0));
  in.read(reinterpret_cast<char*>(out.data()), std::streamsize(size));
  out.resize(size_t(std::max<std::streamsize>(0, in.gcount())));
  return out;
}

void fillFromChart(SongEntry& entry, const Chart& c) {
  for (const auto& [k, t] : c.tracks) entry.available.push_back({t.instrument, t.difficulty, int(t.notes.size())});
  if (!entry.meta.songLength && c.chartLength > 0) entry.meta.songLength = c.chartLength * 1000;
  if (!entry.meta.hasName && c.meta.hasName) entry.meta.name = c.meta.name;
  if (!entry.meta.hasArtist && c.meta.hasArtist) entry.meta.artist = c.meta.artist;
  if (entry.meta.charter.empty() && c.meta.hasCharter) entry.meta.charter = c.meta.charter;
}

struct Candidate { std::string path; bool sng = false; };

void collect(const std::string& dir, std::vector<Candidate>& out) {
  std::error_code ec;
  if (!fs::is_directory(dir, ec)) return;
  bool isSong = false;
  for (const auto& e : fs::directory_iterator(dir, ec)) {
    const std::string n = toLower(e.path().filename().string());
    if (n == "song.ini" || n == "notes.chart" || n == "notes.mid") { isSong = true; break; }
  }
  if (isSong) { out.push_back({dir, false}); return; }
  for (const auto& e : fs::directory_iterator(dir, ec)) {
    if (e.is_directory(ec)) collect(e.path().string(), out);
    else if (isSngPath(e.path().string())) out.push_back({e.path().string(), true});
  }
}

// token identifies the chart file (folder) or the package so cached entries can be reused
std::string candidateToken(const Candidate& c) {
  if (c.sng) return fileToken(c.path);
  std::error_code ec;
  for (const char* n : {"notes.chart", "notes.mid", "song.ini"}) { fs::path p = fs::path(c.path) / n; if (fs::exists(p, ec)) return std::string(n) + "@" + fileToken(p); }
  return "";
}

bool scanSongDir(const std::string& dir, bool builtin, SongEntry& entry) {
  std::error_code ec;
  fs::path chart, mid, ini, album;
  for (const auto& e : fs::directory_iterator(dir, ec)) {
    const std::string n = toLower(e.path().filename().string());
    if (n == "notes.chart") chart = e.path();
    else if (n == "notes.mid") mid = e.path();
    else if (n == "song.ini") ini = e.path();
    else if (n == "album.png" || n == "album.jpg" || n == "album.jpeg") album = e.path();
  }
  if (chart.empty() && mid.empty()) return false;
  entry.id = hashId(dir);
  entry.path = dir;
  entry.builtin = builtin;
  entry.hasAlbumArt = !album.empty();
  entry.albumPath = album.string();
  if (!ini.empty()) entry.meta = parseSongIni(decodeText(readBytes(ini)));
  try {
    if (!chart.empty()) {
      const ChartScan q = scanChartQuick(decodeText(readBytes(chart)));
      for (const auto& t : q.tracks) entry.available.push_back({t.instrument, t.difficulty, t.noteCount});
      if (!entry.meta.songLength && q.lengthSeconds > 0) entry.meta.songLength = q.lengthSeconds * 1000;
      if (!entry.meta.hasName && q.meta.hasName) entry.meta.name = q.meta.name;
      if (!entry.meta.hasArtist && q.meta.hasArtist) entry.meta.artist = q.meta.artist;
      if (entry.meta.charter.empty() && q.meta.hasCharter) entry.meta.charter = q.meta.charter;
      if (entry.available.empty()) return false;
    } else {
      Chart c = parseMidiChart(readBytes(mid));
      fillFromChart(entry, c);
    }
  } catch (...) {
    return false;
  }
  if (!entry.meta.hasName && entry.meta.name == "Unknown Song") {
    const std::string folder = fs::path(dir).filename().string();
    const size_t dash = folder.find(" - ");
    if (dash != std::string::npos) { entry.meta.artist = folder.substr(0, dash); entry.meta.name = folder.substr(dash + 3); }
    else entry.meta.name = folder;
  }
  return true;
}

bool scanSngFile(const std::string& path, SongEntry& entry) {
  std::error_code ec;
  const uint64_t fileSize = fs::file_size(path, ec);
  if (ec || fileSize < 64) return false;
  // parse the header from a growing prefix so large packages are not read whole
  SngHeader h;
  bool ok = false;
  for (uint64_t n = 64 * 1024; !ok; n = std::min(fileSize, n * 4)) {
    const auto prefix = readRange(path, 0, n);
    try { h = parseSngHeader(prefix.data(), prefix.size()); ok = true; }
    catch (const std::exception& ex) {
      if (n >= fileSize || std::string(ex.what()).find("unexpected end") == std::string::npos) return false;
    }
  }
  const SngEntry* chart = h.find("notes.chart");
  const SngEntry* mid = h.find("notes.mid");
  if (!chart && !mid) return false;
  entry.id = hashId(path);
  entry.path = path;
  entry.sng = true;
  entry.meta = parseSongIni(sngMetadataToIni(h));
  try {
    if (chart) {
      auto raw = readRange(path, chart->offset, chart->size);
      const ChartScan q = scanChartQuick(decodeText(unmaskSngFile(h, raw.data(), raw.size())));
      for (const auto& t : q.tracks) entry.available.push_back({t.instrument, t.difficulty, t.noteCount});
      if (!entry.meta.songLength && q.lengthSeconds > 0) entry.meta.songLength = q.lengthSeconds * 1000;
      if (!entry.meta.hasName && q.meta.hasName) entry.meta.name = q.meta.name;
      if (!entry.meta.hasArtist && q.meta.hasArtist) entry.meta.artist = q.meta.artist;
    } else { auto raw = readRange(path, mid->offset, mid->size); Chart c = parseMidiChart(unmaskSngFile(h, raw.data(), raw.size())); fillFromChart(entry, c); }
  } catch (...) {
    return false;
  }
  for (const char* n : {"album.png", "album.jpg", "album.jpeg"}) {
    if (const SngEntry* a = h.find(n)) {
      const fs::path art = fs::path(supportDir()) / "sng" / (entry.id + "-" + n);
      if (!fs::exists(art, ec)) {
        auto raw = readRange(path, a->offset, a->size);
        auto out = unmaskSngFile(h, raw.data(), raw.size());
        fs::create_directories(art.parent_path(), ec);
        std::ofstream(art, std::ios::binary).write(reinterpret_cast<const char*>(out.data()), std::streamsize(out.size()));
      }
      entry.hasAlbumArt = true;
      entry.albumPath = art.string();
      break;
    }
  }
  if (!entry.meta.hasName && entry.meta.name == "Unknown Song") entry.meta.name = fs::path(path).stem().string();
  return true;
}

}  // namespace

void Library::restore() {
  loadStore();
  entries_.clear();
  SongEntry demo;
  if (!builtin_.empty() && scanSongDir(builtin_, true, demo)) entries_.push_back(std::move(demo));
  // cached entries show immediately; the background rescan refreshes them
  for (const auto& [id, cached] : cache_) {
    std::error_code ec;
    if (fs::exists(cached.second.path, ec)) entries_.push_back(cached.second);
  }
  if (onChanged) onChanged();
  if (!settings().songFolders.empty()) scanFoldersAsync(settings().songFolders);
}

void Library::addFolder(const std::string& folder) {
  auto& list = settings().songFolders;
  if (std::find(list.begin(), list.end(), folder) == list.end()) { list.push_back(folder); saveSettings(); }
  scanFoldersAsync({folder});
}

void Library::removeFolder(const std::string& folder) {
  auto& list = settings().songFolders;
  list.erase(std::remove(list.begin(), list.end(), folder), list.end());
  saveSettings();
  entries_.erase(std::remove_if(entries_.begin(), entries_.end(), [&](const SongEntry& e) { return !e.builtin && e.path.rfind(folder, 0) == 0; }), entries_.end());
  for (auto it = cache_.begin(); it != cache_.end();) { if (it->second.second.path.rfind(folder, 0) == 0) it = cache_.erase(it); else ++it; }
  deleteSongsUnder(folder);
  if (onChanged) onChanged();
}

std::string Library::addTemporarySong(const std::string& folder) {
  SongEntry e;
  if (isSngPath(folder) ? !scanSngFile(folder, e) : !scanSongDir(folder, false, e)) return "";
  entries_.erase(std::remove_if(entries_.begin(), entries_.end(), [&](const SongEntry& x) { return x.id == e.id; }), entries_.end());
  entries_.push_back(e);
  return e.id;
}

// Walks the folders and parses charts on a worker thread; progress and the merged result land on the main thread.
void Library::scanFoldersAsync(std::vector<std::string> folders) {
  const int generation = ++scanGeneration_;
  scan_ = {0, 0, true};
  if (onScan) onScan(scan_);
  auto cacheSnapshot = std::make_shared<std::map<std::string, std::pair<std::string, SongEntry>>>(cache_);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::vector<Candidate> candidates;
    for (const auto& f : folders) collect(f, candidates);
    const int total = int(candidates.size());
    dispatch_async(dispatch_get_main_queue(), ^{ if (generation == scanGeneration_) { scan_ = {0, total, true}; if (onScan) onScan(scan_); } });
    auto found = std::make_shared<std::vector<std::pair<std::string, SongEntry>>>();  // (token, entry)
    int done = 0;
    double lastPost = 0;
    for (const auto& c : candidates) {
      const std::string token = candidateToken(c);
      const std::string id = hashId(c.path);
      auto it = cacheSnapshot->find(id);
      if (it != cacheSnapshot->end() && !token.empty() && it->second.first == token) found->emplace_back(token, it->second.second);
      else {
        SongEntry e;
        if (c.sng ? scanSngFile(c.path, e) : scanSongDir(c.path, false, e)) found->emplace_back(token, std::move(e));
      }
      done++;
      const double now = [NSDate timeIntervalSinceReferenceDate];
      if (now - lastPost > 0.1 || done == total) {
        lastPost = now;
        dispatch_async(dispatch_get_main_queue(), ^{ if (generation == scanGeneration_) { scan_ = {done, total, true}; if (onScan) onScan(scan_); } });
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != scanGeneration_) return;
      for (const auto& f : folders) {
        entries_.erase(std::remove_if(entries_.begin(), entries_.end(), [&](const SongEntry& e) { return !e.builtin && e.path.rfind(f, 0) == 0; }), entries_.end());
        for (auto it = cache_.begin(); it != cache_.end();) { if (it->second.second.path.rfind(f, 0) == 0) it = cache_.erase(it); else ++it; }
      }
      for (const auto& f : folders) deleteSongsUnder(f);
      upsertSongs(*found);
      for (auto& [token, e] : *found) {
        entries_.erase(std::remove_if(entries_.begin(), entries_.end(), [&](const SongEntry& x) { return x.id == e.id; }), entries_.end());
        cache_[e.id] = {token, e};
        entries_.push_back(std::move(e));
      }
      scan_ = {total, total, false};
      if (onChanged) onChanged();
      if (onScan) onScan(scan_);
    });
  });
}

const ScoreRecord* Library::score(const std::string& id, Instrument i, Difficulty d) const {
  auto it = scores_.find(key(id, i, d));
  return it == scores_.end() ? nullptr : &it->second;
}

bool Library::saveScore(const std::string& id, Instrument i, Difficulty d, const ScoreRecord& r) {
  const std::string k = key(id, i, d);
  auto it = scores_.find(k);
  if (it != scores_.end() && it->second.score >= r.score) return false;
  scores_[k] = r;
  writeScore(k, r);
  return true;
}

void Library::addHistory(const std::string& id, Instrument i, Difficulty d, const HistoryEntry& h) {
  auto& v = history_[key(id, i, d)];
  v.push_back(h);
  if (v.size() > 50) v.erase(v.begin(), v.begin() + (v.size() - 50));
  insertHistory(key(id, i, d), id, h);
}
const std::vector<HistoryEntry>* Library::history(const std::string& id, Instrument i, Difficulty d) const {
  auto it = history_.find(key(id, i, d));
  return it == history_.end() ? nullptr : &it->second;
}
double Library::lastPlayed(const std::string& id) const {
  double best = 0;
  for (const auto& [k, v] : history_) if (k.rfind(id + ":", 0) == 0) for (const auto& h : v) best = std::max(best, h.date);
  return best;
}

std::map<std::string, int> Library::careerProgress(Instrument i, Difficulty d) const {
  auto it = career_.find(std::string(instrumentName(i)) + ":" + difficultyName(d));
  return it == career_.end() ? std::map<std::string, int>{} : it->second;
}

void Library::recordCareer(Instrument i, Difficulty d, const std::string& songId, int stars) {
  auto& m = career_[std::string(instrumentName(i)) + ":" + difficultyName(d)];
  if (m[songId] < stars) { m[songId] = stars; writeCareer(std::string(instrumentName(i)) + ":" + difficultyName(d), songId, stars); }
}

// ------------------------------------------------------------ SQLite store
namespace {
sqlite3* openDb(const std::string& path) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) { fprintf(stderr, "library db: %s\n", db ? sqlite3_errmsg(db) : "open failed"); return nullptr; }
  sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nullptr, nullptr, nullptr);
  const char* schema =
      "CREATE TABLE IF NOT EXISTS scores(key TEXT PRIMARY KEY, score INTEGER, stars INTEGER, accuracy REAL, notesHit INTEGER, notesTotal INTEGER, longestStreak INTEGER, fullCombo INTEGER, date REAL);"
      "CREATE TABLE IF NOT EXISTS career(key TEXT, songId TEXT, stars INTEGER, PRIMARY KEY(key, songId));"
      "CREATE TABLE IF NOT EXISTS history(id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, songId TEXT, date REAL, score INTEGER, stars INTEGER, accuracy REAL, speed REAL, fullCombo INTEGER, replay TEXT);"
      "CREATE INDEX IF NOT EXISTS history_key ON history(key, date);"
      "CREATE INDEX IF NOT EXISTS history_song ON history(songId, date);"
      "CREATE TABLE IF NOT EXISTS songs(id TEXT PRIMARY KEY, path TEXT, token TEXT, sng INTEGER, hasAlbumArt INTEGER, albumPath TEXT, name TEXT, artist TEXT, album TEXT, genre TEXT, year TEXT, charter TEXT, previewStart REAL, songLength REAL, delay REAL, diff TEXT, available TEXT);"
      "CREATE INDEX IF NOT EXISTS songs_path ON songs(path);";
  char* err = nullptr;
  if (sqlite3_exec(db, schema, nullptr, nullptr, &err) != SQLITE_OK) { fprintf(stderr, "library schema: %s\n", err ? err : "?"); sqlite3_free(err); }
  return db;
}
struct Stmt {
  sqlite3_stmt* st = nullptr;
  Stmt(sqlite3* db, const char* sql) { if (db) sqlite3_prepare_v2(db, sql, -1, &st, nullptr); }
  ~Stmt() { if (st) sqlite3_finalize(st); }
  Stmt& text(int i, const std::string& v) { if (st) sqlite3_bind_text(st, i, v.c_str(), -1, SQLITE_TRANSIENT); return *this; }
  Stmt& num(int i, double v) { if (st) sqlite3_bind_double(st, i, v); return *this; }
  Stmt& integer(int i, long long v) { if (st) sqlite3_bind_int64(st, i, v); return *this; }
  bool step() { return st && sqlite3_step(st) == SQLITE_ROW; }
  void run() { if (st) { sqlite3_step(st); sqlite3_reset(st); sqlite3_clear_bindings(st); } }
  std::string str(int c) const { const unsigned char* t = sqlite3_column_text(st, c); return t ? reinterpret_cast<const char*>(t) : ""; }
  double dbl(int c) const { return sqlite3_column_double(st, c); }
  int i32(int c) const { return sqlite3_column_int(st, c); }
};
// compact text encodings for the per-song maps
std::string encodeDiff(const SongMeta& m) { std::string s; for (const auto& [i, v] : m.diff) s += std::string(instrumentName(i)) + "=" + std::to_string(v) + ";"; return s; }
std::string encodeAvail(const SongEntry& e) { std::string s; for (const auto& a : e.available) s += std::string(instrumentName(a.instrument)) + ":" + difficultyName(a.difficulty) + ":" + std::to_string(a.noteCount) + ";"; return s; }
void decodeDiff(const std::string& s, SongMeta& m) {
  size_t p = 0;
  while (p < s.size()) { size_t eq = s.find('=', p), end = s.find(';', p); if (eq == std::string::npos || end == std::string::npos) break; m.diff[instrumentFromName(s.substr(p, eq - p))] = std::atoi(s.c_str() + eq + 1); p = end + 1; }
}
void decodeAvail(const std::string& s, SongEntry& e) {
  size_t p = 0;
  while (p < s.size()) {
    size_t c1 = s.find(':', p), c2 = c1 == std::string::npos ? c1 : s.find(':', c1 + 1), end = s.find(';', p);
    if (c1 == std::string::npos || c2 == std::string::npos || end == std::string::npos) break;
    e.available.push_back({instrumentFromName(s.substr(p, c1 - p)), difficultyFromName(s.substr(c1 + 1, c2 - c1 - 1)), std::atoi(s.c_str() + c2 + 1)});
    p = end + 1;
  }
}
}  // namespace

void Library::loadStore() {
  const std::string dbPath = supportDir() + "/library.sqlite";
  const std::string jsonPath = supportDir() + "/library.json";
  const bool fresh = !fs::exists(dbPath);
  db_ = openDb(dbPath);
  if (!db_) return;
  sqlite3* db = static_cast<sqlite3*>(db_);
  if (fresh && fs::exists(jsonPath)) {
    importJsonStore(jsonPath);  // one-time migration; the JSON file is kept as library.json.bak
    std::error_code ec;
    fs::rename(jsonPath, jsonPath + ".bak", ec);
  }
  { Stmt q(db, "SELECT key, score, stars, accuracy, notesHit, notesTotal, longestStreak, fullCombo, date FROM scores");
    while (q.step()) { ScoreRecord r; r.score = q.i32(1); r.stars = q.i32(2); r.accuracy = q.dbl(3); r.notesHit = q.i32(4); r.notesTotal = q.i32(5); r.longestStreak = q.i32(6); r.fullCombo = q.i32(7) != 0; r.date = q.dbl(8); scores_[q.str(0)] = r; } }
  { Stmt q(db, "SELECT key, songId, stars FROM career"); while (q.step()) career_[q.str(0)][q.str(1)] = q.i32(2); }
  { Stmt q(db, "SELECT key, date, score, stars, accuracy, speed, fullCombo, replay FROM history ORDER BY date");
    while (q.step()) { HistoryEntry h; h.date = q.dbl(1); h.score = q.i32(2); h.stars = q.i32(3); h.accuracy = q.dbl(4); h.speed = q.dbl(5); h.fullCombo = q.i32(6) != 0; h.replay = q.str(7); history_[q.str(0)].push_back(h); } }
  { Stmt q(db, "SELECT id, path, token, sng, hasAlbumArt, albumPath, name, artist, album, genre, year, charter, previewStart, songLength, delay, diff, available FROM songs");
    while (q.step()) {
      SongEntry e;
      e.id = q.str(0); e.path = q.str(1); e.sng = q.i32(3) != 0; e.hasAlbumArt = q.i32(4) != 0; e.albumPath = q.str(5);
      e.meta.name = q.str(6); e.meta.artist = q.str(7); e.meta.album = q.str(8); e.meta.genre = q.str(9); e.meta.year = q.str(10); e.meta.charter = q.str(11);
      e.meta.hasName = true; e.meta.previewStart = q.dbl(12); e.meta.songLength = q.dbl(13); e.meta.delay = q.dbl(14);
      decodeDiff(q.str(15), e.meta); decodeAvail(q.str(16), e);
      cache_[e.id] = {q.str(2), e};
    } }
}

// Reads the pre-SQLite library.json into the database.
void Library::importJsonStore(const std::string& path) {
  NSData* data = [NSData dataWithContentsOfFile:@(path.c_str())];
  NSDictionary* d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![d isKindOfClass:NSDictionary.class]) return;
  sqlite3* db = static_cast<sqlite3*>(db_);
  sqlite3_exec(db, "BEGIN", nullptr, nullptr, nullptr);
  NSDictionary* scores = d[@"scores"];
  for (NSString* k in scores) {
    NSDictionary* r = scores[k];
    ScoreRecord rec;
    rec.score = [r[@"score"] intValue]; rec.stars = [r[@"stars"] intValue]; rec.accuracy = [r[@"accuracy"] doubleValue];
    rec.notesHit = [r[@"notesHit"] intValue]; rec.notesTotal = [r[@"notesTotal"] intValue]; rec.longestStreak = [r[@"longestStreak"] intValue];
    rec.fullCombo = [r[@"fullCombo"] boolValue]; rec.date = [r[@"date"] doubleValue];
    writeScore(k.UTF8String, rec);
  }
  NSDictionary* career = d[@"career"];
  for (NSString* k in career) { NSDictionary* m = career[k]; for (NSString* song in m) writeCareer(k.UTF8String, song.UTF8String, [m[song] intValue]); }
  NSDictionary* hist = d[@"history"];
  for (NSString* k in hist) {
    const std::string ks = k.UTF8String;
    const std::string songId = ks.substr(0, ks.find(':'));
    for (NSDictionary* h in hist[k]) {
      if (![h isKindOfClass:NSDictionary.class]) continue;
      HistoryEntry e;
      e.date = [h[@"date"] doubleValue]; e.score = [h[@"score"] intValue]; e.stars = [h[@"stars"] intValue]; e.accuracy = [h[@"accuracy"] doubleValue]; e.speed = h[@"speed"] ? [h[@"speed"] doubleValue] : 1; e.fullCombo = [h[@"fullCombo"] boolValue];
      if ([h[@"replay"] isKindOfClass:NSString.class]) e.replay = [h[@"replay"] UTF8String];
      insertHistory(ks, songId, e);
    }
  }
  std::vector<std::pair<std::string, SongEntry>> songs;
  NSDictionary* js = d[@"songs"];
  for (NSString* id in js) {
    NSDictionary* e = js[id];
    if (![e isKindOfClass:NSDictionary.class] || ![e[@"path"] isKindOfClass:NSString.class]) continue;
    SongEntry s;
    s.id = id.UTF8String; s.path = [e[@"path"] UTF8String]; s.sng = [e[@"sng"] boolValue]; s.hasAlbumArt = [e[@"hasAlbumArt"] boolValue];
    if ([e[@"albumPath"] isKindOfClass:NSString.class]) s.albumPath = [e[@"albumPath"] UTF8String];
    NSDictionary* m = e[@"meta"];
    auto str = [&](NSString* k, std::string& out) { if ([m[k] isKindOfClass:NSString.class]) out = [m[k] UTF8String]; };
    str(@"name", s.meta.name); str(@"artist", s.meta.artist); str(@"album", s.meta.album); str(@"genre", s.meta.genre); str(@"year", s.meta.year); str(@"charter", s.meta.charter);
    s.meta.hasName = true; s.meta.previewStart = [m[@"previewStart"] doubleValue]; s.meta.songLength = [m[@"songLength"] doubleValue]; s.meta.delay = [m[@"delay"] doubleValue];
    NSDictionary* diff = m[@"diff"];
    for (NSString* k in diff) s.meta.diff[instrumentFromName(k.UTF8String)] = [diff[k] intValue];
    for (NSArray* a in e[@"available"]) if ([a isKindOfClass:NSArray.class] && a.count == 3) s.available.push_back({instrumentFromName([a[0] UTF8String]), difficultyFromName([a[1] UTF8String]), [a[2] intValue]});
    songs.emplace_back([e[@"token"] isKindOfClass:NSString.class] ? [e[@"token"] UTF8String] : "", s);
  }
  sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr);
  upsertSongs(songs);
}

void Library::writeScore(const std::string& k, const ScoreRecord& r) {
  Stmt q(static_cast<sqlite3*>(db_), "INSERT OR REPLACE INTO scores(key, score, stars, accuracy, notesHit, notesTotal, longestStreak, fullCombo, date) VALUES(?,?,?,?,?,?,?,?,?)");
  q.text(1, k).integer(2, r.score).integer(3, r.stars).num(4, r.accuracy).integer(5, r.notesHit).integer(6, r.notesTotal).integer(7, r.longestStreak).integer(8, r.fullCombo).num(9, r.date).run();
}
void Library::writeCareer(const std::string& k, const std::string& songId, int stars) {
  Stmt q(static_cast<sqlite3*>(db_), "INSERT OR REPLACE INTO career(key, songId, stars) VALUES(?,?,?)");
  q.text(1, k).text(2, songId).integer(3, stars).run();
}
void Library::insertHistory(const std::string& k, const std::string& songId, const HistoryEntry& h) {
  Stmt q(static_cast<sqlite3*>(db_), "INSERT INTO history(key, songId, date, score, stars, accuracy, speed, fullCombo, replay) VALUES(?,?,?,?,?,?,?,?,?)");
  q.text(1, k).text(2, songId).num(3, h.date).integer(4, h.score).integer(5, h.stars).num(6, h.accuracy).num(7, h.speed).integer(8, h.fullCombo).text(9, h.replay).run();
}
void Library::upsertSongs(const std::vector<std::pair<std::string, SongEntry>>& songs) {
  sqlite3* db = static_cast<sqlite3*>(db_);
  if (!db) return;
  sqlite3_exec(db, "BEGIN", nullptr, nullptr, nullptr);
  Stmt q(db, "INSERT OR REPLACE INTO songs(id, path, token, sng, hasAlbumArt, albumPath, name, artist, album, genre, year, charter, previewStart, songLength, delay, diff, available) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
  for (const auto& [token, e] : songs) {
    q.text(1, e.id).text(2, e.path).text(3, token).integer(4, e.sng).integer(5, e.hasAlbumArt).text(6, e.albumPath).text(7, e.meta.name).text(8, e.meta.artist).text(9, e.meta.album).text(10, e.meta.genre).text(11, e.meta.year).text(12, e.meta.charter)
     .num(13, e.meta.previewStart).num(14, e.meta.songLength).num(15, e.meta.delay).text(16, encodeDiff(e.meta)).text(17, encodeAvail(e)).run();
  }
  sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr);
}
void Library::deleteSongsUnder(const std::string& folder) {
  Stmt q(static_cast<sqlite3*>(db_), "DELETE FROM songs WHERE substr(path, 1, ?) = ?");
  q.integer(1, (long long)folder.size()).text(2, folder).run();
}

}  // namespace gc

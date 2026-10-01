// Song library: scans song folders, caches metadata, tracks scores and career progress.
#pragma once
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "core/types.h"

namespace gc {

struct SongAvailability { Instrument instrument; Difficulty difficulty; int noteCount; };

struct SongEntry {
  std::string id;      // hash of path
  std::string path;    // folder
  SongMeta meta;
  std::vector<SongAvailability> available;
  bool builtin = false;
  bool sng = false;    // path is a .sng package
  bool hasAlbumArt = false;
  std::string albumPath;
  const SongAvailability* find(Instrument i, Difficulty d) const {
    for (const auto& a : available) if (a.instrument == i && a.difficulty == d) return &a;
    return nullptr;
  }
};

struct HistoryEntry { double date = 0; int score = 0, stars = 0; double accuracy = 0, speed = 1; bool fullCombo = false; std::string replay; };

struct ScoreRecord { int score = 0; int stars = 0; double accuracy = 0; int notesHit = 0, notesTotal = 0, longestStreak = 0; bool fullCombo = false; double date = 0; };

struct ScanProgress { int done = 0, total = 0; bool scanning = false; };

class Library {
 public:
  static Library& instance();
  void setBuiltinFolder(const std::string& folder);
  void restore();                                 // loads the cache (instant) and rescans saved folders in the background
  void addFolder(const std::string& folder);      // persists and scans recursively in the background
  void removeFolder(const std::string& folder);
  std::string addTemporarySong(const std::string& folder);  // scans one song folder into the list without persisting; returns its id
  ScanProgress scan() const { return scan_; }
  std::function<void(ScanProgress)> onScan;       // main thread; progress while scanning
  const std::vector<SongEntry>& entries() const { return entries_; }
  const SongEntry* byId(const std::string& id) const;
  // scores
  const ScoreRecord* score(const std::string& songId, Instrument i, Difficulty d) const;
  bool saveScore(const std::string& songId, Instrument i, Difficulty d, const ScoreRecord& r);  // true if new record
  void addHistory(const std::string& songId, Instrument i, Difficulty d, const HistoryEntry& h);  // every completed run
  const std::vector<HistoryEntry>* history(const std::string& songId, Instrument i, Difficulty d) const;
  double lastPlayed(const std::string& songId) const;  // newest history date across instruments, 0 if never
  // career: songId -> stars
  std::map<std::string, int> careerProgress(Instrument i, Difficulty d) const;
  void recordCareer(Instrument i, Difficulty d, const std::string& songId, int stars);
  std::function<void()> onChanged;

 private:
  void scanFoldersAsync(std::vector<std::string> folders);
  // SQLite store (library.sqlite): incremental writes, the in-memory maps are the read cache
  void loadStore();
  void importJsonStore(const std::string& path);
  void writeScore(const std::string& key, const ScoreRecord& r);
  void writeCareer(const std::string& key, const std::string& songId, int stars);
  void insertHistory(const std::string& key, const std::string& songId, const HistoryEntry& h);
  void upsertSongs(const std::vector<std::pair<std::string, SongEntry>>& songs);  // (token, entry)
  void deleteSongsUnder(const std::string& folder);
  void* db_ = nullptr;
  std::string builtin_;
  std::vector<SongEntry> entries_;
  std::map<std::string, std::pair<std::string, SongEntry>> cache_;  // id -> (token, entry) from library.json
  ScanProgress scan_;
  int scanGeneration_ = 0;
  std::map<std::string, ScoreRecord> scores_;                 // key "id:inst:diff"
  std::map<std::string, std::vector<HistoryEntry>> history_;  // key "id:inst:diff", newest last
  std::map<std::string, std::map<std::string, int>> career_;  // key "inst:diff" -> songId -> stars
};

}  // namespace gc

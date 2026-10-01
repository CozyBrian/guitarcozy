#pragma once
#include <memory>
#include <string>
#include <vector>
#include "audio/decoder.h"
#include "core/types.h"

namespace gc {

struct LoadedSong {
  Chart chart;
  SongMeta meta;
  struct Stem { std::string name; std::shared_ptr<audio::StreamingStem> stream; };
  std::vector<Stem> stems;
  std::string folder;
};

// Loads a Clone Hero style song folder (song.ini + notes.chart/notes.mid + audio stems).
std::unique_ptr<LoadedSong> loadSongFolder(const std::string& folder, std::string* error);
// A song path is either a folder or a .sng file; .sng packages are unpacked once into the cache
// folder (~/Library/Application Support/GuitarCozy/sng/<hash>) and that folder is returned.
std::string resolveSongFolder(const std::string& path, std::string* error);
std::unique_ptr<LoadedSong> loadSong(const std::string& path, std::string* error);
bool isSngPath(const std::string& path);

}  // namespace gc

// Clone Hero `.sng` single-file song container (https://github.com/mdsitton/SngFileFormat).
#pragma once
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace gc {

struct SngEntry { std::string name; uint64_t offset = 0, size = 0; };  // offset is absolute within the file
struct SngHeader {
  uint32_t version = 0;
  uint8_t xorMask[16] = {};
  std::vector<std::pair<std::string, std::string>> metadata;
  std::vector<SngEntry> files;
  uint64_t dataStart = 0, dataLen = 0;
  uint64_t headerEnd() const { return dataStart; }
  const SngEntry* find(const std::string& lowerName) const;
};

bool isSng(const uint8_t* bytes, size_t len);
// Parses header, metadata and file index from the start of the file. Throws std::runtime_error on
// truncation ("SNG: unexpected end") so callers can retry with a longer prefix.
SngHeader parseSngHeader(const uint8_t* bytes, size_t len);
// De-masks `size` bytes of an entry's contents that start at byte `entry.offset` of the file.
std::vector<uint8_t> unmaskSngFile(const SngHeader& h, const uint8_t* masked, size_t size);
// Renders the metadata as song.ini text ([song] section).
std::string sngMetadataToIni(const SngHeader& h);

}  // namespace gc

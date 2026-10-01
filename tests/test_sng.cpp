#include <cstring>
#include "core/sng.h"
#include "core/song_ini.h"
#include "test.h"

using namespace gc;

namespace {
void put32(std::vector<uint8_t>& b, uint32_t v) { for (int i = 0; i < 4; i++) b.push_back(uint8_t(v >> (8 * i))); }
void put64(std::vector<uint8_t>& b, uint64_t v) { for (int i = 0; i < 8; i++) b.push_back(uint8_t(v >> (8 * i))); }
void putStr(std::vector<uint8_t>& b, const std::string& s) { b.insert(b.end(), s.begin(), s.end()); }

// Builds a minimal .sng with two files and two metadata pairs.
std::vector<uint8_t> buildSng(const std::vector<std::pair<std::string, std::string>>& files) {
  std::vector<uint8_t> b = {0x53, 0x4e, 0x47, 0x50, 0x4b, 0x47};
  put32(b, 1);
  uint8_t mask[16];
  for (int i = 0; i < 16; i++) { mask[i] = uint8_t(i * 37 + 5); b.push_back(mask[i]); }
  std::vector<uint8_t> meta;
  put64(meta, 2);
  for (auto [k, v] : {std::pair{"name", "Test Song"}, std::pair{"artist", "Unit"}}) { put32(meta, uint32_t(strlen(k))); putStr(meta, k); put32(meta, uint32_t(strlen(v))); putStr(meta, v); }
  put64(b, meta.size()); b.insert(b.end(), meta.begin(), meta.end());
  std::vector<uint8_t> index;
  put64(index, files.size());
  // compute data start: after index section + 8 (dataLen)
  size_t indexLen = 8;
  for (const auto& f : files) indexLen += 1 + f.first.size() + 16;
  const uint64_t dataStart = b.size() + 8 + indexLen + 8;
  uint64_t off = dataStart, total = 0;
  for (const auto& f : files) { index.push_back(uint8_t(f.first.size())); putStr(index, f.first); put64(index, f.second.size()); put64(index, off); off += f.second.size(); total += f.second.size(); }
  put64(b, index.size()); b.insert(b.end(), index.begin(), index.end());
  put64(b, total);
  for (const auto& f : files) for (size_t i = 0; i < f.second.size(); i++) b.push_back(uint8_t(f.second[i]) ^ uint8_t(mask[i % 16] ^ (i & 0xff)));
  return b;
}
}  // namespace

TEST(sng_roundtrip) {
  const std::string chart = "[Song]\n{\n  Resolution = 192\n}\n";
  auto bytes = buildSng({{"notes.chart", chart}, {"song.ogg", std::string(300, 'x')}});
  CHECK(isSng(bytes.data(), bytes.size()));
  auto h = parseSngHeader(bytes.data(), bytes.size());
  CHECK(h.version == 1);
  CHECK(h.files.size() == 2);
  const SngEntry* e = h.find("notes.chart");
  CHECK(e != nullptr);
  auto out = unmaskSngFile(h, bytes.data() + e->offset, size_t(e->size));
  CHECK(std::string(out.begin(), out.end()) == chart);
  auto meta = parseSongIni(sngMetadataToIni(h));
  CHECK(meta.name == "Test Song");
  CHECK(meta.artist == "Unit");
  // a truncated prefix must throw so the scanner can retry with more bytes
  bool threw = false;
  try { parseSngHeader(bytes.data(), 40); } catch (const std::exception&) { threw = true; }
  CHECK(threw);
}

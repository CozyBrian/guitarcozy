#include "sng.h"
#include <stdexcept>
#include "text_util.h"

namespace gc {

static const uint8_t MAGIC[6] = {0x53, 0x4e, 0x47, 0x50, 0x4b, 0x47};

bool isSng(const uint8_t* b, size_t len) {
  if (len < 6) return false;
  for (int i = 0; i < 6; i++) if (b[i] != MAGIC[i]) return false;
  return true;
}

namespace {
struct Reader {
  const uint8_t* b; size_t len; size_t pos = 0;
  void need(size_t n) const { if (pos + n > len) throw std::runtime_error("SNG: unexpected end of file"); }
  uint8_t u8() { need(1); return b[pos++]; }
  uint32_t u32() { need(4); uint32_t v = 0; for (int i = 0; i < 4; i++) v |= uint32_t(b[pos + i]) << (8 * i); pos += 4; return v; }
  int32_t i32() { return int32_t(u32()); }
  uint64_t u64() { need(8); uint64_t v = 0; for (int i = 0; i < 8; i++) v |= uint64_t(b[pos + i]) << (8 * i); pos += 8; return v; }
  std::string str(int64_t n) { if (n < 0) throw std::runtime_error("SNG: negative string length"); need(size_t(n)); std::string s(reinterpret_cast<const char*>(b + pos), size_t(n)); pos += size_t(n); return s; }
};
}  // namespace

const SngEntry* SngHeader::find(const std::string& lowerName) const {
  for (const auto& f : files) if (toLower(f.name) == lowerName) return &f;
  return nullptr;
}

SngHeader parseSngHeader(const uint8_t* bytes, size_t len) {
  if (!isSng(bytes, len)) throw std::runtime_error("Not an SNG file");
  Reader r{bytes, len, 6};
  SngHeader h;
  h.version = r.u32();
  r.need(16);
  for (int i = 0; i < 16; i++) h.xorMask[i] = bytes[r.pos + i];
  r.pos += 16;
  const uint64_t metaLen = r.u64();
  const size_t metaStart = r.pos;
  const uint64_t metaCount = r.u64();
  for (uint64_t i = 0; i < metaCount; i++) {
    const int32_t kl = r.i32();
    std::string k = r.str(kl);
    const int32_t vl = r.i32();
    std::string v = r.str(vl);
    h.metadata.emplace_back(std::move(k), std::move(v));
  }
  r.pos = metaStart + size_t(metaLen);
  const uint64_t fileMetaLen = r.u64();
  const size_t fileMetaStart = r.pos;
  const uint64_t fileCount = r.u64();
  for (uint64_t i = 0; i < fileCount; i++) {
    SngEntry e;
    const uint8_t nl = r.u8();
    e.name = r.str(nl);
    e.size = r.u64();
    e.offset = r.u64();
    h.files.push_back(std::move(e));
  }
  r.pos = fileMetaStart + size_t(fileMetaLen);
  h.dataLen = r.u64();
  h.dataStart = r.pos;
  for (const auto& f : h.files)
    if (f.offset < h.dataStart || f.offset + f.size > h.dataStart + h.dataLen) throw std::runtime_error("SNG: file \"" + f.name + "\" lies outside the file data section");
  return h;
}

std::vector<uint8_t> unmaskSngFile(const SngHeader& h, const uint8_t* masked, size_t size) {
  std::vector<uint8_t> out(size);
  for (size_t i = 0; i < size; i++) out[i] = masked[i] ^ uint8_t(h.xorMask[i % 16] ^ (i & 0xff));
  return out;
}

std::string sngMetadataToIni(const SngHeader& h) {
  std::string s = "[song]\n";
  for (const auto& [k, v] : h.metadata) s += k + " = " + v + "\n";
  return s;
}

}  // namespace gc

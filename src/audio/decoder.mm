#import <AudioToolbox/AudioToolbox.h>
#include <cstdio>
#include <cstring>
#include <ogg/ogg.h>
#include <opus.h>
#include <vorbis/vorbisfile.h>
#include "decoder.h"
#include <thread>
#include <algorithm>
#include <cmath>

namespace gc::audio {

namespace {

std::string lowerExt(const std::string& path) {
  size_t dot = path.rfind('.');
  if (dot == std::string::npos) return "";
  std::string e = path.substr(dot + 1);
  for (auto& c : e) c = char(tolower(c));
  return e;
}

bool fileHasMarker(const std::string& path, const char* marker) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  char buf[128];
  size_t n = fread(buf, 1, sizeof buf, f);
  fclose(f);
  size_t ml = strlen(marker);
  for (size_t i = 0; i + ml <= n; i++) if (memcmp(buf + i, marker, ml) == 0) return true;
  return false;
}

// ---- pull sources: open() reports format + total frames (0 = unknown), read() fills interleaved floats
struct Source {
  virtual ~Source() = default;
  virtual bool open(const std::string& path, std::string* error, int& rate, int& channels, size_t& totalFrames) = 0;
  virtual size_t read(float* dst, size_t maxFrames) = 0;  // 0 = end
};

struct VorbisSource : Source {
  OggVorbis_File vf{};
  bool opened = false;
  int ch = 2;
  ~VorbisSource() override { if (opened) ov_clear(&vf); }
  bool open(const std::string& path, std::string* error, int& rate, int& channels, size_t& total) override {
    if (ov_fopen(path.c_str(), &vf) != 0) { if (error) *error = "not an Ogg Vorbis file"; return false; }
    opened = true;
    vorbis_info* vi = ov_info(&vf, -1);
    rate = int(vi->rate); channels = ch = vi->channels;
    const ogg_int64_t t = ov_pcm_total(&vf, -1);
    total = t > 0 ? size_t(t) : 0;
    return true;
  }
  size_t read(float* dst, size_t maxFrames) override {
    float** pcm = nullptr; int section = 0;
    long got = ov_read_float(&vf, &pcm, int(std::min<size_t>(maxFrames, 4096)), &section);
    if (got <= 0) return 0;
    for (long i = 0; i < got; i++) for (int c = 0; c < ch; c++) dst[i * ch + c] = pcm[c][i];
    return size_t(got);
  }
};

// total length of an Ogg stream from the granule position of its last page
int64_t oggLastGranule(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return -1;
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  const long want = std::min<long>(size, 256 * 1024);
  fseek(f, size - want, SEEK_SET);
  std::vector<unsigned char> tail(static_cast<size_t>(want), 0);
  const size_t n = fread(tail.data(), 1, tail.size(), f);
  fclose(f);
  for (size_t i = n; i-- > 27;) {
    if (memcmp(tail.data() + i - 0, "OggS", 4) == 0 && i + 14 <= n) {
      int64_t g = 0;
      for (int k = 0; k < 8; k++) g |= int64_t(tail[i + 6 + k]) << (8 * k);
      return g;
    }
  }
  return -1;
}

struct OpusSource : Source {
  FILE* f = nullptr;
  ogg_sync_state oy{};
  ogg_stream_state os{};
  bool streamInit = false, eof = false;
  OpusDecoder* dec = nullptr;
  int ch = 2, preSkip = 0, packetIndex = 0;
  size_t skipLeft = 0;
  std::vector<float> tmp;
  std::vector<float> pending;  // decoded frames not yet handed out
  ~OpusSource() override {
    if (dec) opus_decoder_destroy(dec);
    if (streamInit) ogg_stream_clear(&os);
    ogg_sync_clear(&oy);
    if (f) fclose(f);
  }
  bool pumpPacket() {  // decodes until `pending` has data or the file ends
    while (pending.empty() && !eof) {
      ogg_packet op;
      while (streamInit && ogg_stream_packetout(&os, &op) == 1) {
        if (packetIndex == 0) {
          if (op.bytes < 19 || memcmp(op.packet, "OpusHead", 8) != 0) { eof = true; return false; }
          ch = op.packet[9]; preSkip = op.packet[10] | (op.packet[11] << 8); skipLeft = size_t(preSkip);
          int err = 0; dec = opus_decoder_create(48000, ch, &err);
          if (err != OPUS_OK || ch > 2) { eof = true; return false; }
        } else if (packetIndex >= 2 && dec) {
          tmp.resize(5760 * size_t(ch));
          int got = opus_decode_float(dec, op.packet, int(op.bytes), tmp.data(), 5760, 0);
          if (got > 0) {
            size_t skip = std::min<size_t>(skipLeft, size_t(got)); skipLeft -= skip;
            pending.insert(pending.end(), tmp.begin() + skip * ch, tmp.begin() + size_t(got) * ch);
          }
        }
        packetIndex++;
        if (!pending.empty()) return true;
      }
      ogg_page og;
      if (ogg_sync_pageout(&oy, &og) == 1) {
        if (!streamInit) { ogg_stream_init(&os, ogg_page_serialno(&og)); streamInit = true; }
        ogg_stream_pagein(&os, &og);
        continue;
      }
      char* buf = ogg_sync_buffer(&oy, 8192);
      size_t n = fread(buf, 1, 8192, f);
      if (n == 0) { eof = true; break; }
      ogg_sync_wrote(&oy, long(n));
    }
    return !pending.empty();
  }
  bool open(const std::string& path, std::string* error, int& rate, int& channels, size_t& total) override {
    f = fopen(path.c_str(), "rb");
    if (!f) { if (error) *error = "cannot open"; return false; }
    ogg_sync_init(&oy);
    // read far enough to see the header packet
    while (packetIndex == 0 && !eof) { if (!pumpPacket() && packetIndex == 0 && eof) break; }
    if (!dec) { if (error) *error = "not an Ogg Opus stream"; return false; }
    rate = 48000; channels = ch;
    const int64_t g = oggLastGranule(path);
    total = g > preSkip ? size_t(g - preSkip) : 0;
    return true;
  }
  size_t read(float* dst, size_t maxFrames) override {
    if (!pumpPacket()) return 0;
    const size_t frames = std::min(maxFrames, pending.size() / size_t(ch));
    std::copy(pending.begin(), pending.begin() + frames * ch, dst);
    pending.erase(pending.begin(), pending.begin() + frames * ch);
    return frames;
  }
};

struct ATSource : Source {
  ExtAudioFileRef file = nullptr;
  int ch = 2;
  ~ATSource() override { if (file) ExtAudioFileDispose(file); }
  bool open(const std::string& path, std::string* error, int& rate, int& channels, size_t& total) override {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path.c_str()), CFIndex(path.size()), false);
    OSStatus st = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (st != noErr) { if (error) *error = "AudioToolbox could not open file (" + std::to_string(st) + ")"; file = nullptr; return false; }
    AudioStreamBasicDescription in{};
    UInt32 size = sizeof in;
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &in);
    ch = in.mChannelsPerFrame > 0 ? int(in.mChannelsPerFrame) : 2;
    rate = in.mSampleRate > 0 ? int(in.mSampleRate) : 44100;
    channels = ch;
    AudioStreamBasicDescription out{};
    out.mSampleRate = rate; out.mFormatID = kAudioFormatLinearPCM; out.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    out.mBitsPerChannel = 32; out.mChannelsPerFrame = ch; out.mBytesPerFrame = 4 * ch; out.mFramesPerPacket = 1; out.mBytesPerPacket = out.mBytesPerFrame;
    st = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof out, &out);
    if (st != noErr) { if (error) *error = "unsupported format"; return false; }
    SInt64 len = 0; size = sizeof len;
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &len);
    total = len > 0 ? size_t(len) : 0;
    return true;
  }
  size_t read(float* dst, size_t maxFrames) override {
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = ch;
    list.mBuffers[0].mDataByteSize = UInt32(maxFrames * ch * sizeof(float));
    list.mBuffers[0].mData = dst;
    UInt32 frames = UInt32(maxFrames);
    if (ExtAudioFileRead(file, &frames, &list) != noErr) return 0;
    return frames;
  }
};

std::unique_ptr<Source> sourceFor(const std::string& path) {
  const std::string ext = lowerExt(path);
  if (ext == "opus" || (ext == "ogg" && fileHasMarker(path, "OpusHead"))) return std::make_unique<OpusSource>();
  if (ext == "ogg") return std::make_unique<VorbisSource>();
  return std::make_unique<ATSource>();
}

}  // namespace

void StreamingStem::wait() const { while (!done.load(std::memory_order_acquire)) std::this_thread::sleep_for(std::chrono::milliseconds(2)); }

std::shared_ptr<StreamingStem> decodeAudioFileAsync(const std::string& path) {
  auto stem = std::make_shared<StreamingStem>();
  stem->pcm = std::make_shared<PcmBuffer>();
  auto src = std::shared_ptr<Source>(sourceFor(path).release());
  int rate = 44100, channels = 2; size_t total = 0;
  std::string err;
  if (!src->open(path, &err, rate, channels, total)) { stem->error = err; stem->failed = true; stem->done = true; return stem; }
  stem->pcm->sampleRate = rate; stem->pcm->channels = channels;
  const bool known = total > 0;
  // storage is fixed up front so readers can hold the data pointer while the writer fills it
  if (known) stem->pcm->samples.assign((total + 4096) * size_t(channels), 0.f);
  std::thread([stem, src, channels, known]() {
    const size_t chunk = 8192;
    std::vector<float> buf(chunk * size_t(channels));
    size_t written = 0;
    for (;;) {
      const size_t got = src->read(buf.data(), chunk);
      if (!got) break;
      if (known) {
        const size_t room = stem->pcm->frames() > written ? stem->pcm->frames() - written : 0;
        const size_t n = std::min(got, room);
        if (n) std::copy(buf.begin(), buf.begin() + n * channels, stem->pcm->samples.begin() + written * channels);
        written += n;
        stem->ready.store(written, std::memory_order_release);
        if (n < got) break;
      } else {
        stem->pcm->samples.insert(stem->pcm->samples.end(), buf.begin(), buf.begin() + got * channels);
        written += got;  // unknown length: published only when complete
      }
    }
    if (known) stem->pcm->samples.resize(std::max(written, size_t(1)) * channels);
    stem->ready.store(written, std::memory_order_release);
    stem->done.store(true, std::memory_order_release);
  }).detach();
  return stem;
}

std::optional<PcmBuffer> decodeAudioFile(const std::string& path, std::string* error) {
  auto stem = decodeAudioFileAsync(path);
  stem->wait();
  if (stem->failed) { if (error) *error = stem->error; return std::nullopt; }
  return std::move(*stem->pcm);
}

}  // namespace gc::audio

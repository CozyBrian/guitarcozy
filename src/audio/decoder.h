#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace gc::audio {

struct PcmBuffer {
  int sampleRate = 44100;
  int channels = 2;
  std::vector<float> samples;  // interleaved
  size_t frames() const { return channels ? samples.size() / channels : 0; }
  double duration() const { return sampleRate ? double(frames()) / sampleRate : 0; }
};

// A stem that is still being decoded: storage is allocated up front from the file's length, a background
// thread fills it and publishes `ready` (frames) with release semantics; readers never touch frames past it.
struct StreamingStem {
  std::shared_ptr<PcmBuffer> pcm;
  std::atomic<size_t> ready{0};
  std::atomic<bool> done{false};
  std::atomic<bool> failed{false};
  std::string error;
  void wait() const;  // block until decoding finished
};

// Decodes WAV/MP3/AAC/FLAC/M4A via AudioToolbox and Ogg Vorbis / Opus via libvorbis / libopus.
std::optional<PcmBuffer> decodeAudioFile(const std::string& path, std::string* error = nullptr);
// Returns as soon as the header is read; playback can start while the rest decodes.
std::shared_ptr<StreamingStem> decodeAudioFileAsync(const std::string& path);

}  // namespace gc::audio

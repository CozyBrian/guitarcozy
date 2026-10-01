#include "midi_parser.h"
#include <algorithm>
#include <map>
#include <set>
#include <stdexcept>
#include "tempo.h"
#include "text_util.h"
#include "track.h"

namespace gc {

namespace {

constexpr int META_TEXT = 0x01, META_TRACK_NAME = 0x03, META_LYRIC = 0x05, META_END = 0x2F, META_TEMPO = 0x51, META_TIMESIG = 0x58;
constexpr int NOTE_SOLO = 103, NOTE_TAP = 104, NOTE_STAR_POWER = 116;

struct MidiNoteEvent { int tick; int note; int velocity; int channel; bool on; };
struct MidiMeta { int tick; int type; std::vector<uint8_t> data; };
struct MidiSysex { int tick; std::vector<uint8_t> data; };
struct MidiTrack {
  std::string name;
  std::vector<MidiNoteEvent> notes;
  std::vector<MidiMeta> metas;
  std::vector<MidiSysex> sysex;
  int endTick = 0;
};
struct MidiFile { int format = 1; int division = 480; std::vector<MidiTrack> tracks; };

uint32_t u32(const std::vector<uint8_t>& d, size_t p) {
  auto b = [&](size_t i) -> uint32_t { return i < d.size() ? d[i] : 0; };
  return (b(p) << 24) | (b(p + 1) << 16) | (b(p + 2) << 8) | b(p + 3);
}
uint16_t u16(const std::vector<uint8_t>& d, size_t p) {
  auto b = [&](size_t i) -> uint32_t { return i < d.size() ? d[i] : 0; };
  return uint16_t((b(p) << 8) | b(p + 1));
}

std::string metaText(const std::vector<uint8_t>& d) {
  std::string s(d.begin(), d.end());
  while (!s.empty() && s.back() == '\0') s.pop_back();
  return s;
}

MidiTrack parseTrackChunk(const std::vector<uint8_t>& buf, size_t start, size_t end) {
  MidiTrack track;
  size_t p = start;
  int tick = 0;
  int running = 0;
  auto readVlq = [&]() {
    int v = 0;
    for (int i = 0; i < 4 && p < end; i++) {
      uint8_t b = buf[p++];
      v = v * 128 + (b & 0x7F);
      if (!(b & 0x80)) break;
    }
    return v;
  };
  while (p < end) {
    tick += readVlq();
    if (p >= end) break;
    int status = buf[p];
    if (status < 0x80) {
      if (!running) break;
      status = running;
    } else p++;
    if (status == 0xFF) {
      if (p >= end) break;
      int type = buf[p++];
      int len = readVlq();
      size_t e = std::min(end, p + size_t(len));
      track.metas.push_back(MidiMeta{tick, type, std::vector<uint8_t>(buf.begin() + p, buf.begin() + e)});
      p += size_t(len);
      if (type == META_END) break;
    } else if (status == 0xF0 || status == 0xF7) {
      int len = readVlq();
      size_t e = std::min(end, p + size_t(len));
      track.sysex.push_back(MidiSysex{tick, std::vector<uint8_t>(buf.begin() + p, buf.begin() + e)});
      p += size_t(len);
    } else if (status >= 0x80 && status < 0xF0) {
      running = status;
      const int hi = status & 0xF0;
      const int nData = (hi == 0xC0 || hi == 0xD0) ? 1 : 2;
      if (p + nData > end) break;
      const int d1 = buf[p];
      const int d2 = nData == 2 ? buf[p + 1] : 0;
      p += nData;
      if (hi == 0x90 || hi == 0x80) track.notes.push_back(MidiNoteEvent{tick, d1, d2, status & 0x0F, hi == 0x90 && d2 > 0});
    } else {
      if (status == 0xF2) p += 2;
      else if (status == 0xF1 || status == 0xF3) p += 1;
    }
    track.endTick = std::max(track.endTick, tick);
  }
  for (const auto& m : track.metas) if (m.type == META_TRACK_NAME) { track.name = trim(metaText(m.data)); break; }
  return track;
}

MidiFile parseMidiFile(const std::vector<uint8_t>& data) {
  if (data.size() < 8 || std::string(data.begin(), data.begin() + 4) != "MThd") throw std::runtime_error("Not a MIDI file");
  const uint32_t headerLen = u32(data, 4);
  MidiFile file;
  file.format = u16(data, 8);
  const uint16_t division = u16(data, 12);
  if (division & 0x8000) throw std::runtime_error("SMPTE time division MIDI files are not supported");
  file.division = division > 0 ? division : 480;
  size_t pos = 8 + std::max<size_t>(6, headerLen);
  while (pos + 8 <= data.size()) {
    const std::string id(data.begin() + pos, data.begin() + pos + 4);
    const uint32_t len = u32(data, pos + 4);
    pos += 8;
    const size_t end = std::min(data.size(), pos + size_t(len));
    if (id == "MTrk") file.tracks.push_back(parseTrackChunk(data, pos, end));
    pos = end;
  }
  return file;
}

struct MidiNote { int note; int tick; int length; int channel; };

std::vector<MidiNote> matchNotes(const MidiTrack& track) {
  std::vector<MidiNote> out;
  std::map<int, std::vector<size_t>> pending;
  for (const auto& ev : track.notes) {
    const int key = ev.note + ev.channel * 128;
    if (ev.on) {
      out.push_back(MidiNote{ev.note, ev.tick, 0, ev.channel});
      pending[key].push_back(out.size() - 1);
    } else {
      auto& list = pending[key];
      if (!list.empty()) {
        out[list.front()].length = std::max(0, ev.tick - out[list.front()].tick);
        list.erase(list.begin());
      }
    }
  }
  return out;
}

std::vector<RawRange> rangesFor(const std::vector<MidiNote>& notes, int noteNumber) {
  std::vector<RawRange> out;
  for (const auto& n : notes) if (n.note == noteNumber) out.push_back(RawRange{n.tick, n.length});
  return out;
}

bool anyContains(const std::vector<RawRange>& ranges, int tick) {
  for (const auto& r : ranges) {
    if (r.length <= 0 ? tick == r.tick : (tick >= r.tick && tick < r.tick + r.length)) return true;
  }
  return false;
}

struct PhaseShift { std::vector<RawRange> open[4], tap[4]; };

PhaseShift parsePhaseShift(const MidiTrack& track) {
  PhaseShift ps;
  std::map<std::pair<int, int>, int> pending;  // (type, diff) -> start tick
  for (const auto& ev : track.sysex) {
    const auto& d = ev.data;
    if (d.size() < 7 || d[0] != 0x50 || d[1] != 0x53 || d[2] != 0 || d[3] != 0) continue;
    const int dd = d[4], type = d[5];
    const bool on = d[6] == 1;
    if (type != 0x01 && type != 0x04) continue;
    std::vector<int> diffs;
    if (dd == 0xFF) diffs = {0, 1, 2, 3};
    else if (dd < 4) diffs = {dd};
    for (int diff : diffs) {
      auto key = std::make_pair(type, diff);
      if (on) { if (!pending.count(key)) pending[key] = ev.tick; }
      else {
        auto it = pending.find(key);
        if (it != pending.end()) {
          (type == 0x01 ? ps.open : ps.tap)[diff].push_back(RawRange{it->second, std::max(0, ev.tick - it->second)});
          pending.erase(it);
        }
      }
    }
  }
  for (const auto& [key, start] : pending) (key.first == 0x01 ? ps.open : ps.tap)[key.second].push_back(RawRange{start, std::max(0, track.endTick - start)});
  return ps;
}

const Difficulty kDiffs[4] = {Difficulty::Easy, Difficulty::Medium, Difficulty::Hard, Difficulty::Expert};
const int kDiffBase[4] = {60, 72, 84, 96};

struct Built { std::vector<Track> tracks; int endTick = 0; double chartLength = 0; };

Built buildInstrumentTracks(Instrument instrument, const MidiTrack& track, const TempoMap& tempo, const MidiParseOptions& opts) {
  const auto notes = matchNotes(track);
  const auto ps = parsePhaseShift(track);
  bool has116 = false, has103 = false;
  for (const auto& n : notes) { if (n.note == NOTE_STAR_POWER) has116 = true; if (n.note == NOTE_SOLO) has103 = true; }
  const int spNote = (opts.multiplierNote == NOTE_SOLO && !has116 && has103) ? NOTE_SOLO : NOTE_STAR_POWER;
  const auto starPower = rangesFor(notes, spNote);
  const auto solos = spNote == NOTE_SOLO ? std::vector<RawRange>{} : rangesFor(notes, NOTE_SOLO);
  const auto globalTaps = rangesFor(notes, NOTE_TAP);
  BuildOptions bo;
  bo.hopoThreshold = opts.hopoThreshold;
  bo.sustainCutoff = opts.sustainCutoff >= 0 ? opts.sustainCutoff : tempo.resolution() / 3;
  bo.timeOffset = opts.timeOffset;
  Built result;
  result.endTick = track.endTick;
  for (int di = 0; di < 4; di++) {
    const int base = kDiffBase[di];
    RawTrackData raw;
    std::vector<RawRange> forceHopo, forceStrum;
    const auto& openRanges = ps.open[di];
    for (const auto& n : notes) {
      const int rel = n.note - base;
      if (rel < 0 || rel > 6) continue;
      if (rel <= 4) {
        const int fret = (rel == 0 && !openRanges.empty() && anyContains(openRanges, n.tick)) ? 5 : rel;
        raw.notes.push_back(RawNote{n.tick, fret, n.length});
        result.endTick = std::max(result.endTick, n.tick + n.length);
      } else if (rel == 5) forceHopo.push_back(RawRange{n.tick, n.length});
      else forceStrum.push_back(RawRange{n.tick, n.length});
    }
    if (raw.notes.empty()) continue;
    raw.taps = globalTaps;
    raw.taps.insert(raw.taps.end(), ps.tap[di].begin(), ps.tap[di].end());
    raw.starPower = starPower;
    raw.solos = solos;
    Track built = buildTrack(instrument, kDiffs[di], raw, tempo, bo);
    if (!forceHopo.empty() || !forceStrum.empty()) {
      std::vector<RawRange> flips;
      for (const auto& note : built.notes) {
        const bool hopoCovered = anyContains(forceHopo, note.tick);
        const bool strumCovered = anyContains(forceStrum, note.tick);
        const bool naturalHopo = note.type == NoteType::Hopo;
        bool flip = false;
        if (hopoCovered) flip = !naturalHopo;
        else if (strumCovered) flip = naturalHopo;
        if (flip) flips.push_back(RawRange{note.tick, 0});
      }
      if (!flips.empty()) {
        raw.forced = flips;
        built = buildTrack(instrument, kDiffs[di], raw, tempo, bo);
      }
    }
    for (const auto& n : built.notes) result.chartLength = std::max(result.chartLength, n.endTime);
    result.tracks.push_back(std::move(built));
  }
  return result;
}

std::vector<std::pair<int, std::string>> textEvents(const MidiTrack& track) {
  std::vector<std::pair<int, std::string>> out;
  bool sawName = false;
  for (const auto& m : track.metas) {
    if (m.type == META_TEXT || m.type == META_LYRIC) out.emplace_back(m.tick, metaText(m.data));
    else if (m.type == META_TRACK_NAME) {
      if (sawName) out.emplace_back(m.tick, metaText(m.data));
      sawName = true;
    }
  }
  return out;
}

const MidiTrack* findTrack(const std::vector<MidiTrack>& tracks, const std::string& name) {
  const std::string upper = toLower(name);
  for (const auto& t : tracks) if (toLower(t.name) == upper) return &t;
  return nullptr;
}

std::string sectionName(const std::string& raw) {
  std::string t = trim(raw);
  if (t.size() < 3 || t.front() != '[' || t.back() != ']') return "";
  std::string inner = trim(t.substr(1, t.size() - 2));
  std::string lower = toLower(inner);
  if (startsWith(lower, "section ")) return trim(inner.substr(8));
  if (startsWith(lower, "prc_")) {
    std::string n = inner.substr(4);
    std::replace(n.begin(), n.end(), '_', ' ');
    return trim(n);
  }
  return "";
}

}  // namespace

Chart parseMidiChart(const std::vector<uint8_t>& data, const MidiParseOptions& opts) {
  MidiFile midi = parseMidiFile(data);
  const int resolution = midi.division;
  const double timeOffset = opts.timeOffset;
  std::vector<TempoEvent> rawTempos;
  for (const auto& t : midi.tracks) {
    bool any = false;
    for (const auto& m : t.metas) if (m.type == META_TEMPO) { any = true; break; }
    if (!any) continue;
    for (const auto& m : t.metas) {
      if (m.type != META_TEMPO || m.data.size() < 3) continue;
      const int us = (m.data[0] << 16) | (m.data[1] << 8) | m.data[2];
      if (us > 0) rawTempos.push_back(TempoEvent{m.tick, 60000000.0 / us, 0});
    }
    break;
  }
  TempoMap tempo(resolution, rawTempos);
  Chart chart;
  chart.resolution = resolution;
  chart.tempos = tempo.tempos();
  for (auto& t : chart.tempos) t.time += timeOffset;
  for (const auto& t : midi.tracks) {
    bool any = false;
    for (const auto& m : t.metas) if (m.type == META_TIMESIG) { any = true; break; }
    if (!any) continue;
    for (const auto& m : t.metas) {
      if (m.type != META_TIMESIG || m.data.size() < 2) continue;
      const int num = m.data[0] ? m.data[0] : 4;
      const int den = m.data[1] < 8 ? (1 << m.data[1]) : 4;
      chart.timeSigs.push_back(TimeSigEvent{m.tick, num, den, tempo.tickToTime(m.tick) + timeOffset});
    }
    break;
  }
  int endTick = 0;
  for (const auto& t : midi.tracks) endTick = std::max(endTick, t.endTick);

  if (const MidiTrack* ev = findTrack(midi.tracks, "EVENTS")) {
    for (const auto& [tick, text] : textEvents(*ev)) {
      const std::string name = sectionName(text);
      if (!name.empty()) chart.sections.push_back(Section{tick, tempo.tickToTime(tick) + timeOffset, name});
      {
        std::string t = trim(text);
        if (t.size() > 2 && t.front() == '[' && t.back() == ']') t = t.substr(1, t.size() - 2);
        const std::string low = toLower(trim(t));
        if (startsWith(low, "lighting")) {
          const size_t a = low.find('('), b = low.find(')');
          chart.lighting.push_back(LightEvent{tick, tempo.tickToTime(tick) + timeOffset, a != std::string::npos && b > a ? low.substr(a + 1, b - a - 1) : ""});
        } else if (low == "bre_start" || low == "bre_end" || startsWith(low, "crowd_")) chart.lighting.push_back(LightEvent{tick, tempo.tickToTime(tick) + timeOffset, low});
      }
    }
    std::stable_sort(chart.sections.begin(), chart.sections.end(), [](const Section& a, const Section& b) { return a.tick < b.tick; });
  }
  if (const MidiTrack* voc = findTrack(midi.tracks, "PART VOCALS")) {
    for (const auto& [tick, text] : textEvents(*voc)) {
      if (text.empty() || text.front() == '[') continue;
      chart.lyrics.push_back(LyricEvent{tick, tempo.tickToTime(tick) + timeOffset, text});
    }
  }
  const std::pair<const char*, Instrument> names[] = {{"part guitar", Instrument::Guitar}, {"part bass", Instrument::Bass}, {"part rhythm", Instrument::Rhythm}, {"part keys", Instrument::Keys}, {"part guitar coop", Instrument::Coop}};
  std::set<Instrument> seen;
  std::vector<std::pair<Instrument, const MidiTrack*>> instrumentTracks;
  for (const auto& t : midi.tracks) {
    const std::string lower = toLower(t.name);
    for (const auto& [n, inst] : names) {
      if (lower == n && !seen.count(inst)) {
        seen.insert(inst);
        instrumentTracks.emplace_back(inst, &t);
      }
    }
  }
  if (!seen.count(Instrument::Guitar)) {
    if (const MidiTrack* legacy = findTrack(midi.tracks, "T1 GEMS")) instrumentTracks.emplace_back(Instrument::Guitar, legacy);
  }
  double chartLength = 0;
  for (const auto& [inst, t] : instrumentTracks) {
    Built b = buildInstrumentTracks(inst, *t, tempo, opts);
    for (auto& tr : b.tracks) chart.tracks[trackKey(tr.instrument, tr.difficulty)] = std::move(tr);
    endTick = std::max(endTick, b.endTick);
    chartLength = std::max(chartLength, b.chartLength);
  }
  chart.beats = generateBeats(tempo, chart.timeSigs, endTick);
  for (auto& b : chart.beats) b.time += timeOffset;
  chart.chartLength = chartLength;
  return chart;
}

}  // namespace gc

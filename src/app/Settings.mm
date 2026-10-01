#import <Foundation/Foundation.h>
#include <filesystem>
#include "Settings.h"
#include <map>

namespace gc {

static Settings gSettings;
Settings& settings() { return gSettings; }

std::string keyName(int code) {
  static const std::map<int, const char*> names = {{0, "A"}, {1, "S"}, {2, "D"}, {3, "F"}, {4, "H"}, {5, "G"}, {6, "Z"}, {7, "X"}, {8, "C"}, {9, "V"}, {11, "B"}, {12, "Q"}, {13, "W"}, {14, "E"}, {15, "R"}, {16, "Y"}, {17, "T"}, {18, "1"}, {19, "2"}, {20, "3"}, {21, "4"}, {22, "6"}, {23, "5"}, {24, "="}, {25, "9"}, {26, "7"}, {27, "-"}, {28, "8"}, {29, "0"}, {30, "]"}, {31, "O"}, {32, "U"}, {33, "["}, {34, "I"}, {35, "P"}, {36, "Enter"}, {37, "L"}, {38, "J"}, {39, "'"}, {40, "K"}, {41, ";"}, {42, "\\"}, {43, ","}, {44, "/"}, {45, "N"}, {46, "M"}, {47, "."}, {48, "Tab"}, {49, "Space"}, {50, "`"}, {51, "Delete"}, {53, "Esc"}, {54, "Right Cmd"}, {55, "Left Cmd"}, {56, "Left Shift"}, {57, "Caps Lock"}, {58, "Left Option"}, {59, "Left Ctrl"}, {60, "Right Shift"}, {61, "Right Option"}, {62, "Right Ctrl"}, {63, "Fn"}, {123, "←"}, {124, "→"}, {125, "↓"}, {126, "↑"}};
  auto it = names.find(code);
  return it != names.end() ? it->second : "Key " + std::to_string(code);
}

std::string supportDir() {
  NSString* base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  NSString* dir = [base stringByAppendingPathComponent:@"GuitarCozy"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir.UTF8String;
}

Instrument instrumentFromName(const std::string& s) {
  if (s == "bass") return Instrument::Bass;
  if (s == "rhythm") return Instrument::Rhythm;
  if (s == "keys") return Instrument::Keys;
  if (s == "coop") return Instrument::Coop;
  return Instrument::Guitar;
}
Difficulty difficultyFromName(const std::string& s) {
  if (s == "easy") return Difficulty::Easy;
  if (s == "medium") return Difficulty::Medium;
  if (s == "hard") return Difficulty::Hard;
  return Difficulty::Expert;
}

static NSString* path() { return [NSString stringWithUTF8String:(supportDir() + "/settings.json").c_str()]; }

#define NUM(k, field) if (d[k]) s.field = [d[k] doubleValue];
#define BOOLV(k, field) if (d[k]) s.field = [d[k] boolValue];
#define STR(k, field) if ([d[k] isKindOfClass:NSString.class]) s.field = [d[k] UTF8String];

void loadSettings() {
  Settings s;
  NSData* data = [NSData dataWithContentsOfFile:path()];
  if (data) {
    NSDictionary* d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([d isKindOfClass:NSDictionary.class]) {
      NUM(@"audioOffset", audioOffset) NUM(@"videoOffset", videoOffset) NUM(@"hitWindow", hitWindow) NUM(@"noteSpeed", noteSpeed) NUM(@"perfectWindow", perfectWindow) NUM(@"quickplaySpeed", quickplaySpeed) BOOLV(@"timingFeedback", timingFeedback) BOOLV(@"onboarded", onboarded)
      BOOLV(@"noFail", noFail) BOOLV(@"muteOnMiss", muteOnMiss) BOOLV(@"showDemoSong", showDemoSong) BOOLV(@"showLyrics", showLyrics) BOOLV(@"leftHanded", leftHanded) BOOLV(@"botMode", botMode) BOOLV(@"reducedMotion", reducedMotion)
      NUM(@"masterVolume", masterVolume) NUM(@"musicVolume", musicVolume) NUM(@"sfxVolume", sfxVolume)
      STR(@"background", background) STR(@"quality", quality) STR(@"lastInstrument", lastInstrument) STR(@"lastDifficulty", lastDifficulty) STR(@"playerName", playerName)
      STR(@"toneMapping", toneMapping) STR(@"bloom", bloom) STR(@"antialias", antialias) STR(@"cameraPreset", cameraPreset)
      NUM(@"exposure", exposure) NUM(@"saturation", saturation) NUM(@"contrast", contrast) NUM(@"renderScale", renderScale) NUM(@"reflections", reflections) NUM(@"effectsIntensity", effectsIntensity)
      NSArray* frets = d[@"keyFrets"];
      if ([frets isKindOfClass:NSArray.class] && frets.count == 5) for (int i = 0; i < 5; i++) s.keys.frets[i] = [frets[i] intValue];
      NUM(@"keyStrumUp", keys.strumUp) NUM(@"keyStrumDown", keys.strumDown) NUM(@"keyStarPower", keys.starPower) NUM(@"keyPause", keys.pause) NUM(@"keyWhammy", keys.whammy)
      NSArray* pf = d[@"padFrets"];
      if ([pf isKindOfClass:NSArray.class] && pf.count == 5) for (int i = 0; i < 5; i++) s.pad.frets[i] = [pf[i] intValue];
      NUM(@"padStrumUp", pad.strumUp) NUM(@"padStrumDown", pad.strumDown) NUM(@"padStarPower", pad.starPower) NUM(@"padPause", pad.pause) NUM(@"padWhammyAxis", pad.whammyAxis) NUM(@"padTiltAxis", pad.tiltAxis)
      NSArray* folders = d[@"songFolders"];
      if ([folders isKindOfClass:NSArray.class]) for (NSString* f in folders) if ([f isKindOfClass:NSString.class]) s.songFolders.push_back(f.UTF8String);
    }
  }
  gSettings = s;
}

void saveSettings() {
  const Settings& s = gSettings;
  NSMutableDictionary* d = [NSMutableDictionary new];
  d[@"audioOffset"] = @(s.audioOffset); d[@"videoOffset"] = @(s.videoOffset); d[@"hitWindow"] = @(s.hitWindow); d[@"noteSpeed"] = @(s.noteSpeed); d[@"perfectWindow"] = @(s.perfectWindow); d[@"quickplaySpeed"] = @(s.quickplaySpeed); d[@"timingFeedback"] = @(s.timingFeedback); d[@"onboarded"] = @(s.onboarded);
  d[@"noFail"] = @(s.noFail); d[@"muteOnMiss"] = @(s.muteOnMiss); d[@"showDemoSong"] = @(s.showDemoSong); d[@"showLyrics"] = @(s.showLyrics); d[@"leftHanded"] = @(s.leftHanded); d[@"botMode"] = @(s.botMode); d[@"reducedMotion"] = @(s.reducedMotion);
  d[@"masterVolume"] = @(s.masterVolume); d[@"musicVolume"] = @(s.musicVolume); d[@"sfxVolume"] = @(s.sfxVolume);
  d[@"background"] = @(s.background.c_str()); d[@"quality"] = @(s.quality.c_str()); d[@"lastInstrument"] = @(s.lastInstrument.c_str()); d[@"lastDifficulty"] = @(s.lastDifficulty.c_str()); d[@"playerName"] = @(s.playerName.c_str());
  d[@"toneMapping"] = @(s.toneMapping.c_str()); d[@"bloom"] = @(s.bloom.c_str()); d[@"antialias"] = @(s.antialias.c_str()); d[@"cameraPreset"] = @(s.cameraPreset.c_str());
  d[@"exposure"] = @(s.exposure); d[@"saturation"] = @(s.saturation); d[@"contrast"] = @(s.contrast); d[@"renderScale"] = @(s.renderScale); d[@"reflections"] = @(s.reflections); d[@"effectsIntensity"] = @(s.effectsIntensity);
  d[@"keyFrets"] = @[@(s.keys.frets[0]), @(s.keys.frets[1]), @(s.keys.frets[2]), @(s.keys.frets[3]), @(s.keys.frets[4])];
  d[@"keyStrumUp"] = @(s.keys.strumUp); d[@"keyStrumDown"] = @(s.keys.strumDown); d[@"keyStarPower"] = @(s.keys.starPower); d[@"keyPause"] = @(s.keys.pause); d[@"keyWhammy"] = @(s.keys.whammy);
  d[@"padFrets"] = @[@(s.pad.frets[0]), @(s.pad.frets[1]), @(s.pad.frets[2]), @(s.pad.frets[3]), @(s.pad.frets[4])];
  d[@"padStrumUp"] = @(s.pad.strumUp); d[@"padStrumDown"] = @(s.pad.strumDown); d[@"padStarPower"] = @(s.pad.starPower); d[@"padPause"] = @(s.pad.pause); d[@"padWhammyAxis"] = @(s.pad.whammyAxis); d[@"padTiltAxis"] = @(s.pad.tiltAxis);
  NSMutableArray* folders = [NSMutableArray new];
  for (const auto& f : s.songFolders) [folders addObject:@(f.c_str())];
  d[@"songFolders"] = folders;
  NSData* data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:path() atomically:YES];
}

}  // namespace gc

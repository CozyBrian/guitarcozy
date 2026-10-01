#pragma once
#include <string>
#include <vector>
#include "core/types.h"

namespace gc {

struct KeyBindings { int frets[5] = {0, 1, 2, 3, 5}; int strumUp = 126, strumDown = 125, starPower = 49, pause = 53, whammy = 56; };  // macOS virtual key codes
struct PadBindings { int frets[5] = {0, 1, 3, 2, 4}; int strumUp = 12, strumDown = 13, starPower = 8, pause = 9, whammyAxis = 2, tiltAxis = -1; };

struct Settings {
  KeyBindings keys;
  PadBindings pad;
  double audioOffset = 0, videoOffset = 0;  // ms
  double hitWindow = 90;                    // ms
  double perfectWindow = 35;                // ms: |offset| below this reads as Perfect
  bool timingFeedback = true;               // Early / Late / Perfect readout
  double quickplaySpeed = 1.0;              // song speed chip on the song card
  bool onboarded = false;                   // first-run screen shown
  double noteSpeed = 1.0;
  bool noFail = false, muteOnMiss = true, showDemoSong = true, showLyrics = true, leftHanded = false, botMode = false, reducedMotion = false;
  double masterVolume = 1, musicVolume = 0.9, sfxVolume = 0.8;
  std::string background = "stage", quality = "high", lastInstrument = "guitar", lastDifficulty = "expert", playerName = "Player";
  std::string toneMapping = "none", bloom = "low", antialias = "msaa", cameraPreset = "classic";
  double exposure = 1, saturation = 1.15, contrast = 1.05, renderScale = 1, reflections = 0.4, effectsIntensity = 1;
  std::vector<std::string> songFolders;
};

Settings& settings();
void loadSettings();
void saveSettings();
std::string supportDir();  // ~/Library/Application Support/GuitarCozy
std::string keyName(int macKeyCode);  // human label for a virtual key code
Instrument instrumentFromName(const std::string& s);
Difficulty difficultyFromName(const std::string& s);

}  // namespace gc

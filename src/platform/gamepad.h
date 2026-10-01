// Gamepad / guitar controller polling. GameController framework first; raw IOKit HID as a fallback for
// guitars macOS does not expose as game controllers. Button indices follow the web Gamepad API
// "standard" layout so saved bindings match: 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 LT, 7 RT, 8 Back, 9 Start,
// 10 LS, 11 RS, 12..15 d-pad up/down/left/right. Axes: 0/1 left stick, 2/3 right stick (whammy is axis 2).
#pragma once
#include <string>

namespace gc::platform {

struct PadState {
  bool connected = false;
  bool buttons[16] = {};
  float axes[4] = {};
  std::string name;
  bool hasMotion = false;
  float tilt = 0;  // 0..1, how far the neck is raised (from the controller's motion sensor)
  bool raw = false;  // came from the IOKit fallback
};

PadState pollGamepad();
void rumble(float intensity, float seconds);  // haptics on the connected controller, if it has any

}  // namespace gc::platform

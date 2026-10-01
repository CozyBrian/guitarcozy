#include "gamepad.h"
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <IOKit/hid/IOHIDManager.h>
#include <algorithm>
#include <vector>

namespace gc::platform {

namespace {

// ---- raw HID fallback
struct RawDevice {
  IOHIDDeviceRef device = nullptr;
  std::vector<IOHIDElementRef> buttons;  // sorted by usage
  IOHIDElementRef hat = nullptr;
  IOHIDElementRef axes[4] = {};
  std::string name;
};
IOHIDManagerRef gManager = nullptr;
std::vector<RawDevice> gRaw;

void rawAdded(void*, IOReturn, void*, IOHIDDeviceRef dev) {
  RawDevice r;
  r.device = dev;
  CFStringRef prod = (CFStringRef)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
  r.name = prod ? std::string([(__bridge NSString*)prod UTF8String]) : "HID controller";
  CFArrayRef elems = IOHIDDeviceCopyMatchingElements(dev, nullptr, kIOHIDOptionsTypeNone);
  if (!elems) return;
  std::vector<std::pair<uint32_t, IOHIDElementRef>> btns;
  for (CFIndex i = 0; i < CFArrayGetCount(elems); i++) {
    IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(elems, i);
    const uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    if (IOHIDElementGetType(e) == kIOHIDElementTypeCollection) continue;
    if (page == kHIDPage_Button) btns.emplace_back(usage, e);
    else if (page == kHIDPage_GenericDesktop) {
      if (usage == kHIDUsage_GD_Hatswitch) r.hat = e;
      else if (usage == kHIDUsage_GD_X) r.axes[0] = e;
      else if (usage == kHIDUsage_GD_Y) r.axes[1] = e;
      else if (usage == kHIDUsage_GD_Z) r.axes[2] = e;
      else if (usage == kHIDUsage_GD_Rz) r.axes[3] = e;
    }
  }
  CFRelease(elems);
  std::sort(btns.begin(), btns.end(), [](auto& a, auto& b) { return a.first < b.first; });
  for (auto& [u, e] : btns) r.buttons.push_back(e);
  gRaw.push_back(r);
}
void rawRemoved(void*, IOReturn, void*, IOHIDDeviceRef dev) {
  gRaw.erase(std::remove_if(gRaw.begin(), gRaw.end(), [&](const RawDevice& r) { return r.device == dev; }), gRaw.end());
}
void ensureRaw() {
  if (gManager) return;
  gManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  NSArray* match = @[@{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
                     @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)},
                     @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_MultiAxisController)}];
  IOHIDManagerSetDeviceMatchingMultiple(gManager, (__bridge CFArrayRef)match);
  IOHIDManagerRegisterDeviceMatchingCallback(gManager, rawAdded, nullptr);
  IOHIDManagerRegisterDeviceRemovalCallback(gManager, rawRemoved, nullptr);
  IOHIDManagerScheduleWithRunLoop(gManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
  IOHIDManagerOpen(gManager, kIOHIDOptionsTypeNone);
}
double elementValue(IOHIDDeviceRef dev, IOHIDElementRef e, bool normalize) {
  IOHIDValueRef v = nullptr;
  if (!e || IOHIDDeviceGetValue(dev, e, &v) != kIOReturnSuccess || !v) return 0;
  const double raw = double(IOHIDValueGetIntegerValue(v));
  if (!normalize) return raw;
  const double lo = double(IOHIDElementGetLogicalMin(e)), hi = double(IOHIDElementGetLogicalMax(e));
  return hi > lo ? (raw - lo) / (hi - lo) * 2.0 - 1.0 : 0;
}
PadState pollRaw() {
  PadState s;
  ensureRaw();
  if (gRaw.empty()) return s;
  const RawDevice& r = gRaw.front();
  s.connected = true;
  s.raw = true;
  s.name = r.name;
  for (size_t i = 0; i < r.buttons.size() && i < 12; i++) s.buttons[i] = elementValue(r.device, r.buttons[i], false) > 0.5;
  if (r.hat) {
    IOHIDValueRef v = nullptr;
    if (IOHIDDeviceGetValue(r.device, r.hat, &v) == kIOReturnSuccess && v) {
      const long h = IOHIDValueGetIntegerValue(v) - IOHIDElementGetLogicalMin(r.hat);
      const long n = IOHIDElementGetLogicalMax(r.hat) - IOHIDElementGetLogicalMin(r.hat) + 1;  // 4 or 8 way
      if (h >= 0 && h < n) {
        const int dir = n == 8 ? int(h) : int(h) * 2;  // 0 up, 2 right, 4 down, 6 left
        s.buttons[12] = dir == 7 || dir == 0 || dir == 1;
        s.buttons[15] = dir == 1 || dir == 2 || dir == 3;
        s.buttons[13] = dir == 3 || dir == 4 || dir == 5;
        s.buttons[14] = dir == 5 || dir == 6 || dir == 7;
      }
    }
  }
  for (int a = 0; a < 4; a++) s.axes[a] = float(elementValue(r.device, r.axes[a], true));
  return s;
}

// ---- haptics
CHHapticEngine* gHaptics = nil;
GCController* gHapticsController = nil;
}  // namespace

PadState pollGamepad() {
  PadState s;
  GCController* c = nil;
  for (GCController* cand in GCController.controllers) if (cand.extendedGamepad) { c = cand; break; }
  if (!c) return pollRaw();
  GCExtendedGamepad* g = c.extendedGamepad;
  s.connected = true;
  s.name = c.vendorName ? c.vendorName.UTF8String : "Controller";
  auto pressed = [](GCControllerButtonInput* b) { return b && (b.pressed || b.value > 0.5f); };
  s.buttons[0] = pressed(g.buttonA);
  s.buttons[1] = pressed(g.buttonB);
  s.buttons[2] = pressed(g.buttonX);
  s.buttons[3] = pressed(g.buttonY);
  s.buttons[4] = pressed(g.leftShoulder);
  s.buttons[5] = pressed(g.rightShoulder);
  s.buttons[6] = pressed(g.leftTrigger);
  s.buttons[7] = pressed(g.rightTrigger);
  s.buttons[8] = pressed(g.buttonOptions);
  s.buttons[9] = pressed(g.buttonMenu);
  s.buttons[10] = pressed(g.leftThumbstickButton);
  s.buttons[11] = pressed(g.rightThumbstickButton);
  s.buttons[12] = pressed(g.dpad.up);
  s.buttons[13] = pressed(g.dpad.down);
  s.buttons[14] = pressed(g.dpad.left);
  s.buttons[15] = pressed(g.dpad.right);
  s.axes[0] = g.leftThumbstick.xAxis.value;
  s.axes[1] = -g.leftThumbstick.yAxis.value;
  s.axes[2] = g.rightThumbstick.xAxis.value;
  s.axes[3] = -g.rightThumbstick.yAxis.value;
  if (c.motion) {
    if (!c.motion.sensorsActive && c.motion.sensorsRequireManualActivation) c.motion.sensorsActive = YES;
    s.hasMotion = c.motion.hasGravityAndUserAcceleration || c.motion.hasAttitude || true;
    const GCAcceleration gr = c.motion.gravity;
    // neck raised: gravity swings toward the controller's long axis. Use the larger of the two horizontal axes.
    s.tilt = float(std::max(0.0, std::max(-gr.x, -gr.y)));
  }
  return s;
}

void rumble(float intensity, float seconds) {
  GCController* c = nil;
  for (GCController* cand in GCController.controllers) if (cand.extendedGamepad) { c = cand; break; }
  if (!c || !c.haptics) return;
  if (gHapticsController != c || !gHaptics) {
    gHaptics = [c.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    gHapticsController = c;
    if (!gHaptics) return;
    gHaptics.playsHapticsOnly = YES;
    [gHaptics startAndReturnError:nil];
  }
  NSError* err = nil;
  CHHapticEventParameter* inten = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:std::max(0.f, std::min(1.f, intensity))];
  CHHapticEventParameter* sharp = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.4f];
  CHHapticEvent* ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[inten, sharp] relativeTime:0 duration:std::max(0.02f, seconds)];
  CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
  if (!pattern) return;
  id<CHHapticPatternPlayer> player = [gHaptics createPlayerWithPattern:pattern error:&err];
  [player startAtTime:0 error:&err];
}

}  // namespace gc::platform

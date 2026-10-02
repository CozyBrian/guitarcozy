#import "App.h"
#import <ImageIO/ImageIO.h>
#include <mach/mach_time.h>
#include <algorithm>
#include "Library.h"
#include "Settings.h"
#include "audio/sfx.h"
#include "render/renderer.h"
#import "screens/MainMenuScreen.h"
#import "screens/GameplayScreen.h"
#import "screens/SongSelectScreen.h"
#import "screens/CareerScreen.h"
#import "screens/OptionsScreen.h"

double GCHostSeconds(void) {
  static double scale = [] { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return double(tb.numer) / tb.denom * 1e-9; }();
  return double(mach_absolute_time()) * scale;
}

// Content view that forwards keyboard events to the app.
@interface GCRootView : NSView
@end
@implementation GCRootView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }
- (void)keyDown:(NSEvent*)ev {
  GCApp* app = GCApp.shared;
  id<GCScreen> s = app.screen;
  if ([s respondsToSelector:@selector(keyDown:)]) [s keyDown:ev];
  if (ev.isARepeat) return;
  // physical navigation keys always drive menus
  NSString* action = nil;
  switch (ev.keyCode) {
    case 126: action = @"up"; break;
    case 125: action = @"down"; break;
    case 123: action = @"left"; break;
    case 124: action = @"right"; break;
    case 36: case 76: case 49: action = @"confirm"; break;
    case 53: case 51: action = @"back"; break;
    case 48: action = (ev.modifierFlags & NSEventModifierFlagShift) ? @"backtab" : @"tab"; break;  // Tab: next pane / section
    case 44: action = @"search"; break;  // "/" focuses a search field where there is one
  }
  if (!action) {
    const auto& k = gc::settings().keys;
    if (ev.keyCode == k.strumUp) action = @"up";
    else if (ev.keyCode == k.strumDown) action = @"down";
    else if (ev.keyCode == k.frets[0]) action = @"confirm";
    else if (ev.keyCode == k.frets[1]) action = @"back";
  }
  if (action) [app dispatchMenuAction:action];
}
- (void)keyUp:(NSEvent*)ev {
  id<GCScreen> s = GCApp.shared.screen;
  if ([s respondsToSelector:@selector(keyUp:)]) [s keyUp:ev];
}
- (void)flagsChanged:(NSEvent*)ev {
  id<GCScreen> s = GCApp.shared.screen;
  if ([s respondsToSelector:@selector(flagsChanged:)]) [s flagsChanged:ev];
}
@end

static GCApp* gApp;

@implementation GCApp
+ (GCApp*)shared { return gApp; }

- (void)applicationDidFinishLaunching:(NSNotification*)n {
  gApp = self;
  NSRect frame = NSMakeRect(0, 0, 1440, 900);
  self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable) backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"GuitarCozy";
  self.window.restorable = NO;  // AppKit's periodic persistent-UI flush otherwise stalls the main thread mid-song
  self.window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;  // green button / Ctrl+Cmd+F enter full screen
  // minimal app menu so the standard shortcuts work (Cmd+Q quit, Cmd+H hide, Ctrl+Cmd+F full screen)
  NSMenu* bar = [NSMenu new];
  NSMenuItem* appItem = [bar addItemWithTitle:@"GuitarCozy" action:nil keyEquivalent:@""];
  NSMenu* appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"Hide GuitarCozy" action:@selector(hide:) keyEquivalent:@"h"];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit GuitarCozy" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  NSMenuItem* viewItem = [bar addItemWithTitle:@"View" action:nil keyEquivalent:@""];
  NSMenu* viewMenu = [NSMenu new];
  NSMenuItem* fs = [viewMenu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
  fs.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
  viewItem.submenu = viewMenu;
  NSApp.mainMenu = bar;
  self.window.minSize = NSMakeSize(960, 600);
  [self.window center];
  GCRootView* root = [[GCRootView alloc] initWithFrame:frame];
  root.wantsLayer = YES;
  root.layer.backgroundColor = GCColor(GC_BG).CGColor;
  self.window.contentView = root;

  self.device = MTLCreateSystemDefaultDevice();
  self.queue = [self.device newCommandQueue];
  self.gameView = [[MTKView alloc] initWithFrame:frame device:self.device];
  self.gameView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  self.gameView.framebufferOnly = NO;
  self.gameView.preferredFramesPerSecond = std::max<NSInteger>(60, self.window.screen ? self.window.screen.maximumFramesPerSecond : 60);
  self.gameView.delegate = self;
  self.gameView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.gameView.hidden = YES;
  self.gameView.clearColor = MTLClearColorMake(0.035, 0.035, 0.035, 1);
  // present inside the Core Animation transaction so the Metal frame and the HUD overlay commit together
  ((CAMetalLayer*)self.gameView.layer).presentsWithTransaction = YES;
  [root addSubview:self.gameView];

  self.stage = [[GCStage alloc] initWithFrame:frame];
  self.stage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:self.stage];

  GCRegisterFonts([NSString stringWithUTF8String:(self.resourcePath + "/fonts").c_str()]);
  gc::loadSettings();
  gc::audio::Sfx::instance().start();
  [self applySfxGain];
  { const std::string lib = self.metallibPath; id<MTLDevice> dev = self.device; dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ gc::render::Renderer::preload(dev, lib); }); }
  gc::Library::instance().setBuiltinFolder(self.resourcePath + "/demo");
  gc::Library::instance().restore();

  [self.window makeFirstResponder:root];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  self.startedAt = GCHostSeconds();
  if (self.debugActionsAt > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(self.debugActionsAt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runDebugActions]; });
  if (getenv("GC_CLOCKLOG")) {
    // main-thread busy time per run loop iteration (everything AppKit does between frames: layout, CA commit, timers)
    static double woke = 0;
    CFRunLoopObserverRef obs = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity act) {
      if (act == kCFRunLoopAfterWaiting) woke = GCHostSeconds();
      else if (woke > 0) { const double busy = GCHostSeconds() - woke; if (busy > 0.012) fprintf(stderr, "runloop busy %.1f ms (wall %.2f s)\n", busy * 1000, GCHostSeconds() - self.startedAt); }
    });
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    // bracket AppKit's layout + Core Animation commit (its BeforeWaiting observers run at order ~2000000)
    static double preCommit = 0;
    CFRunLoopObserverRef pre = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting, true, -1000000, ^(CFRunLoopObserverRef, CFRunLoopActivity) { preCommit = GCHostSeconds(); });
    CFRunLoopObserverRef post = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting, true, 3000000, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
      const double c = GCHostSeconds() - preCommit;
      if (c > 0.006) fprintf(stderr, "ca commit %.1f ms (wall %.2f s)\n", c * 1000, GCHostSeconds() - self.startedAt);
    });
    CFRunLoopAddObserver(CFRunLoopGetMain(), pre, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetMain(), post, kCFRunLoopCommonModes);
  }
  for (NSString* spec in self.debugKeys) {
    NSArray* parts = [spec componentsSeparatedByString:@":"];
    if (parts.count < 2) continue;
    const double at = [parts[0] doubleValue];
    const unsigned short code = (unsigned short)[parts[1] intValue];
    const double hold = parts.count > 2 ? [parts[2] doubleValue] : 0.03;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (getenv("GC_CLOCKLOG")) fprintf(stderr, "synthetic key %d down (screen %s)\n", code, [[self.screen class] description].UTF8String);
      NSEvent* down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:[NSProcessInfo processInfo].systemUptime windowNumber:self.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
      [self.window.contentView keyDown:down];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t((at + hold) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSEvent* up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:[NSProcessInfo processInfo].systemUptime windowNumber:self.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
      [self.window.contentView keyUp:up];
    });
  }
  // ticker: controller polling, non-game screen animations, screenshot timing
  [NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer* t) {
    [self pollPad];
    if ([self.screen respondsToSelector:@selector(update:)] && ![self.screen respondsToSelector:@selector(wantsGameView)]) [self.screen update:1.0 / 120];
    if (!self.screenshotPath.empty() && self.gameView.hidden && GCHostSeconds() - self.startedAt >= self.screenshotSeconds) [self saveScreenshot];
  }];
}

- (void)applySfxGain {
  const auto& s = gc::settings();
  gc::audio::Sfx::instance().setGain(self.screenshotPath.empty() ? float(s.sfxVolume * s.masterVolume) : 0.f);
}

- (void)dispatchMenuAction:(NSString*)action {
  id<GCScreen> s = self.screen;
  if (!s) return;
  if (self.gameView.hidden) {
    auto& sfx = gc::audio::Sfx::instance();
    if ([action isEqualToString:@"up"] || [action isEqualToString:@"down"] || [action isEqualToString:@"tab"] || [action isEqualToString:@"backtab"]) sfx.playMenuMove();
    else if ([action isEqualToString:@"confirm"]) sfx.playMenuConfirm();
    else if ([action isEqualToString:@"back"]) sfx.playMenuBack();
  }
  [s menuAction:action];
}

// ---- controller: edges drive menus (strum = up/down, green = confirm, red/start = back) and gameplay gets the raw state
- (void)pollPad {
  static gc::platform::PadState prev;
  static const bool clockLog = getenv("GC_CLOCKLOG") != nullptr;
  const double t0 = GCHostSeconds();
  gc::platform::PadState p = gc::platform::pollGamepad();
  if (clockLog && GCHostSeconds() - t0 > 0.002) fprintf(stderr, "pad poll %.1f ms\n", (GCHostSeconds() - t0) * 1000);
  self.padName = p.connected ? @(p.name.c_str()) : nil;
  self.padRaw = p.raw;
  if (p.connected) {
    auto edge = [&](int b) { return b >= 0 && b < 16 && p.buttons[b] && !prev.buttons[b]; };
    if (self.padCapture) {
      for (int b = 0; b < 16; b++) if (edge(b)) { void (^cb)(int) = self.padCapture; self.padCapture = nil; cb(b); break; }
    } else {
      const auto& g = gc::settings().pad;
      if (edge(g.strumUp)) [self dispatchMenuAction:@"up"];
      if (edge(g.strumDown)) [self dispatchMenuAction:@"down"];
      if (edge(g.frets[0])) [self dispatchMenuAction:@"confirm"];
      if (edge(g.frets[1]) || edge(g.pause)) [self dispatchMenuAction:@"back"];
      if ([self.screen respondsToSelector:@selector(padState:prev:)]) [self.screen padState:p prev:prev];
    }
  }
  prev = p;
}

- (void)showScreen:(id<GCScreen>)screen {
  if (self.screen) [self.screen exit];
  [self.stage clear];
  self.screen = screen;
  const BOOL game = [screen respondsToSelector:@selector(wantsGameView)] && [screen wantsGameView];
  self.gameView.hidden = !game;
  [screen enter:self.stage];
  [self.stage relayout];
  [self.window makeFirstResponder:self.window.contentView];
}

- (void)runDebugActions {
  NSArray* acts = self.debugActions;
  self.debugActions = nil;
  for (NSUInteger i = 0; i < acts.count; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t((0.3 + i * 0.25) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self.screen menuAction:acts[i]]; });
  }
}

- (void)showMainMenu { [self showScreen:[MainMenuScreen new]]; }
- (void)showSongSelect:(NSString*)mode { [self showScreen:[[SongSelectScreen alloc] initWithMode:mode]]; }
- (void)showCareer { [self showScreen:[CareerScreen new]]; }
- (void)showOptions { [self showScreen:[[OptionsScreen alloc] initWithTab:@"gameplay"]]; }
- (void)showCredits { [self showScreen:[CreditsScreen new]]; }

- (void)startSong:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty mode:(NSString*)mode practiceStart:(double)ps practiceEnd:(double)pe speed:(double)speed loop:(BOOL)loop {
  GameplayScreen* g = [[GameplayScreen alloc] initWithSongId:songId instrument:instrument difficulty:difficulty mode:mode];
  if ([mode isEqualToString:@"practice"]) [g setPracticeStart:ps end:pe speed:speed loop:loop];
  else [g setSpeed:self.debugRate > 0 ? self.debugRate : speed];
  [self showScreen:g];
}

- (void)watchReplay:(NSString*)path songId:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty {
  GameplayScreen* g = [[GameplayScreen alloc] initWithSongId:songId instrument:instrument difficulty:difficulty mode:@"quickplay"];
  [g setReplayPath:path];
  [self showScreen:g];
}

// ---- MTKView delegate: drives the gameplay screen
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
  if ([self.screen respondsToSelector:@selector(drawableSizeChanged:)]) [(id)self.screen drawableSizeChanged:size];
}
- (void)drawInMTKView:(MTKView*)view {
  if (![self.screen respondsToSelector:@selector(renderFrame:)]) return;
  [(id)self.screen renderFrame:view];
  if (!self.screenshotPath.empty() && GCHostSeconds() - self.startedAt >= self.screenshotSeconds) [self saveScreenshot];
}

// ---- screenshot: composite the Metal drawable (if visible) with the AppKit overlay
- (void)saveScreenshot {
  const std::string path = self.screenshotPath;
  self.screenshotPath.clear();
  NSView* root = self.window.contentView;
  const CGFloat bs = self.window.backingScaleFactor;
  const NSSize sz = root.bounds.size;
  const size_t w = size_t(sz.width * bs), h = size_t(sz.height * bs);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
  CGContextSetRGBFillColor(ctx, 0.035, 0.035, 0.035, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
  if (!self.gameView.hidden && [self.screen respondsToSelector:@selector(lastFrameTexture)]) {
    id<MTLTexture> tex = [(id)self.screen lastFrameTexture];
    if (tex) {
      std::vector<uint8_t> bytes(tex.width * tex.height * 4);
      [tex getBytes:bytes.data() bytesPerRow:tex.width * 4 fromRegion:MTLRegionMake2D(0, 0, tex.width, tex.height) mipmapLevel:0];
      for (size_t i = 0; i < bytes.size(); i += 4) { std::swap(bytes[i], bytes[i + 2]); bytes[i + 3] = 255; }
      CGDataProviderRef dp = CGDataProviderCreateWithData(nullptr, bytes.data(), bytes.size(), nullptr);
      CGImageRef img = CGImageCreate(tex.width, tex.height, 8, 32, tex.width * 4, cs, kCGImageAlphaNoneSkipLast, dp, nullptr, false, kCGRenderingIntentDefault);
      CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
      CGImageRelease(img);
      CGDataProviderRelease(dp);
    }
  }
  // AppKit overlay (stage) rendered with alpha
  NSBitmapImageRep* rep = [self.stage bitmapImageRepForCachingDisplayInRect:self.stage.bounds];
  [self.stage cacheDisplayInRect:self.stage.bounds toBitmapImageRep:rep];
  CGImageRef overlay = rep.CGImage;
  if (overlay) CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), overlay);
  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8*)path.c_str(), path.size(), false);
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
  CGImageDestinationAddImage(dst, out, nullptr);
  CGImageDestinationFinalize(dst);
  CFRelease(dst); CFRelease(url); CGImageRelease(out); CGContextRelease(ctx); CGColorSpaceRelease(cs);
  fprintf(stdout, "screenshot saved: %s\n", path.c_str());
  fflush(stdout);
  [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app { return YES; }
@end

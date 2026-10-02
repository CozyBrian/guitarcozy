// Application shell: window, Metal game view, stage UI overlay, screen manager, input routing.
#pragma once
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#include <memory>
#include <string>
#include "ui/Stage.h"
#include "platform/gamepad.h"

@class GCApp;

@protocol GCScreen <NSObject>
- (void)enter:(GCStage*)stage;
- (void)exit;
- (void)menuAction:(NSString*)action;  // up, down, left, right, confirm, back
@optional
- (void)update:(double)dt;
- (void)padState:(const gc::platform::PadState&)state prev:(const gc::platform::PadState&)prev;  // raw controller state (gameplay)
- (void)keyDown:(NSEvent*)ev;
- (void)keyUp:(NSEvent*)ev;
- (void)flagsChanged:(NSEvent*)ev;  // modifier keys (Shift, Ctrl, Option, Command) arrive here, not as keyDown
- (BOOL)wantsGameView;
@end

@interface GCApp : NSObject <NSApplicationDelegate, MTKViewDelegate>
+ (GCApp*)shared;
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) MTKView* gameView;
@property(nonatomic, strong) GCStage* stage;
@property(nonatomic, strong) id<GCScreen> screen;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic) std::string resourcePath;
@property(nonatomic) std::string metallibPath;
// debug / screenshot mode
@property(nonatomic) std::string screenshotPath;
@property(nonatomic) double screenshotSeconds;
@property(nonatomic) double startedAt;
@property(nonatomic) double debugPauseAt;   // seconds of song time after which gameplay auto-pauses (0 = off)
@property(nonatomic, strong) NSArray<NSString*>* debugActions;
@property(nonatomic) BOOL debugBot;
@property(nonatomic) double debugRate;                    // --rate: song speed multiplier for fast playthroughs (0 = normal)
@property(nonatomic) double debugActionsAt;  // wall seconds after launch to replay debugActions (0 = at screen entry)
@property(nonatomic, strong) NSArray<NSString*>* debugKeys;   // "seconds:keycode" synthetic key presses routed like real ones                       // --bot: autoplay without persisting the setting
@property(nonatomic, strong) NSString* padName;           // connected controller name, nil when none
@property(nonatomic) BOOL padRaw;                         // controller comes through the IOKit fallback
@property(nonatomic, copy) void (^padCapture)(int button); // set to capture the next controller button (rebinding)
- (void)dispatchMenuAction:(NSString*)action;             // plays the menu blip on non-game screens, then forwards
- (void)applySfxGain;  // menu actions replayed 0.25 s apart (after the debug pause when gameplay)
- (void)runDebugActions;
- (void)showScreen:(id<GCScreen>)screen;
- (void)showMainMenu;
- (void)showSongSelect:(NSString*)mode;   // "quickplay" | "practice"
- (void)showCareer;
- (void)showOptions;
- (void)showCredits;
- (void)startSong:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty mode:(NSString*)mode practiceStart:(double)ps practiceEnd:(double)pe speed:(double)speed loop:(BOOL)loop;
- (void)watchReplay:(NSString*)path songId:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty;
- (void)saveScreenshot;
@end

double GCHostSeconds(void);

#import "WelcomeScreen.h"
#import "Chrome.h"
#import "OptionsScreen.h"
#include "app/Library.h"
#include "app/Settings.h"

using namespace gc;

@implementation WelcomeScreen {
  GCMenuList* _menu;
}
- (void)enter:(GCStage*)stage {
  GCApp* app = GCApp.shared;
  GCHeader(stage, @"GC / Welcome", GCCrumb(@"FIRST RUN"), YES);
  GCLabel* k = GCMakeLabel(@"Three things before the first song.", 14, NO, 400, GC_YELLOW); k.tracking = 0.2; k.uppercase = YES; k.left = 80; k.top = 118; [stage addSubview:k];
  GCLabel* t = GCMakeLabel(@"Welcome to the stage.", 96, YES, 900, GC_INK); t.left = 80; t.top = 150; t.lineHeight = 96; [stage addSubview:t];
  GCLabel* d = GCMakeLabel(@"Point GuitarCozy at your Clone Hero songs folder, check your timing, then play.\nYou can do all of this later from the main menu.", 18, NO, 400, GC_MUTED); d.left = 80; d.top = 270; d.width = 700; d.wraps = YES; d.lineHeight = 28; [stage addSubview:d];
  __weak WelcomeScreen* weakSelf = self;
  auto done = ^{ settings().onboarded = true; saveSettings(); };
  _menu = [[GCMenuList alloc] initWithItems:@[@"Add songs folder", @"Calibrate timing", @"Play the demo", @"Skip for now"] dim:@[@NO, @NO, @NO, @YES] numbered:YES width:560 actions:@[
    ^{ done();
       NSOpenPanel* p = [NSOpenPanel openPanel];
       p.canChooseDirectories = YES; p.canChooseFiles = NO; p.allowsMultipleSelection = NO; p.title = @"Choose your songs folder";
       if ([p runModal] == NSModalResponseOK && p.URL) Library::instance().addFolder(p.URL.path.UTF8String);
       [app showSongSelect:@"quickplay"]; },
    ^{ done(); [app showScreen:[[OptionsScreen alloc] initWithTab:@"calibration"]]; },
    ^{ done();
       for (const auto& e : Library::instance().entries()) if (e.builtin) { [app startSong:@(e.id.c_str()) instrument:@"guitar" difficulty:@"medium" mode:@"quickplay" practiceStart:0 practiceEnd:0 speed:1 loop:NO]; return; }
       [app showMainMenu]; },
    ^{ done(); [app showMainMenu]; }]];
  (void)weakSelf;
  _menu.view.left = 80; _menu.view.top = 380;
  [stage addSubview:_menu.view];
  [_menu relayout];
  GCFooter(stage, GCDefaultHints());
}
- (void)exit {}
- (void)menuAction:(NSString*)action {
  if ([action isEqualToString:@"back"]) { settings().onboarded = true; saveSettings(); [GCApp.shared showMainMenu]; return; }
  [_menu handle:action];
}
@end

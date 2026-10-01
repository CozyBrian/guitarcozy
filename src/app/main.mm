// GuitarCozy native entry point.
// usage: GuitarCozy [--screen menu|songs|career|options] [--song <name-substring>] [--bot] [--difficulty expert]
//                   [--instrument guitar] [--practice start,end,speed] [--screenshot out.png --seconds N]
//                   [--pause-at N] [--actions down,confirm,...] [--keys 6:53[:hold],...]  (seconds:keycode synthetic presses)
//                   [--song-folder <path>]  load a song folder directly without touching the library
#import <Cocoa/Cocoa.h>
#include <string>
#import "App.h"
#include "Library.h"
#include "Settings.h"
#import "screens/PracticeSetupScreen.h"
#import "screens/WelcomeScreen.h"

int main(int argc, const char** argv) {
  @autoreleasepool {
    std::string screen = "menu", song, difficulty = "expert", instrument = "guitar", shot, practice, actions, keys, songFolder;
    bool bot = false;
    double seconds = 0, pauseAt = 0, delegateActionsAt = 0;
    for (int i = 1; i < argc; i++) {
      std::string a = argv[i];
      auto next = [&]() { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
      if (a == "--screen") screen = next();
      else if (a == "--song") song = next();
      else if (a == "--bot") bot = true;
      else if (a == "--difficulty") difficulty = next();
      else if (a == "--instrument") instrument = next();
      else if (a == "--practice") practice = next();
      else if (a == "--screenshot") shot = next();
      else if (a == "--seconds") seconds = atof(next().c_str());
      else if (a == "--pause-at") pauseAt = atof(next().c_str());
      else if (a == "--actions") actions = next();
      else if (a == "--keys") keys = next();
      else if (a == "--actions-at") delegateActionsAt = atof(next().c_str());
      else if (a == "--song-folder") songFolder = next();
    }
    NSApplication* app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    GCApp* delegate = [GCApp new];
    delegate.resourcePath = [[NSBundle mainBundle] resourcePath].UTF8String;
    delegate.metallibPath = delegate.resourcePath + "/default.metallib";
    delegate.screenshotPath = shot;
    delegate.screenshotSeconds = seconds;
    delegate.debugPauseAt = pauseAt;
    if (!actions.empty()) delegate.debugActions = [@(actions.c_str()) componentsSeparatedByString:@","];
    delegate.debugActionsAt = delegateActionsAt;
    if (!keys.empty()) delegate.debugKeys = [@(keys.c_str()) componentsSeparatedByString:@","];
    app.delegate = delegate;
    // route the initial screen once the app has launched
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification*) {
      if (bot) delegate.debugBot = YES;
      if (!songFolder.empty()) {
        const std::string id = gc::Library::instance().addTemporarySong(songFolder);
        if (id.empty()) { fprintf(stderr, "cannot load song folder %s\n", songFolder.c_str()); [NSApp terminate:nil]; return; }
        [delegate startSong:@(id.c_str()) instrument:@(instrument.c_str()) difficulty:@(difficulty.c_str()) mode:@"quickplay" practiceStart:0 practiceEnd:0 speed:1 loop:NO];
        return;
      }
      if (!song.empty()) {
        NSString* id = nil;
        for (const auto& e : gc::Library::instance().entries()) {
          std::string lower = e.meta.name;
          for (auto& c : lower) c = char(tolower(c));
          std::string q = song;
          for (auto& c : q) c = char(tolower(c));
          if (lower.find(q) != std::string::npos) { id = @(e.id.c_str()); break; }
        }
        if (id) {
          if (screen == "practice") { [delegate showScreen:[[PracticeSetupScreen alloc] initWithSongId:id instrument:@(instrument.c_str()) difficulty:@(difficulty.c_str())]]; return; }
          if (!practice.empty()) {
            double a = 0, b = 0, sp = 1;
            sscanf(practice.c_str(), "%lf,%lf,%lf", &a, &b, &sp);
            [delegate startSong:id instrument:@(instrument.c_str()) difficulty:@(difficulty.c_str()) mode:@"practice" practiceStart:a practiceEnd:b speed:sp loop:NO];
          } else [delegate startSong:id instrument:@(instrument.c_str()) difficulty:@(difficulty.c_str()) mode:@"quickplay" practiceStart:0 practiceEnd:0 speed:1 loop:NO];
          return;
        }
      }
      if (screen == "songs") [delegate showSongSelect:@"quickplay"];
      else if (screen == "career") [delegate showCareer];
      else if (screen == "options") [delegate showOptions];
      else if (screen == "welcome" || (screen == "menu" && !gc::settings().onboarded && shot.empty())) [delegate showScreen:[WelcomeScreen new]];
      else [delegate showMainMenu];
      if ((!practice.empty() || song.empty()) && delegate.debugActionsAt <= 0) [delegate runDebugActions];
    }];
    [app run];
  }
  return 0;
}

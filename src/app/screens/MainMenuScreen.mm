#import "MainMenuScreen.h"
#import "Chrome.h"

@implementation MainMenuScreen {
  GCMenuList* _menu;
}
- (void)enter:(GCStage*)stage {
  GCStageArt* art = [[GCStageArt alloc] initWithFrame:NSZeroRect];
  art.left = 640; art.right = 0; art.top = 0; art.bottom = 80;
  [stage addSubview:art];

  GCElement* right = [[GCElement alloc] initWithFrame:NSZeroRect];
  right.width = 220; right.height = 18;
  GCBox* dot = [[GCBox alloc] initWithFrame:NSZeroRect];
  dot.width = 7; dot.height = 7; dot.left = 0; dot.top = 6; dot.fill = GCColor(GC_YELLOW); dot.layer.cornerRadius = 3.5;
  [right addSubview:dot];
  GCLabel* status = GCCrumb(@"PLAYER 01 · KEYBOARD", GC_INK);
  status.right = 0; status.top = 0;
  [right addSubview:status];
  GCHeader(stage, @"GC / Legends of the Highway", right, NO);

  GCLabel* title = GCMakeLabel(@"Guitar Cozy", 112, YES, 900, GC_INK);
  title.left = 80; title.top = 111; title.tracking = -0.035; title.lineHeight = 106;
  [stage addSubview:title];
  GCLabel* sub = GCMakeLabel(@"YOUR STAGE. YOUR RULES.", 15, NO, 400, GC_MUTED);
  sub.left = 80; sub.top = 231; sub.tracking = 0.34;
  [stage addSubview:sub];

  GCApp* app = GCApp.shared;
  _menu = [[GCMenuList alloc] initWithItems:@[@"Quickplay", @"Career", @"Practice", @"Options", @"Credits", @"Quit"] dim:@[@NO, @NO, @NO, @NO, @YES, @YES] numbered:YES width:510 actions:@[
    ^{ [app showSongSelect:@"quickplay"]; }, ^{ [app showCareer]; }, ^{ [app showSongSelect:@"practice"]; }, ^{ [app showOptions]; }, ^{ [app showCredits]; }, ^{ [NSApp terminate:nil]; }]];
  _menu.view.left = 80; _menu.view.top = 326;
  [stage addSubview:_menu.view];

  GCLabel* kicker = GCMakeLabel(@"NO SETLIST. NO LIMITS.", 14, NO, 400, GC_YELLOW);
  kicker.tracking = 0.2; kicker.right = 136; kicker.bottom = 240; kicker.width = 400;
  [stage addSubview:kicker];
  GCLabel* promo = GCMakeLabel(@"One more song.\nThen one more.", 48, YES, 700, GC_INK);
  promo.right = 136; promo.bottom = 138; promo.width = 400; promo.lineHeight = 48; promo.wraps = YES;
  [stage addSubview:promo];
  GCLabel* promoSub = GCMakeLabel(@"Pick a track. Turn it up. Own the highway.", 16, NO, 400, GC_MUTED);
  promoSub.right = 136; promoSub.bottom = 118; promoSub.width = 400;
  [stage addSubview:promoSub];
  GCFooter(stage, GCDefaultHints());
  [_menu relayout];
}
- (void)exit {}
- (void)menuAction:(NSString*)action { [_menu handle:action]; }
@end

@implementation CreditsScreen
- (void)enter:(GCStage*)stage {
  GCStageArt* art = [[GCStageArt alloc] initWithFrame:NSZeroRect];
  art.left = 640; art.right = 0; art.top = 0; art.bottom = 80; art.artOpacity = 0.6;
  [stage addSubview:art];
  GCHeader(stage, @"GC / Credits", nil, NO);
  GCLabel* h = GCMakeLabel(@"Made for the encore.", 80, YES, 800, GC_INK);
  h.left = 48; h.top = 94;
  [stage addSubview:h];
  GCLabel* body = GCMakeLabel(@"A fan-made rhythm game inspired by Guitar Hero III. Plays community charts in the Clone Hero folder format (.chart / .mid + song.ini + audio stems).\n\nNative build: C++20, Objective-C++, Metal and CoreAudio. Sound effects are synthesized in real time. The built-in song \"Highway Burn\" was generated for this game.\n\nGuitar Hero is a trademark of Activision. This project is not affiliated with or endorsed by Activision, Neversoft, RedOctane or Harmonix.", 17, NO, 400, GC_MUTED);
  body.left = 48; body.top = 200; body.width = 560; body.wraps = YES; body.lineHeight = 26;
  [stage addSubview:body];
  GCButton* back = GCSlab(@"Back to menu", @"Esc ↗", ^{ [GCApp.shared showMainMenu]; });
  back.left = 48; back.top = 520; back.width = 320;
  [stage addSubview:back];
  GCFooter(stage, @[@[@"Esc", @"Back", @"r"]]);
}
- (void)exit {}
- (void)menuAction:(NSString*)action { if ([action isEqualToString:@"back"] || [action isEqualToString:@"confirm"]) [GCApp.shared showMainMenu]; }
@end

#import "OptionsScreen.h"
#import "Chrome.h"
#include <cmath>
#include <functional>
#include <memory>
#include "app/Settings.h"
#include "app/Library.h"
#include "audio/mixer.h"

using namespace gc;

static void (^gOnChange)(void);
static void changed() { saveSettings(); if (gOnChange) gOnChange(); }

// ------------------------------------------------------------ slider element (design: 330px track, 20px knob)
@interface GCSlider : GCElement
@property(nonatomic) double value, minValue, maxValue, step;
@property(nonatomic) BOOL accent;
@property(nonatomic, copy) void (^onChange)(double);
@end
@implementation GCSlider {
  GCBox* _track;
  GCBox* _knob;
}
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    self.width = 330; self.height = 20; self.fitContent = NO;
    _track = [[GCBox alloc] initWithFrame:NSZeroRect]; _track.left = 0; _track.right = 0; _track.top = 8; _track.height = 4; _track.fill = GCColor(GC_BORDER); [self addSubview:_track];
    _knob = [[GCBox alloc] initWithFrame:NSZeroRect]; _knob.top = 0; _knob.width = 20; _knob.height = 20; _knob.layer.cornerRadius = 10; [self addSubview:_knob];
    _step = 1;
  }
  return self;
}
- (void)layoutChildrenWithScale:(CGFloat)s {
  const double t = (_maxValue > _minValue) ? (_value - _minValue) / (_maxValue - _minValue) : 0;
  _knob.left = t * (330 - 20);
  _knob.fill = GCColor(self.accent ? GC_YELLOW : GC_INK);
  _knob.layer.cornerRadius = 10 * s;
  [super layoutChildrenWithScale:s];
}
- (void)setFromPoint:(NSPoint)p {
  const double t = std::max(0.0, std::min(1.0, (p.x - 10 * GCApp.shared.stage.scale) / (self.bounds.size.width - 20 * GCApp.shared.stage.scale)));
  double v = _minValue + t * (_maxValue - _minValue);
  v = std::round(v / _step) * _step;
  [self setValue:v notify:YES];
}
- (void)setValue:(double)v notify:(BOOL)notify {
  _value = std::max(_minValue, std::min(_maxValue, v));
  [self markDirty];
  [GCApp.shared.stage relayout];
  if (notify && _onChange) _onChange(_value);
}
- (void)nudge:(int)dir { [self setValue:_value + dir * _step notify:YES]; }
- (void)mouseDown:(NSEvent*)e { [self setFromPoint:[self convertPoint:e.locationInWindow fromView:nil]]; }
- (void)mouseDragged:(NSEvent*)e { [self setFromPoint:[self convertPoint:e.locationInWindow fromView:nil]]; }
@end

struct Row { GCElement* view; std::function<void(int)> nudge; std::function<void()> activate; };

@implementation OptionsScreen {
  NSString* _tab;
  int _pane;      // 0 = section tabs (left), 1 = option rows (right)
  int _tabIdx;    // index into kTabs, kTabs.count = "Reset defaults"
  GCButton* _resetBtn;
  BOOL _overlay, _justCaptured;
  GCStage* _stage;
  NSView* _host;
  GCBox* _root;
  GCElement* _page;
  NSMutableArray<GCButton*>* _tabButtons;
  std::vector<Row> _rows;
  int _focus;
  BOOL _controlsGamepad;
  // rebinding
  int* _captureTarget;
  GCLabel* _captureLabel;
  NSString* _capturePrev;
  // calibration
  std::unique_ptr<audio::Mixer> _calMixer;
  std::vector<double> _calTicks, _calHits;
  BOOL _calRunning;
  NSMutableArray<GCBox*>* _calCells;
  GCLabel *_calStatus, *_calCount;
  GCElement* _calResult;
}
- (instancetype)init { return [self initWithTab:@"gameplay"]; }
- (instancetype)initWithTab:(NSString*)tab { return [self initWithTab:tab overlay:NO]; }
static NSArray<NSArray<NSString*>*>* kTabs = nil;
- (instancetype)initWithTab:(NSString*)tab overlay:(BOOL)overlay {
  if ((self = [super init])) {
    if (!kTabs) kTabs = @[@[@"gameplay", @"Gameplay"], @[@"calibration", @"Calibration"], @[@"controls", @"Controls"], @[@"audio", @"Audio"], @[@"video", @"Video"], @[@"library", @"Library"]];
    _tab = tab ?: @"gameplay"; _overlay = overlay;
    for (NSUInteger i = 0; i < kTabs.count; i++) if ([kTabs[i][0] isEqualToString:_tab]) _tabIdx = (int)i;
  }
  return self;
}

- (void)enter:(GCStage*)stage {
  _stage = stage;
  __weak OptionsScreen* weakSelf = self;
  gOnChange = ^{ OptionsScreen* s = weakSelf; if (s && s.onChange) s.onChange(); };
  if (_overlay) {
    _root = [[GCBox alloc] initWithFrame:NSZeroRect];
    _root.left = 0; _root.right = 0; _root.top = 0; _root.bottom = 0;
    _root.fill = GCColor(GC_BG, 0.72);
    [stage addSubview:_root];
    _host = _root;
  } else _host = stage;
  NSView* host = _host;
  GCButton* reset = GCGhost(@"Reset defaults", ^{ auto folders = settings().songFolders; settings() = Settings(); settings().songFolders = folders; changed(); [weakSelf render]; }, 14);
  reset.width = 132; reset.height = 44; ((GCLabel*)reset.subviews.firstObject).left = 18; ((GCLabel*)reset.subviews.firstObject).top = 12;
  reset.right = 0; reset.top = -6;
  _resetBtn = reset;
  GCHeader(host, _overlay ? @"GC / Paused / Options" : @"GC / Options", reset, NO);
  GCLabel* h1 = GCMakeLabel(@"Dial it in.", 72, YES, 800, GC_INK); h1.left = 48; h1.top = 112; h1.lineHeight = 88; [host addSubview:h1];
  _tabButtons = [NSMutableArray new];
  NSArray* tabs = kTabs;
  for (NSUInteger i = 0; i < tabs.count; i++) {
    GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect]; b.left = 48; b.top = 232 + i * 72; b.width = 248; b.height = 64;
    GCLabel* l = GCMakeLabel(tabs[i][1], 28, YES, 700, GC_INK); l.left = 20; l.top = 15; [b addSubview:l];
    NSString* id = tabs[i][0];
    b.onClick = ^{ OptionsScreen* s = weakSelf; if (s) { [s stopCalibration]; s->_tab = id; s->_tabIdx = (int)i; s->_pane = 0; s->_focus = 0; [s render]; } };
    [host addSubview:b];
    [_tabButtons addObject:b];
  }
  GCBox* pageClip = [[GCBox alloc] initWithFrame:NSZeroRect]; pageClip.left = 360; pageClip.right = 48; pageClip.top = 118; pageClip.bottom = 92; pageClip.clips = YES; [host addSubview:pageClip];
  _page = [[GCElement alloc] initWithFrame:NSZeroRect]; _page.left = 0; _page.right = 0; _page.top = 0; _page.height = 2000; [pageClip addSubview:_page];
  GCFooter(host, @[@[@"↑ ↓", @"Move"], @[@"Tab", @"Switch pane"], @[@"← →", @"Adjust"], @[@"Enter", @"Select", @"g"], @[@"Esc", _overlay ? @"Back" : @"Back", @"r"]]);
  [self render];
}
- (void)exit {
  [self stopCalibration];
  Library::instance().onScan = nullptr;
  GCApp.shared.padCapture = nil;
  gOnChange = nil;
  if (_root) { [_root removeFromSuperview]; _root = nil; }
}

// ------------------------------------------------------------ widgets
- (GCLabel*)intro:(NSString*)title desc:(NSString*)desc {
  GCLabel* t = GCMakeLabel(title, 48, YES, 700, GC_INK); t.left = 0; t.top = 0; t.lineHeight = 58; [_page addSubview:t];
  GCLabel* d = GCMakeLabel(desc, 17, NO, 400, GC_MUTED); d.left = 0; d.top = 72; d.width = 700; d.wraps = YES; d.lineHeight = 26; [_page addSubview:d];
  return d;
}
- (GCBox*)rowAt:(CGFloat)y name:(NSString*)name desc:(NSString*)desc {
  GCBox* r = [[GCBox alloc] initWithFrame:NSZeroRect]; r.left = 0; r.right = 0; r.top = y; r.height = 92;
  GCBox* rule = GCRule(); rule.left = 0; rule.right = 0; rule.top = 0; [r addSubview:rule];
  GCLabel* n = GCMakeLabel(name, 21, NO, 500, GC_INK); n.left = 0; n.top = 22; [r addSubview:n];
  if (desc.length) { GCLabel* d = GCMakeLabel(desc, 15, NO, 400, GC_MUTED); d.left = 0; d.top = 54; d.width = 470; [r addSubview:d]; }
  [_page addSubview:r];
  return r;
}
- (CGFloat)slider:(CGFloat)y name:(NSString*)name desc:(NSString*)desc value:(double)v min:(double)mn max:(double)mx step:(double)st accent:(BOOL)accent fmt:(NSString* (^)(double))fmt onChange:(void (^)(double))onChange {
  GCBox* r = [self rowAt:y name:name desc:desc];
  GCSlider* s = [[GCSlider alloc] initWithFrame:NSZeroRect]; s.minValue = mn; s.maxValue = mx; s.step = st; s.value = v; s.accent = accent; s.right = 180; s.top = 36;
  GCLabel* val = GCMakeLabel(fmt(v), 34, YES, 700, GC_INK); val.uppercase = NO; val.right = 0; val.top = 24; val.width = 144; val.align = NSTextAlignmentRight; val.fitContent = NO; val.height = 42;
  s.onChange = ^(double nv) { val.text = fmt(nv); onChange(nv); changed(); };
  [r addSubview:s]; [r addSubview:val];
  _rows.push_back({r, [s](int d) { [s nudge:d]; }, nullptr});
  return y + 92;
}
- (CGFloat)toggle:(CGFloat)y name:(NSString*)name desc:(NSString*)desc value:(bool*)ref {
  GCBox* r = [self rowAt:y name:name desc:desc];
  GCButton* t = [[GCButton alloc] initWithFrame:NSZeroRect]; t.right = 0; t.top = 30; t.width = 62; t.height = 32; t.layer.cornerRadius = 16;
  GCBox* knob = [[GCBox alloc] initWithFrame:NSZeroRect]; knob.top = 4; knob.width = 24; knob.height = 24; knob.layer.cornerRadius = 12; [t addSubview:knob];
  auto paint = [t, knob, ref]() { t.fill = GCColor(*ref ? GC_YELLOW : GC_RULE); knob.fill = GCColor(*ref ? GC_BG : GC_MUTED); knob.left = *ref ? 34 : 4; };
  paint();
  auto flip = [paint, ref]() { *ref = !*ref; paint(); changed(); [GCApp.shared.stage relayout]; };
  t.onClick = ^{ flip(); };
  [r addSubview:t];
  _rows.push_back({r, [flip](int) { flip(); }, [flip]() { flip(); }});
  return y + 92;
}
- (CGFloat)segmented:(CGFloat)y name:(NSString*)name desc:(NSString*)desc options:(NSArray<NSArray<NSString*>*>*)options value:(std::string*)ref onChange:(void (^)(void))onChange {
  GCBox* r = [self rowAt:y name:name desc:desc];
  GCBox* seg = [[GCBox alloc] initWithFrame:NSZeroRect]; seg.right = 0; seg.top = 24; seg.height = 46; seg.border = GCColor(GC_BORDER);
  CGFloat x = 0;
  NSMutableArray<GCButton*>* opts = [NSMutableArray new];
  for (NSArray* o in options) {
    GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect];
    CGFloat w = 38 + [GCMakeLabel(o[1], 15, NO, 700, GC_INK) contentSizeForScale:1].width;
    b.left = x; b.top = 0; b.width = w; b.height = 44;
    GCLabel* l = GCMakeLabel(o[1], 15, NO, 400, GC_INK); l.left = 19; l.top = 13; [b addSubview:l];
    [seg addSubview:b]; [opts addObject:b];
    x += w;
  }
  seg.width = x;
  auto paint = [opts, options, ref]() {
    for (NSUInteger i = 0; i < opts.count; i++) {
      const bool sel = *ref == std::string([options[i][0] UTF8String]);
      opts[i].fill = GCColor(sel ? GC_YELLOW : GC_PANEL, sel ? 1 : 0);
      ((GCLabel*)opts[i].subviews.firstObject).color = GCColor(sel ? GC_BG : GC_INK);
      ((GCLabel*)opts[i].subviews.firstObject).weight = sel ? 700 : 400;
    }
  };
  paint();
  for (NSUInteger i = 0; i < opts.count; i++) {
    NSString* v = options[i][0];
    opts[i].onClick = ^{ *ref = v.UTF8String; paint(); changed(); if (onChange) onChange(); [GCApp.shared.stage relayout]; };
  }
  [r addSubview:seg];
  auto cycle = [opts, options, ref, paint, onChange](int d) {
    int cur = 0; for (NSUInteger i = 0; i < options.count; i++) if (*ref == std::string([options[i][0] UTF8String])) cur = (int)i;
    cur = (cur + d + (int)options.count) % (int)options.count;
    *ref = [options[cur][0] UTF8String]; paint(); changed(); if (onChange) onChange(); [GCApp.shared.stage relayout];
  };
  _rows.push_back({r, cycle, [cycle]() { cycle(1); }});
  return y + 92;
}

// ------------------------------------------------------------ pages
- (void)render {
  for (NSView* v in [_page.subviews copy]) [v removeFromSuperview];
  _rows.clear();
  for (NSUInteger i = 0; i < _tabButtons.count; i++) {
    const BOOL sel = [kTabs[i][0] isEqualToString:_tab];
    _tabButtons[i].fill = sel ? GCColor(GC_YELLOW) : nil;
    ((GCLabel*)_tabButtons[i].subviews.firstObject).color = GCColor(sel ? GC_BG : GC_INK);
  }
  Settings& s = settings();
  CGFloat y = 130;
  if ([_tab isEqualToString:@"gameplay"]) {
    [self intro:@"Play it your way." desc:@"Speed, timing window and the little rules that make the highway feel right."];
    y = [self slider:y name:@"Note speed" desc:@"How fast notes travel down the highway." value:s.noteSpeed min:0.5 max:2.5 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%.2f×", v]; } onChange:^(double v) { settings().noteSpeed = v; }];
    y = [self slider:y name:@"Hit window" desc:@"Timing tolerance in each direction. Default 90 ms." value:s.hitWindow min:40 max:200 step:5 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"±%d ms", int(v)]; } onChange:^(double v) { settings().hitWindow = v; }];
    y = [self slider:y name:@"Perfect window" desc:@"Offsets within this read as Perfect; outside it they show Early or Late." value:s.perfectWindow min:10 max:90 step:5 accent:YES fmt:^(double v) { return [NSString stringWithFormat:@"±%d ms", int(v)]; } onChange:^(double v) { settings().perfectWindow = v; }];
    y = [self toggle:y name:@"Timing feedback" desc:@"Show Perfect / Early / Late above the frets, with the offset in ms." value:&s.timingFeedback];
    y = [self toggle:y name:@"No fail" desc:@"The rock meter never ends the song." value:&s.noFail];
    y = [self toggle:y name:@"Mute guitar on miss" desc:@"GH3 style: the guitar stem drops out when you miss." value:&s.muteOnMiss];
    y = [self toggle:y name:@"Left-handed" desc:@"Flip the highway so orange is on the left." value:&s.leftHanded];
    y = [self toggle:y name:@"Show lyrics" desc:@"Display lyric events when a chart has them." value:&s.showLyrics];
    y = [self toggle:y name:@"Autoplay bot" desc:@"The game plays itself perfectly. Scores are not saved." value:&s.botMode];
    y = [self toggle:y name:@"Show demo song" desc:@"List the built-in \"Highway Burn\" in your library." value:&s.showDemoSong];
  } else if ([_tab isEqualToString:@"calibration"]) {
    [self intro:@"Right on the beat." desc:@"Every setup has a little delay. Match the sound to your strum\nand make the highway feel like an extension of your hands."];
    y = [self slider:y name:@"Audio offset" desc:@"Positive values compensate for late audio." value:s.audioOffset min:-300 max:300 step:1 accent:YES fmt:^(double v) { return [NSString stringWithFormat:@"%@%d ms", v > 0 ? @"+" : @"", int(v)]; } onChange:^(double v) { settings().audioOffset = v; }];
    y = [self slider:y name:@"Video offset" desc:@"Positive values move the visuals earlier." value:s.videoOffset min:-300 max:300 step:1 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d ms", int(v)]; } onChange:^(double v) { settings().videoOffset = v; }];
    [self calibrationCard:y + 36];
  } else if ([_tab isEqualToString:@"controls"]) {
    [self controlsPage];
  } else if ([_tab isEqualToString:@"library"]) {
    [self libraryPage];
  } else if ([_tab isEqualToString:@"audio"]) {
    [self intro:@"Turn it up." desc:@"Mix the music against the menu and hit sounds."];
    y = [self slider:y name:@"Master volume" desc:@"" value:s.masterVolume min:0 max:1 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d%%", int(v * 100 + 0.5)]; } onChange:^(double v) { settings().masterVolume = v; }];
    y = [self slider:y name:@"Music volume" desc:@"Song stems and previews." value:s.musicVolume min:0 max:1 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d%%", int(v * 100 + 0.5)]; } onChange:^(double v) { settings().musicVolume = v; }];
    y = [self slider:y name:@"SFX volume" desc:@"Miss clanks, star power, menu ticks." value:s.sfxVolume min:0 max:1 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d%%", int(v * 100 + 0.5)]; } onChange:^(double v) { settings().sfxVolume = v; }];
  } else {
    [self intro:@"Set the scene." desc:@"Everything here applies live. Pause a song and open Options to tune it while looking at the highway."];
    y = [self segmented:y name:@"Tone mapping" desc:@"None is the most vivid. Neutral keeps colours true. Filmic is softer." options:@[@[@"none", @"None (vivid)"], @[@"neutral", @"Neutral"], @[@"aces", @"Filmic"]] value:&s.toneMapping onChange:nil];
    y = [self slider:y name:@"Exposure" desc:@"Overall brightness of the highway." value:s.exposure min:0.6 max:1.6 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%.2f", v]; } onChange:^(double v) { settings().exposure = v; }];
    y = [self slider:y name:@"Saturation" desc:@"Colour intensity of gems, rails and effects." value:s.saturation min:0.6 max:1.8 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d%%", int(v * 100 + 0.5)]; } onChange:^(double v) { settings().saturation = v; }];
    y = [self slider:y name:@"Contrast" desc:@"Punch between the dark board and bright notes." value:s.contrast min:0.8 max:1.4 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%.2f", v]; } onChange:^(double v) { settings().contrast = v; }];
    y = [self segmented:y name:@"Bloom" desc:@"Glow around bright things. Off is the sharpest." options:@[@[@"off", @"Off"], @[@"low", @"Low"], @[@"medium", @"Medium"], @[@"high", @"High"]] value:&s.bloom onChange:nil];
    y = [self slider:y name:@"Effects intensity" desc:@"Size of flames, sparks and hit rings." value:s.effectsIntensity min:0.5 max:1.5 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d%%", int(v * 100 + 0.5)]; } onChange:^(double v) { settings().effectsIntensity = v; }];
    y = [self segmented:y name:@"Background" desc:@"Song background uses the chart's background image when it has one." options:@[@[@"stage", @"Stage"], @[@"song", @"Song background"], @[@"none", @"None"]] value:&s.background onChange:nil];
    y = [self segmented:y name:@"Camera" desc:@"How the highway is framed." options:@[@[@"classic", @"Classic"], @[@"close", @"Close"], @[@"high", @"High"]] value:&s.cameraPreset onChange:nil];
    y = [self toggle:y name:@"Reduce motion" desc:@"Removes camera shake and full-screen flashes." value:&s.reducedMotion];
    y = [self segmented:y name:@"Render quality" desc:@"Low disables post-processing entirely for weak GPUs." options:@[@[@"high", @"High"], @[@"medium", @"Medium"], @[@"low", @"Low"]] value:&s.quality onChange:nil];
    y = [self slider:y name:@"Render scale" desc:@"Internal resolution of the highway. Lower it on older Macs; the HUD stays sharp." value:s.renderScale min:0.5 max:1.0 step:0.05 accent:NO fmt:^(double v) { return [NSString stringWithFormat:@"%d%%", int(v * 100 + 0.5)]; } onChange:^(double v) { settings().renderScale = v; }];
  }
  [self paintFocus];
  [_stage relayout];
}

- (void)paintFocus {
  const BOOL tabsPane = _pane == 0;
  for (NSUInteger i = 0; i < _tabButtons.count; i++) {
    const BOOL f = tabsPane && (int)i == _tabIdx;
    _tabButtons[i].border = f ? GCColor(GC_INK) : nil; _tabButtons[i].borderWidth = 2;
  }
  const BOOL resetFocused = tabsPane && _tabIdx == (int)kTabs.count;
  _resetBtn.border = GCColor(resetFocused ? GC_INK : GC_BORDER); _resetBtn.borderWidth = resetFocused ? 2 : 1;
  for (size_t i = 0; i < _rows.size(); i++) {
    GCBox* r = (GCBox*)_rows[i].view;
    if ([r isKindOfClass:GCBox.class]) r.fill = (!tabsPane && (int)i == _focus) ? GCColor(GC_PANEL) : nil;
  }
  // keep focus visible
  if (_focus < (int)_rows.size()) {
    const CGFloat top = _rows[_focus].view.top;
    const CGFloat visible = _stage.stageSize.height - 118 - 92;
    CGFloat scroll = -_page.top;
    if (top + 92 > scroll + visible) scroll = top + 92 - visible;
    if (top < scroll) scroll = top;
    _page.top = -std::max<CGFloat>(0, scroll);
  }
}

// ------------------------------------------------------------ controls page
- (void)controlsPage {
  Settings& s = settings();
  [self intro:@"Your hands. Your setup." desc:@"Select a binding, then press a key or a guitar button. Esc cancels capture."];
  __weak OptionsScreen* weakSelf = self;
  GCBox* tabs = [[GCBox alloc] initWithFrame:NSZeroRect]; tabs.left = 0; tabs.top = 126; tabs.height = 52; tabs.width = 296; [_page addSubview:tabs];
  auto flipDevice = [weakSelf](int) { OptionsScreen* s = weakSelf; if (s) { s->_controlsGamepad = !s->_controlsGamepad; [s render]; } };
  _rows.push_back({tabs, flipDevice, [flipDevice]() { flipDevice(1); }});
  NSArray* names = @[@"Keyboard", @"Guitar controller"];
  CGFloat x = 0;
  for (int i = 0; i < 2; i++) {
    const BOOL sel = (i == 1) == _controlsGamepad;
    GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect]; b.left = x; b.top = 0; b.height = 52; b.width = i == 0 ? 122 : 174; b.fill = sel ? GCColor(GC_INK) : nil; b.border = sel ? nil : GCColor(GC_BORDER);
    GCLabel* l = GCMakeLabel(names[i], 17, NO, 400, sel ? GC_BG : GC_INK); l.left = 24; l.top = 14; [b addSubview:l];
    b.onClick = ^{ OptionsScreen* self2 = weakSelf; if (self2) { self2->_controlsGamepad = i == 1; [self2 render]; } };
    [tabs addSubview:b];
    x += b.width;
  }
  NSString* pad = GCApp.shared.padName;
  GCLabel* st = GCMakeLabel(pad ? [NSString stringWithFormat:@"%@ CONNECTED%@", [pad uppercaseString], GCApp.shared.padRaw ? @" (RAW HID)" : @""] : @"NO GUITAR DETECTED", 14, NO, 400, pad ? GC_GREEN : GC_MUTED); st.right = 0; st.top = 142; [_page addSubview:st];
  GCLabel* fl = GCSmallLabel(@"Fret buttons / Five lanes, one muscle memory"); fl.tracking = 0.16; fl.left = 0; fl.top = 214; [_page addSubview:fl];
  const uint32_t colors[] = {GC_GREEN, GC_RED, GC_YELLOW, GC_BLUE, GC_ORANGE};
  NSArray* fretNames = @[@"Green", @"Red", @"Yellow", @"Blue", @"Orange"];
  int* frets = _controlsGamepad ? s.pad.frets : s.keys.frets;
  for (int i = 0; i < 5; i++) {
    GCButton* card = [[GCButton alloc] initWithFrame:NSZeroRect]; card.left = i * 209; card.top = 256; card.width = 196; card.height = 144; card.fill = GCColor(GC_PANEL);
    GCBox* top = [[GCBox alloc] initWithFrame:NSZeroRect]; top.left = 0; top.right = 0; top.top = 0; top.height = 4; top.fill = GCColor(colors[i]); [card addSubview:top];
    GCLabel* n = GCMakeLabel([NSString stringWithFormat:@"%@ fret", fretNames[i]], 16, NO, 400, GC_INK); n.left = 20; n.top = 24; [card addSubview:n];
    GCLabel* k = GCMakeLabel([self keyName:frets[i]], 48, YES, 700, GC_INK); k.left = 20; k.top = 62; [card addSubview:k];
    GCLabel* rb = GCMakeLabel(@"REBIND ↗", 13, NO, 400, GC_MUTED); rb.right = 20; rb.top = 82; [card addSubview:rb];
    int* target = &frets[i];
    card.onClick = ^{ [weakSelf capture:target label:k]; };
    [_page addSubview:card];
    _rows.push_back({card, nullptr, [weakSelf, target, k]() { [weakSelf capture:target label:k]; }});
  }
  struct Bind { NSString* name; int* ref; int col; };
  std::vector<Bind> binds = _controlsGamepad ? std::vector<Bind>{{@"Strum up", &s.pad.strumUp, 0}, {@"Star power", &s.pad.starPower, 1}, {@"Strum down", &s.pad.strumDown, 0}, {@"Pause", &s.pad.pause, 1}}
                                             : std::vector<Bind>{{@"Strum up", &s.keys.strumUp, 0}, {@"Star power", &s.keys.starPower, 1}, {@"Strum down", &s.keys.strumDown, 0}, {@"Pause", &s.keys.pause, 1}, {@"Whammy", &s.keys.whammy, 0}};
  int rowL = 0, rowR = 0;
  for (const auto& b : binds) {
    int& r = b.col == 0 ? rowL : rowR;
    GCButton* row = [[GCButton alloc] initWithFrame:NSZeroRect];
    row.top = 436 + r * 58; row.height = 58; row.width = 500;
    if (b.col == 0) row.left = 0; else row.right = 0;
    GCBox* rule = GCRule(); rule.left = 0; rule.right = 0; rule.bottom = 0; [row addSubview:rule];
    GCLabel* n = GCMakeLabel(b.name, 18, NO, 400, GC_INK); n.left = 0; n.top = 18; [row addSubview:n];
    GCLabel* k = GCMakeLabel([self keyName:*b.ref], 18, NO, 400, GC_MUTED); k.right = 0; k.top = 18; [row addSubview:k];
    int* target = b.ref;
    row.onClick = ^{ [weakSelf capture:target label:k]; };
    [_page addSubview:row];
    _rows.push_back({row, nullptr, [weakSelf, target, k]() { [weakSelf capture:target label:k]; }});
    r++;
  }
  GCBox* note = [[GCBox alloc] initWithFrame:NSZeroRect]; note.left = 0; note.right = 0; note.top = 436 + std::max(rowL, rowR) * 58 + 36; note.height = 94; note.fill = GCColor(GC_PANEL); note.border = GCColor(GC_RULE);
  GCLabel* nt = GCMakeLabel(@"Defaults: A S D F G for frets, arrow keys strum, Space for star power.", 18, NO, 400, GC_INK); nt.left = 24; nt.top = 22; [note addSubview:nt];
  GCLabel* nd = GCMakeLabel(@"Click a binding, then press the key you want. Esc cancels.", 15, NO, 400, GC_MUTED); nd.left = 24; nd.top = 52; [note addSubview:nd];
  [_page addSubview:note];
}
- (NSString*)keyName:(int)code {
  if (_controlsGamepad) {
    static NSArray* pad = @[@"A", @"B", @"X", @"Y", @"LB", @"RB", @"LT", @"RT", @"Back", @"Start", @"LS", @"RS", @"D-pad ↑", @"D-pad ↓", @"D-pad ←", @"D-pad →"];
    return code >= 0 && code < (int)pad.count ? pad[code] : [NSString stringWithFormat:@"B%d", code];
  }
  return @(keyName(code).c_str());
}
- (void)capture:(int*)target label:(GCLabel*)label {
  _captureTarget = target; _captureLabel = label; _capturePrev = label.text;
  label.text = @"..."; label.color = GCColor(GC_YELLOW);
  if (_controlsGamepad) {
    __weak OptionsScreen* weakSelf = self;
    GCApp.shared.padCapture = ^(int button) {
      OptionsScreen* self2 = weakSelf;
      if (!self2 || self2->_captureTarget != target) return;
      *target = button; changed();
      label.text = [self2 keyName:button]; label.color = GCColor(GC_INK);
      self2->_captureTarget = nullptr; self2->_captureLabel = nil;
      [self2->_stage relayout];
    };
  }
  [_stage relayout];
}
- (void)flagsChanged:(NSEvent*)ev {
  // rebinding to a modifier key: take it on press
  static const NSUInteger anyMod = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
  if (!_captureTarget || _controlsGamepad || !(ev.modifierFlags & anyMod)) return;
  [self keyDown:ev];
}
- (void)keyDown:(NSEvent*)ev {
  if (!_captureTarget) return;
  if (_controlsGamepad) {  // only Esc cancels a controller capture
    if (ev.keyCode != 53) return;
    GCApp.shared.padCapture = nil;
    _captureLabel.text = _capturePrev; _captureLabel.color = GCColor(GC_INK);
    _captureTarget = nullptr; _captureLabel = nil; _justCaptured = YES;
    [_stage relayout];
    return;
  }
  if (ev.keyCode == 53) { _captureLabel.text = _capturePrev; }
  else { *_captureTarget = ev.keyCode; changed(); _captureLabel.text = [self keyName:ev.keyCode]; }
  _captureLabel.color = GCColor(GC_INK);
  _captureTarget = nullptr; _captureLabel = nil;
  _justCaptured = YES;  // the same key event also reaches menuAction; ignore it there
  [_stage relayout];
}

// ------------------------------------------------------------ calibration
- (void)calibrationCard:(CGFloat)y {
  GCBox* card = [[GCBox alloc] initWithFrame:NSZeroRect]; card.left = 0; card.right = 0; card.top = y; card.height = 310; card.fill = GCColor(GC_PANEL); card.border = GCColor(GC_RULE); [_page addSubview:card];
  GCLabel* k = GCSmallLabel(@"Automatic latency test", GC_YELLOW); k.left = 32; k.top = 30; [card addSubview:k];
  GCLabel* t = GCMakeLabel(@"16 clicks. Find your timing.", 38, YES, 700, GC_INK); t.left = 32; t.top = 54; [card addSubview:t];
  GCLabel* d = GCMakeLabel(@"Strum on each click using ↑ / ↓ or your guitar.\nWe'll suggest an audio offset when you're done.", 16, NO, 400, GC_MUTED); d.left = 32; d.top = 108; d.width = 600; d.wraps = YES; d.lineHeight = 25; [card addSubview:d];
  __weak OptionsScreen* weakSelf = self;
  GCButton* start = GCSlab(@"Start test ↗", nil, ^{ [weakSelf startCalibration]; }); start.right = 32; start.top = 40; start.width = 248; ((GCLabel*)start.subviews.firstObject).left = 0; ((GCLabel*)start.subviews.firstObject).right = 0; ((GCLabel*)start.subviews.firstObject).align = NSTextAlignmentCenter; ((GCLabel*)start.subviews.firstObject).fontSize = 28; [card addSubview:start];
  _calCells = [NSMutableArray new];
  for (int i = 0; i < 16; i++) { GCBox* c = [[GCBox alloc] initWithFrame:NSZeroRect]; c.left = 32 + i * 61; c.top = 180; c.width = 53; c.height = 38; c.fill = GCColor(GC_CELL); c.border = GCColor(i % 4 == 0 ? GC_MUTED : GC_BORDER); [card addSubview:c]; [_calCells addObject:c]; }
  _calStatus = GCMakeLabel(@"Ready when you are. Use your usual audio setup.", 15, NO, 400, GC_MUTED); _calStatus.left = 32; _calStatus.top = 254; [card addSubview:_calStatus];
  _calCount = GCMakeLabel(@"0 / 16 clicks", 15, NO, 400, GC_MUTED); _calCount.right = 32; _calCount.top = 254; [card addSubview:_calCount];
  _calResult = [[GCElement alloc] initWithFrame:NSZeroRect]; _calResult.left = 0; _calResult.right = 0; _calResult.top = y + 340; _calResult.height = 200; [_page addSubview:_calResult];
  _rows.push_back({start, nullptr, [weakSelf]() { [weakSelf startCalibration]; }});
}
- (void)startCalibration {
  [self stopCalibration];
  for (NSView* v in [_calResult.subviews copy]) [v removeFromSuperview];
  for (int i = 0; i < 16; i++) { _calCells[i].fill = GCColor(GC_CELL); _calCells[i].border = GCColor(i % 4 == 0 ? GC_MUTED : GC_BORDER); }
  if (!_calMixer) { _calMixer = std::make_unique<audio::Mixer>(); _calMixer->start(); }
  _calMixer->setSfxGain(float(settings().sfxVolume * settings().masterVolume));
  _calTicks.clear(); _calHits.clear(); _calRunning = YES;
  const double t0 = GCHostSeconds() + 1.0;
  for (int i = 0; i < 16; i++) {
    const double t = t0 + i * 0.5;
    _calTicks.push_back(t + _calMixer->outputLatency());
    auto click = std::make_shared<audio::PcmBuffer>();
    click->sampleRate = 48000; click->channels = 1;
    const int n = 48000 * 0.06;
    const double f = i % 4 == 0 ? 1200 : 800;
    for (int k = 0; k < n; k++) click->samples.push_back(float(0.3 * (sin(2 * M_PI * f * k / 48000.0) > 0 ? 1 : -1) * exp(-k / (48000.0 * 0.02))));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t((t - GCHostSeconds()) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self->_calRunning) self->_calMixer->playOneShot(click); });
  }
  _calStatus.text = @"Listen... strum on every click.";
  [self performSelector:@selector(finishCalibration) withObject:nil afterDelay:16 * 0.5 + 1.6];
  [self performSelector:@selector(pollCalibration) withObject:nil afterDelay:0.05];
  [_stage relayout];
}
- (void)pollCalibration {
  if (!_calRunning) return;
  const double now = GCHostSeconds();
  for (size_t i = 0; i < _calTicks.size(); i++) {
    if (now < _calTicks[i]) continue;
    bool hit = false, late = false;
    for (double h : _calHits) if (fabs(h - _calTicks[i]) < 0.2) { hit = true; late = fabs(h - _calTicks[i]) >= 0.06; }
    if (hit) { _calCells[i].fill = GCColor(late ? GC_ORANGE : GC_YELLOW); _calCells[i].border = _calCells[i].fill; }
    else if (now > _calTicks[i] + 0.22) { _calCells[i].fill = GCColor(GC_RED); _calCells[i].border = _calCells[i].fill; }
  }
  _calCount.text = [NSString stringWithFormat:@"%zu / 16 clicks", std::min<size_t>(16, _calHits.size())];
  [_stage relayout];
  [self performSelector:@selector(pollCalibration) withObject:nil afterDelay:0.05];
}
- (void)finishCalibration {
  _calRunning = NO;
  std::vector<double> offsets;
  for (double h : _calHits) {
    double best = 1e9;
    for (double t : _calTicks) if (fabs(h - t) < fabs(best)) best = h - t;
    if (fabs(best) < 0.2) offsets.push_back(best * 1000);
  }
  if (offsets.size() < 6) { _calStatus.text = [NSString stringWithFormat:@"Not enough strums registered (%zu). Try again.", offsets.size()]; [_stage relayout]; return; }
  std::sort(offsets.begin(), offsets.end());
  const size_t a = offsets.size() * 15 / 100, b = std::max(a + 1, offsets.size() * 85 / 100);
  double sum = 0; for (size_t i = a; i < b; i++) sum += offsets[i];
  const int avg = int(std::lround(sum / (b - a)));
  _calStatus.text = @"Test complete.";
  GCBox* card = [[GCBox alloc] initWithFrame:NSZeroRect]; card.left = 0; card.right = 0; card.top = 0; card.height = 200; card.fill = GCColor(GC_PANEL); card.border = GCColor(GC_RULE); [_calResult addSubview:card];
  GCLabel* k = GCMakeLabel(@"05 / CALIBRATION COMPLETE", 12, NO, 400, GC_YELLOW); k.tracking = 0.1; k.left = 24; k.top = 22; [card addSubview:k];
  GCLabel* t = GCMakeLabel(@"Your timing, dialed in.", 30, YES, 700, GC_INK); t.left = 24; t.top = 46; [card addSubview:t];
  GCLabel* d = GCMakeLabel([NSString stringWithFormat:@"Suggested audio offset\n%@%d ms · %zu clicks measured", avg > 0 ? @"+" : @"", avg, offsets.size()], 15, NO, 400, GC_MUTED); d.left = 24; d.top = 92; d.width = 500; d.wraps = YES; d.lineHeight = 24; [card addSubview:d];
  __weak OptionsScreen* weakSelf = self;
  GCButton* apply = [[GCButton alloc] initWithFrame:NSZeroRect]; apply.right = 24; apply.top = 78; apply.width = 260; apply.height = 44; apply.fill = GCColor(GC_YELLOW);
  GCLabel* al = GCMakeLabel([NSString stringWithFormat:@"Apply %@%d ms", avg > 0 ? @"+" : @"", avg], 23, YES, 700, GC_BG); al.left = 0; al.right = 0; al.top = 8; al.align = NSTextAlignmentCenter; [apply addSubview:al];
  apply.onClick = ^{ settings().audioOffset = avg; changed(); [weakSelf render]; };
  [card addSubview:apply];
  [_stage relayout];
}
- (void)stopCalibration {
  _calRunning = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

// ------------------------------------------------------------ input
- (void)menuAction:(NSString*)action {
  if (_captureTarget) return;
  if (_justCaptured) { _justCaptured = NO; return; }
  if (_calRunning && ([action isEqualToString:@"up"] || [action isEqualToString:@"down"])) { _calHits.push_back(GCHostSeconds()); return; }
  const BOOL up = [action isEqualToString:@"up"], down = [action isEqualToString:@"down"], left = [action isEqualToString:@"left"], right = [action isEqualToString:@"right"];
  const BOOL confirm = [action isEqualToString:@"confirm"], back = [action isEqualToString:@"back"], tab = [action isEqualToString:@"tab"] || [action isEqualToString:@"backtab"];
  if (tab) { _pane = (_pane == 0 && !_rows.empty()) ? 1 : 0; [self paintFocus]; [_stage relayout]; return; }
  if (_pane == 0) {  // section tabs (+ Reset defaults as the last stop)
    const int n = (int)kTabs.count + 1;
    if (up || down) {
      _tabIdx = (_tabIdx + (down ? 1 : n - 1)) % n;
      if (_tabIdx < (int)kTabs.count) { [self stopCalibration]; _tab = kTabs[_tabIdx][0]; _focus = 0; [self render]; }
      else { [self paintFocus]; [_stage relayout]; }
    } else if (right || confirm) {
      if (_tabIdx == (int)kTabs.count) { if (_resetBtn.onClick) _resetBtn.onClick(); }
      else if (!_rows.empty()) { _pane = 1; [self paintFocus]; [_stage relayout]; }
    } else if (back) {
      if (_overlay) { if (self.onClose) self.onClose(); }
      else [GCApp.shared showMainMenu];
    }
    return;
  }
  if (up || down) {
    if (_rows.empty()) return;
    _focus = (_focus + (down ? 1 : (int)_rows.size() - 1)) % (int)_rows.size();
    [self paintFocus]; [_stage relayout];
  } else if (left || right) {
    if (_focus < (int)_rows.size() && _rows[_focus].nudge) _rows[_focus].nudge(right ? 1 : -1);
    else if (left) { _pane = 0; [self paintFocus]; [_stage relayout]; }  // a row without a left/right action: Left returns to the sections
  } else if (confirm) {
    if (_focus < (int)_rows.size() && _rows[_focus].activate) _rows[_focus].activate();
  } else if (back) {
    _pane = 0; [self paintFocus]; [_stage relayout];
  }
}

// ------------------------------------------------------------ library page: linked song folders
- (void)libraryPage {
  [self intro:@"Your songs, your folders." desc:@"Every folder here is scanned for Clone Hero songs. Unlink one to drop its songs from the library; nothing on disk is touched."];
  __weak OptionsScreen* weakSelf = self;
  CGFloat y = 130;
  const auto folders = settings().songFolders;
  if (folders.empty()) {
    GCLabel* none = GCMakeLabel(@"No folders linked yet. The built-in demo is always available.", 17, NO, 400, GC_MUTED); none.left = 0; none.top = y + 20; [_page addSubview:none];
    y += 70;
  }
  for (const auto& f : folders) {
    const std::string folder = f;
    const size_t slash = folder.find_last_of('/');
    GCBox* r = [self rowAt:y name:@(slash == std::string::npos ? folder.c_str() : folder.c_str() + slash + 1) desc:@(folder.c_str())];
    int count = 0;
    for (const auto& e : Library::instance().entries()) if (!e.builtin && e.path.rfind(folder, 0) == 0) count++;
    GCLabel* n = GCMakeLabel([NSString stringWithFormat:@"%d song%s", count, count == 1 ? "" : "s"], 15, NO, 400, GC_MUTED); n.right = 150; n.top = 36; [r addSubview:n];
    GCButton* rm = GCGhost(@"Unlink", ^{ Library::instance().removeFolder(folder); [weakSelf render]; }, 14);
    rm.right = 0; rm.top = 24; rm.width = 110; rm.height = 44; ((GCLabel*)rm.subviews.firstObject).left = 0; ((GCLabel*)rm.subviews.firstObject).right = 0; ((GCLabel*)rm.subviews.firstObject).top = 12; ((GCLabel*)rm.subviews.firstObject).align = NSTextAlignmentCenter;
    [r addSubview:rm];
    _rows.push_back({r, nullptr, [folder, weakSelf]() { Library::instance().removeFolder(folder); [weakSelf render]; }});
    y += 92;
  }
  GCBox* addRow = [self rowAt:y name:@"Add songs folder" desc:@"Pick a Clone Hero Songs folder, or any folder containing song folders or .sng files. Subfolders are scanned."];
  GCButton* add = GCGhost(@"Add folder ↗", ^{ [weakSelf pickFolder]; }, 14);
  add.right = 0; add.top = 24; add.width = 140; add.height = 44; ((GCLabel*)add.subviews.firstObject).left = 0; ((GCLabel*)add.subviews.firstObject).right = 0; ((GCLabel*)add.subviews.firstObject).top = 12; ((GCLabel*)add.subviews.firstObject).align = NSTextAlignmentCenter;
  [addRow addSubview:add];
  _rows.push_back({addRow, nullptr, [weakSelf]() { [weakSelf pickFolder]; }});
  const auto sp = Library::instance().scan();
  if (sp.scanning) { GCLabel* st = GCMakeLabel(sp.total ? [NSString stringWithFormat:@"Scanning… %d / %d", sp.done, sp.total] : @"Scanning folders…", 15, NO, 400, GC_YELLOW); st.left = 0; st.top = y + 110; [_page addSubview:st]; }
}
- (void)pickFolder {
  NSOpenPanel* p = [NSOpenPanel openPanel];
  p.canChooseDirectories = YES; p.canChooseFiles = NO; p.allowsMultipleSelection = NO; p.title = @"Choose your songs folder";
  if ([p runModal] == NSModalResponseOK && p.URL) {
    Library::instance().addFolder(p.URL.path.UTF8String);
    __weak OptionsScreen* weakSelf = self;
    Library::instance().onScan = ^(ScanProgress) { OptionsScreen* s = weakSelf; if (s && [s->_tab isEqualToString:@"library"]) [s render]; };
    [self render];
  }
}
@end

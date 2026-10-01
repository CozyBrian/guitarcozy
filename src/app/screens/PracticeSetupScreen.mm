#import "PracticeSetupScreen.h"
#import "Chrome.h"
#include <memory>
#include "app/Library.h"
#include "app/Settings.h"
#include "platform/song_loader.h"

using namespace gc;

static NSString* fmtT(double sec) { int s = int(std::max(0.0, sec) + 0.5); return [NSString stringWithFormat:@"%02d:%02d", s / 60, s % 60]; }

struct SectionChoice { std::string name; double time, endTime; int notes; };

@implementation PracticeSetupScreen {
  NSString *_songId, *_instrument, *_difficulty;
  std::vector<SectionChoice> _sections;
  int _from, _to;
  double _speed;
  bool _loop;
  GCStage* _stage;
  GCElement* _list;
  GCLabel *_loopTitle, *_loopMeta, *_speedVal;
  NSMutableArray<GCButton*>* _speedChips;
  GCBox* _toggle;
  GCBox* _knob;
}
- (instancetype)initWithSongId:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty {
  if ((self = [super init])) { _songId = songId; _instrument = instrument; _difficulty = difficulty; _speed = 1; _loop = true; }
  return self;
}
- (void)enter:(GCStage*)stage {
  _stage = stage;
  const SongEntry* entry = Library::instance().byId(_songId.UTF8String);
  std::string err;
  auto song = entry ? loadSong(entry->path, &err) : nullptr;
  if (!song) { [GCApp.shared showSongSelect:@"practice"]; return; }
  const Track* track = song->chart.track(instrumentFromName(_instrument.UTF8String), difficultyFromName(_difficulty.UTF8String));
  const auto& chart = song->chart;
  std::vector<std::pair<std::string, double>> secs;
  for (const auto& s : chart.sections) secs.emplace_back(s.name, s.time);
  if (secs.size() < 2) {
    secs.clear();
    int i = 0;
    for (const auto& b : chart.beats) { if (b.measure) { if (i % 8 == 0) secs.emplace_back("Measure " + std::to_string(i + 1), b.time); i++; } }
    if (secs.empty()) secs.emplace_back("Whole song", 0.0);
  }
  const double end = chart.chartLength + 0.5;
  for (size_t i = 0; i < secs.size(); i++) {
    const double e = i + 1 < secs.size() ? secs[i + 1].second : end;
    int n = 0;
    if (track) for (const auto& note : track->notes) if (note.time >= secs[i].second && note.time < e) n++;
    _sections.push_back({secs[i].first, secs[i].second, e, n});
  }
  _from = 0; _to = int(_sections.size()) - 1;
  GCHeader(stage, @"GC / Practice", GCCrumb([NSString stringWithFormat:@"%@ · %@", [_instrument capitalizedString], [_difficulty capitalizedString]]), NO);
  GCLabel* h1 = GCMakeLabel(@"Make the hard part easy.", 80, YES, 800, GC_INK); h1.left = 48; h1.top = 94; h1.lineHeight = 82; [stage addSubview:h1];
  GCLabel* sub = GCMakeLabel([NSString stringWithFormat:@"%s / %s     ·     Select a section range. Find your speed.", entry->meta.name.c_str(), entry->meta.artist.c_str()], 18, NO, 400, GC_MUTED); sub.left = 48; sub.top = 190; [stage addSubview:sub];
  GCElement* head = [[GCElement alloc] initWithFrame:NSZeroRect]; head.left = 68; head.right = 604; head.top = 266; head.height = 16;
  GCLabel* c1 = GCSmallLabel(@"#"); c1.left = 0; c1.top = 0; [head addSubview:c1];
  GCLabel* c2 = GCSmallLabel(@"Section"); c2.left = 76; c2.top = 0; [head addSubview:c2];
  GCLabel* c3 = GCSmallLabel(@"Time"); c3.right = 112 + 60; c3.top = 0; c3.width = 80; [head addSubview:c3];
  GCLabel* c4 = GCSmallLabel(@"Notes"); c4.right = 0; c4.top = 0; c4.width = 112; c4.align = NSTextAlignmentRight; [head addSubview:c4];
  [stage addSubview:head];
  GCBox* clip = [[GCBox alloc] initWithFrame:NSZeroRect]; clip.left = 48; clip.right = 584; clip.top = 300; clip.bottom = 176; clip.clips = YES; [stage addSubview:clip];
  _list = [[GCElement alloc] initWithFrame:NSZeroRect]; _list.left = 0; _list.right = 0; _list.top = 0; _list.height = 2000; [clip addSubview:_list];
  GCLabel* hint = GCMakeLabel(@"↑ ↓ Set start     ·     ← → Set end\nMouse: click start, then Shift-click the final section.", 15, NO, 400, GC_MUTED); hint.left = 48; hint.bottom = 108; hint.width = 700; hint.wraps = YES; hint.lineHeight = 24; [stage addSubview:hint];
  GCBox* card = [[GCBox alloc] initWithFrame:NSZeroRect]; card.right = 48; card.top = 252; card.width = 488; card.bottom = 162; card.fill = GCColor(GC_PANEL); card.border = GCColor(GC_RULE); [stage addSubview:card];
  GCLabel* yl = GCSmallLabel(@"Your loop"); yl.left = 32; yl.top = 32; [card addSubview:yl];
  _loopTitle = GCMakeLabel(@"", 42, YES, 700, GC_INK); _loopTitle.left = 32; _loopTitle.top = 60; _loopTitle.width = 424; _loopTitle.fitContent = NO; _loopTitle.height = 52; [card addSubview:_loopTitle];
  _loopMeta = GCMakeLabel(@"", 16, NO, 400, GC_MUTED); _loopMeta.left = 32; _loopMeta.top = 122; [card addSubview:_loopMeta];
  GCLabel* pl = GCSmallLabel(@"Playback speed"); pl.left = 32; pl.top = 176; [card addSubview:pl];
  _speedVal = GCMakeLabel(@"100%", 44, YES, 700, GC_INK); _speedVal.right = 32; _speedVal.top = 152; [card addSubview:_speedVal];
  _speedChips = [NSMutableArray new];
  const double speeds[] = {0.5, 0.6, 0.7, 0.8, 0.9, 1.0};
  __weak PracticeSetupScreen* weakSelf = self;
  for (int i = 0; i < 6; i++) {
    GCButton* c = [[GCButton alloc] initWithFrame:NSZeroRect]; c.left = 32 + i * 71; c.top = 216; c.width = 66; c.height = 46; c.border = GCColor(GC_BORDER); c.fill = GCColor(GC_PANEL);
    GCLabel* l = GCMakeLabel([NSString stringWithFormat:@"%d%%", int(speeds[i] * 100)], 15, NO, 400, GC_INK); l.left = 0; l.right = 0; l.top = 14; l.align = NSTextAlignmentCenter; [c addSubview:l];
    const double sp = speeds[i];
    c.onClick = ^{ [weakSelf setSpeed:sp]; };
    [card addSubview:c]; [_speedChips addObject:c];
  }
  GCBox* rule = GCRule(); rule.left = 32; rule.width = 424; rule.top = 304; [card addSubview:rule];
  GCLabel* lt = GCMakeLabel(@"Loop section", 20, NO, 400, GC_INK); lt.left = 32; lt.top = 328; [card addSubview:lt];
  GCLabel* ld = GCMakeLabel(@"Repeat until it clicks.", 15, NO, 400, GC_MUTED); ld.left = 32; ld.top = 358; [card addSubview:ld];
  GCButton* tg = [[GCButton alloc] initWithFrame:NSZeroRect]; tg.right = 32; tg.top = 332; tg.width = 62; tg.height = 32; tg.layer.cornerRadius = 16; tg.onClick = ^{ [weakSelf toggleLoop]; };
  _knob = [[GCBox alloc] initWithFrame:NSZeroRect]; _knob.top = 4; _knob.width = 24; _knob.height = 24; _knob.layer.cornerRadius = 12; [tg addSubview:_knob];
  _toggle = tg;
  [card addSubview:tg];
  GCLabel* np = GCMakeLabel(@"No pressure. No fail.\nPractice scores don't affect personal bests.", 15, NO, 400, GC_MUTED); np.left = 32; np.top = 416; np.width = 424; np.wraps = YES; np.lineHeight = 23; [card addSubview:np];
  GCButton* go = GCSlab(@"Let's work on it", @"Enter ↗", ^{ [weakSelf start]; }); go.right = 48; go.bottom = 92; go.width = 488; [stage addSubview:go];
  GCFooter(stage, GCDefaultHints());
  [self setSpeed:1];
  [self renderList];
}
- (void)setSpeed:(double)sp {
  _speed = sp;
  _speedVal.text = [NSString stringWithFormat:@"%d%%", int(sp * 100 + 0.5)];
  const double speeds[] = {0.5, 0.6, 0.7, 0.8, 0.9, 1.0};
  for (int i = 0; i < 6; i++) {
    const bool sel = fabs(speeds[i] - sp) < 1e-6;
    _speedChips[i].fill = GCColor(sel ? GC_YELLOW : GC_PANEL);
    _speedChips[i].border = GCColor(sel ? GC_YELLOW : GC_BORDER);
    ((GCLabel*)_speedChips[i].subviews.firstObject).color = GCColor(sel ? GC_BG : GC_INK);
  }
  [self renderToggle];
  [_stage relayout];
}
- (void)renderToggle {
  _toggle.fill = GCColor(_loop ? GC_YELLOW : GC_RULE);
  _knob.fill = GCColor(_loop ? GC_BG : GC_MUTED);
  _knob.left = _loop ? 34 : 4;
}
- (void)toggleLoop { _loop = !_loop; [self renderToggle]; [_stage relayout]; }
- (void)renderList {
  for (NSView* v in [_list.subviews copy]) [v removeFromSuperview];
  CGFloat y = 0;
  __weak PracticeSetupScreen* weakSelf = self;
  for (size_t i = 0; i < _sections.size(); i++) {
    const auto& s = _sections[i];
    const bool in = (int)i >= _from && (int)i <= _to;
    NSString* tag = (int)i == _from && (int)i == _to ? @"LOOP" : (int)i == _from ? @"START" : (int)i == _to ? @"END" : [NSString stringWithFormat:@"%02zu", i + 1];
    GCButton* row = [[GCButton alloc] initWithFrame:NSZeroRect]; row.left = 0; row.right = 0; row.top = y; row.height = 68; row.fill = in ? GCColor(GC_YELLOW) : nil;
    GCBox* rule = GCRule(); rule.left = 0; rule.right = 0; rule.bottom = 0; [row addSubview:rule];
    GCLabel* n = GCMakeLabel(tag, 14, NO, 400, in ? GC_BG : GC_INK); n.left = 20; n.top = 25; [row addSubview:n];
    GCLabel* t = GCMakeLabel(@(s.name.c_str()), 22, NO, 600, in ? GC_BG : GC_INK); t.left = 96; t.top = 20; t.right = 280; t.fitContent = NO; t.height = 28; [row addSubview:t];
    GCLabel* tm = GCMakeLabel(fmtT(s.time), 16, NO, 400, in ? GC_BG : GC_INK); tm.right = 132 + 60; tm.top = 24; tm.width = 80; tm.fitContent = NO; tm.height = 20; [row addSubview:tm];
    GCLabel* nt = GCMakeLabel([NSString stringWithFormat:@"%d", s.notes], 16, NO, 400, in ? GC_BG : GC_INK); nt.right = 20; nt.top = 24; nt.width = 112; nt.align = NSTextAlignmentRight; nt.fitContent = NO; nt.height = 20; [row addSubview:nt];
    row.onClick = ^{
      PracticeSetupScreen* self2 = weakSelf; if (!self2) return;
      const bool shift = (NSEvent.modifierFlags & NSEventModifierFlagShift) != 0;
      if (shift) self2->_to = std::max(self2->_from, (int)i);
      else if ((int)i > self2->_from && (int)i <= self2->_to) self2->_to = (int)i;
      else { self2->_from = (int)i; if (self2->_to < (int)i) self2->_to = (int)i; }
      [self2 renderList];
    };
    [_list addSubview:row];
    y += 68;
  }
  _list.height = y;
  const auto& a = _sections[_from]; const auto& b = _sections[_to];
  int notes = 0; for (int i = _from; i <= _to; i++) notes += _sections[i].notes;
  _loopTitle.text = _from == _to ? @(a.name.c_str()) : [NSString stringWithFormat:@"%s → %s", a.name.c_str(), b.name.c_str()];
  _loopMeta.text = [NSString stringWithFormat:@"%@ – %@     ·     %d notes", fmtT(a.time), fmtT(b.endTime), notes];
  [_stage relayout];
}
- (void)start {
  const auto& a = _sections[_from]; const auto& b = _sections[_to];
  [GCApp.shared startSong:_songId instrument:_instrument difficulty:_difficulty mode:@"practice" practiceStart:a.time practiceEnd:b.endTime speed:_speed loop:_loop];
}
- (void)exit {}
- (void)menuAction:(NSString*)action {
  if ([action isEqualToString:@"up"]) { _from = std::max(0, _from - 1); if (_to < _from) _to = _from; }
  else if ([action isEqualToString:@"down"]) { _from = std::min((int)_sections.size() - 1, _from + 1); if (_to < _from) _to = _from; }
  else if ([action isEqualToString:@"left"]) _to = std::max(_from, _to - 1);
  else if ([action isEqualToString:@"right"]) _to = std::min((int)_sections.size() - 1, _to + 1);
  else if ([action isEqualToString:@"confirm"]) { [self start]; return; }
  else if ([action isEqualToString:@"back"]) { [GCApp.shared showSongSelect:@"practice"]; return; }
  [self renderList];
}
@end

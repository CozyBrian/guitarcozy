#import "ResultsScreen.h"
#import "Chrome.h"
#include "app/Library.h"
#include "app/Settings.h"
#include "audio/sfx.h"
#include <cmath>
#include <vector>

@implementation ResultsScreen {
  NSDictionary* _r;
  GCLabel* _scoreLabel;
  NSMutableArray<GCLabel*>* _stars;
  NSArray<GCButton*>* _buttons;
  NSInteger _idx;
  double _t0;
  BOOL _revealed;
  NSMutableArray<GCBox*>* _barFills;
  std::vector<double> _barTargets;
}
- (instancetype)initWithResult:(NSDictionary*)result { if ((self = [super init])) _r = result; return self; }

- (void)enter:(GCStage*)stage {
  NSDictionary* r = _r;
  const BOOL failed = [r[@"failed"] boolValue], fc = [r[@"fullCombo"] boolValue], newRecord = [r[@"newRecord"] boolValue];
  const int pct = int([r[@"accuracy"] doubleValue] * 100 + 0.5);
  const int stars = [r[@"stars"] intValue];
  const gc::SongEntry* e = gc::Library::instance().byId([r[@"songId"] UTF8String]);
  GCHeader(stage, @"GC / Performance", GCCrumb([NSString stringWithFormat:@"%@ · %@", [r[@"instrument"] capitalizedString], [r[@"difficulty"] capitalizedString]]), NO);
  NSString* kicker = failed ? @"Song failed" : fc ? @"Full combo" : newRecord ? @"New personal best" : @"Performance";
  NSString* title = failed ? @"One more try." : pct == 100 ? @"Flawless!" : pct >= 90 ? @"Encore!" : pct >= 70 ? @"Solid set." : @"Rough night.";
  GCLabel* k = GCMakeLabel(kicker, 14, NO, 400, GC_YELLOW); k.tracking = 0.2; k.uppercase = YES; k.left = 80; k.top = 104; [stage addSubview:k];
  GCLabel* t = GCMakeLabel(title, 120, YES, 900, GC_INK); t.tracking = -0.02; t.left = 80; t.top = 140; t.lineHeight = 114; [stage addSubview:t];
  GCLabel* song = GCMakeLabel([NSString stringWithFormat:@"%s / %s", e ? e->meta.name.c_str() : "", e ? e->meta.artist.c_str() : ""], 21, NO, 400, GC_INK); song.left = 80; song.top = 272; [stage addSubview:song];
  GCLabel* fl = GCMakeLabel(failed ? @"SCORE AT FAILURE" : @"FINAL SCORE", 14, NO, 400, GC_MUTED); fl.tracking = 0.16; fl.left = 80; fl.top = 364; [stage addSubview:fl];
  _scoreLabel = GCMakeLabel(@"0", 112, YES, 800, GC_INK); _scoreLabel.left = 80; _scoreLabel.top = 392; _scoreLabel.lineHeight = 110; [stage addSubview:_scoreLabel];
  _stars = [NSMutableArray new];
  for (int i = 0; i < 5; i++) { GCLabel* s = GCMakeLabel(@"★", 44, NO, 400, GC_RULE); s.left = 80 + i * 50; s.top = 512; [_stars addObject:s]; [stage addSubview:s]; }
  NSString* quip = failed ? [NSString stringWithFormat:@"Made it to %d%% · %@ points. No new score saved. You've got this.", int(100.0 * ([r[@"notesHit"] intValue] + [r[@"notesMissed"] intValue]) / std::max(1, [r[@"notesTotal"] intValue])), [NSNumberFormatter localizedStringFromNumber:r[@"score"] numberStyle:NSNumberFormatterDecimalStyle]]
                 : fc ? @"Not a single note out of place." : newRecord ? @"That one's going in the record books." : pct >= 90 ? @"The crowd wants one more." : @"Every miss is a note you now know.";
  GCLabel* q = GCMakeLabel(quip, 17, NO, 400, GC_MUTED); q.left = 80; q.top = 584; q.width = 620; [stage addSubview:q];
  if (const auto* hist = gc::Library::instance().history([r[@"songId"] UTF8String], gc::instrumentFromName([r[@"instrument"] UTF8String]), gc::difficultyFromName([r[@"difficulty"] UTF8String]))) {
    if (!hist->empty()) {
      int best = 0; double accSum = 0; for (const auto& h : *hist) { best = std::max(best, h.score); accSum += h.accuracy; }
      NSString* line = [NSString stringWithFormat:@"YOUR RUNS   %zu play%s · best %@ · last %@ · avg %d%% accuracy", hist->size(), hist->size() == 1 ? "" : "s", [NSNumberFormatter localizedStringFromNumber:@(best) numberStyle:NSNumberFormatterDecimalStyle], [NSNumberFormatter localizedStringFromNumber:@(hist->back().score) numberStyle:NSNumberFormatterDecimalStyle], int(accSum / hist->size() * 100 + 0.5)];
      GCLabel* hl = GCMakeLabel(line, 13, NO, 400, GC_MUTED); hl.left = 80; hl.top = 610; hl.tracking = 0.02; [stage addSubview:hl];
    }
  }
  auto stat = ^(NSString* v, NSString* l, CGFloat x, CGFloat bottom, BOOL small) {
    GCLabel* val = GCMakeLabel(v, small ? 36 : 48, YES, 700, GC_INK); val.left = x; val.bottom = bottom + (small ? 28 : 30); [stage addSubview:val];
    GCLabel* lab = GCMakeLabel(l, small ? 14 : 13, NO, 400, GC_MUTED); lab.left = x; lab.bottom = bottom; if (!small) { lab.tracking = 0.08; lab.uppercase = YES; } [stage addSubview:lab];
  };
  stat([NSString stringWithFormat:@"%d%%", pct], [NSString stringWithFormat:@"%@ / %@ hit", r[@"notesHit"], r[@"notesTotal"]], 80, 176, NO);
  stat([NSString stringWithFormat:@"%@", r[@"longestStreak"]], @"Best streak", 240, 176, NO);
  stat([NSString stringWithFormat:@"%.2f×", [r[@"maxBase"] doubleValue] > 0 ? [r[@"score"] doubleValue] / [r[@"maxBase"] doubleValue] : 0], @"Avg multiplier", 380, 176, NO);
  // breakdown
  GCBox* col = [[GCBox alloc] initWithFrame:NSZeroRect]; col.left = 800; col.top = 142; col.bottom = 166; col.width = 1; col.fill = GCColor(GC_RULE); [stage addSubview:col];
  GCLabel* bl = GCMakeLabel(@"THE BREAKDOWN", 14, NO, 400, GC_MUTED); bl.tracking = 0.16; bl.left = 836; bl.top = 142; [stage addSubview:bl];
  NSArray* sections = r[@"sections"];
  CGFloat y = 208;
  NSUInteger shown = 0;
  NSArray* offsets = r[@"offsets"];
  const NSUInteger maxSections = offsets.count ? 3 : 5;
  for (NSDictionary* s in sections) {
    if (shown >= maxSections) break;
    const double p = [s[@"total"] intValue] ? [s[@"hit"] doubleValue] / [s[@"total"] doubleValue] : 1;
    const BOOL low = p < 0.95;
    GCLabel* n = GCMakeLabel(s[@"name"], 18, NO, 400, GC_INK); n.left = 836; n.top = y; [stage addSubview:n];
    GCLabel* v = GCMakeLabel([NSString stringWithFormat:@"%d%%", int(p * 100 + 0.5)], 18, NO, 400, low ? GC_YELLOW : GC_INK); v.right = 80; v.top = y; [stage addSubview:v];
    GCBox* track = [[GCBox alloc] initWithFrame:NSZeroRect]; track.left = 836; track.right = 80; track.top = y + 36; track.height = 4; track.fill = GCColor(GC_RULE); [stage addSubview:track];
    GCBox* fill = [[GCBox alloc] initWithFrame:NSZeroRect]; fill.left = 0; fill.top = 0; fill.height = 4; fill.width = 0; fill.fill = GCColor(low ? GC_YELLOW : GC_MUTED); [track addSubview:fill];
    if (!_barFills) _barFills = [NSMutableArray new];
    [_barFills addObject:fill]; _barTargets.push_back((stage.stageSize.width - 916) * p);
    y += 76;
    shown++;
  }
  if (!sections.count) { GCLabel* none = GCMakeLabel(@"This chart has no section markers.", 15, NO, 400, GC_MUTED); none.left = 836; none.top = 200; [stage addSubview:none]; }
  // timing histogram: hit offsets across the hit window, perfect band highlighted
  if (offsets.count) {
    const double win = [r[@"hitWindow"] doubleValue] ?: 90, perfect = [r[@"perfectWindow"] doubleValue] ?: 35;
    const CGFloat hy = std::max<CGFloat>(y + 4, 440);
    GCLabel* tl = GCMakeLabel(@"TIMING", 14, NO, 400, GC_MUTED); tl.tracking = 0.16; tl.left = 836; tl.top = hy; [stage addSubview:tl];
    const int bins = 21;
    std::vector<int> counts(bins, 0);
    double sum = 0; int perfectCount = 0, early = 0, late = 0;
    for (NSNumber* n in offsets) {
      const double o = n.doubleValue;
      sum += o;
      if (fabs(o) <= perfect) perfectCount++; else if (o < 0) early++; else late++;
      int b = int(std::floor((o + win) / (2 * win) * bins));
      counts[std::max(0, std::min(bins - 1, b))]++;
    }
    int peak = 1; for (int c : counts) peak = std::max(peak, c);
    const CGFloat gw = stage.stageSize.width - 916, bw = gw / bins;
    GCBox* base = [[GCBox alloc] initWithFrame:NSZeroRect]; base.left = 836; base.right = 80; base.top = hy + 106; base.height = 1; base.fill = GCColor(GC_RULE); [stage addSubview:base];
    for (int b = 0; b < bins; b++) {
      const double centre = -win + (b + 0.5) * (2 * win) / bins;
      const bool inPerfect = fabs(centre) <= perfect;
      GCBox* bar = [[GCBox alloc] initWithFrame:NSZeroRect]; bar.left = 836 + b * bw + 1; bar.width = bw - 2; bar.height = std::max<CGFloat>(counts[b] ? 2 : 0, 54.0 * counts[b] / peak); bar.top = hy + 106 - bar.height;
      bar.fill = GCColor(inPerfect ? GC_GREEN : centre < 0 ? GC_BLUE : GC_ORANGE, counts[b] ? 1 : 0.25); [stage addSubview:bar];
    }
    GCLabel* lo = GCMakeLabel([NSString stringWithFormat:@"-%d ms early", int(win)], 12, NO, 400, GC_MUTED); lo.left = 836; lo.top = hy + 111; [stage addSubview:lo];
    GCLabel* hi = GCMakeLabel([NSString stringWithFormat:@"late +%d ms", int(win)], 12, NO, 400, GC_MUTED); hi.right = 80; hi.top = hy + 111; [stage addSubview:hi];
    const double avg = sum / offsets.count;
    GCLabel* sum1 = GCMakeLabel([NSString stringWithFormat:@"%d%% perfect · %d early · %d late · avg %+.0f ms%@", int(100.0 * perfectCount / offsets.count + 0.5), early, late, avg, fabs(avg) > 12 ? (avg > 0 ? @"  →  try a higher audio offset" : @"  →  try a lower audio offset") : @""], 13, NO, 400, GC_INK); sum1.left = 836; sum1.top = hy + 26; [stage addSubview:sum1];
    // song timeline: star power phrases in yellow, every miss as a red tick
    const double len = std::max(1.0, [r[@"length"] doubleValue]);
    const CGFloat ty = hy + 156;
    NSArray* misses = r[@"missTimes"];
    GCLabel* tl2 = GCMakeLabel([NSString stringWithFormat:@"TIMELINE   ·   %@", misses.count ? [NSString stringWithFormat:@"%lu miss%s", (unsigned long)misses.count, misses.count == 1 ? "" : "es"] : @"No misses"], 11, NO, 400, GC_MUTED); tl2.tracking = 0.14; tl2.left = 836; tl2.top = ty - 18; [stage addSubview:tl2];
    GCBox* line = [[GCBox alloc] initWithFrame:NSZeroRect]; line.left = 836; line.right = 80; line.top = ty + 6; line.height = 3; line.fill = GCColor(GC_RULE); [stage addSubview:line];
    for (NSArray* ph in r[@"spPhrases"]) {
      if (![ph isKindOfClass:NSArray.class] || ph.count != 2) continue;
      const double a = [ph[0] doubleValue] / len, b = [ph[1] doubleValue] / len;
      GCBox* seg = [[GCBox alloc] initWithFrame:NSZeroRect]; seg.left = 836 + gw * a; seg.width = std::max<CGFloat>(2, gw * (b - a)); seg.top = ty + 6; seg.height = 3; seg.fill = GCColor(GC_YELLOW, 0.8); [stage addSubview:seg];
    }
    for (NSNumber* m in misses) {
      GCBox* tick = [[GCBox alloc] initWithFrame:NSZeroRect]; tick.left = 836 + gw * (m.doubleValue / len) - 1; tick.width = 2; tick.top = ty; tick.height = 15; tick.fill = GCColor(GC_RED); [stage addSubview:tick];
    }
  }
  stat([NSString stringWithFormat:@"%@ / %@", r[@"spHit"], r[@"spTotal"]], @"Star power phrases", 836, 216, YES);
  stat([NSString stringWithFormat:@"%@", r[@"overstrums"]], @"Overstrums", 1010, 216, YES);
  // actions
  __weak ResultsScreen* weakSelf = self;
  GCButton* again = GCSlab(failed ? @"Try again" : @"Play again", @"↗", ^{ [weakSelf retry]; });
  again.left = 80; again.bottom = 40; again.width = 320; again.height = 66;
  [stage addSubview:again];
  GCButton* sel = GCGhost(@"Song select", ^{ [weakSelf songSelect]; }, 28);
  sel.left = 416; sel.bottom = 40; sel.width = 280; sel.height = 66;
  ((GCLabel*)sel.subviews.firstObject).display = YES; ((GCLabel*)sel.subviews.firstObject).weight = 700; ((GCLabel*)sel.subviews.firstObject).uppercase = YES;
  ((GCLabel*)sel.subviews.firstObject).left = 60; ((GCLabel*)sel.subviews.firstObject).top = 14;
  [stage addSubview:sel];
  // practice the weakest section straight from here
  NSDictionary* worst = nil; double worstP = 2;
  for (NSDictionary* s in sections) { if ([s[@"total"] intValue] < 4) continue; const double p = [s[@"hit"] doubleValue] / [s[@"total"] doubleValue]; if (p < worstP) { worstP = p; worst = s; } }
  NSMutableArray* btns = [NSMutableArray arrayWithObjects:again, sel, nil];
  NSString* replayPath = r[@"replay"];
  if ([replayPath isKindOfClass:NSString.class] && replayPath.length && ![r[@"isReplay"] boolValue]) {
    GCButton* watch = GCGhost(@"Watch replay", ^{ [GCApp.shared watchReplay:replayPath songId:r[@"songId"] instrument:r[@"instrument"] difficulty:r[@"difficulty"]]; }, 22);
    watch.left = 712; watch.bottom = 40; watch.width = 220; watch.height = 66;
    ((GCLabel*)watch.subviews.firstObject).display = YES; ((GCLabel*)watch.subviews.firstObject).weight = 700; ((GCLabel*)watch.subviews.firstObject).uppercase = YES;
    ((GCLabel*)watch.subviews.firstObject).left = 24; ((GCLabel*)watch.subviews.firstObject).top = 18;
    [stage addSubview:watch];
    [btns addObject:watch];
  }
  if (worst && worstP < 1.0 && ![r[@"mode"] isEqualToString:@"practice"]) {
    NSDictionary* w = worst;
    GCButton* prac = GCGhost([NSString stringWithFormat:@"Practice %@", w[@"name"]], ^{ [weakSelf practiceSection:w]; }, 22);
    prac.left = btns.count > 2 ? 948 : 712; prac.bottom = 40; prac.width = 300; prac.height = 66;
    ((GCLabel*)prac.subviews.firstObject).display = YES; ((GCLabel*)prac.subviews.firstObject).weight = 700; ((GCLabel*)prac.subviews.firstObject).uppercase = YES;
    ((GCLabel*)prac.subviews.firstObject).left = 24; ((GCLabel*)prac.subviews.firstObject).top = 18; ((GCLabel*)prac.subviews.firstObject).width = 252; ((GCLabel*)prac.subviews.firstObject).fitContent = NO; ((GCLabel*)prac.subviews.firstObject).height = 30;
    [stage addSubview:prac];
    [btns addObject:prac];
  }
  GCLabel* hint = GCMakeLabel(btns.count > 3 ? @"← →   Enter   Esc" : @"← → Choose   ·   Enter Confirm   ·   Esc Back", 15, NO, 400, GC_MUTED); hint.right = 80; hint.bottom = 62; [stage addSubview:hint];
  if ([r[@"speed"] doubleValue] < 0.999) { GCLabel* sp = GCMakeLabel([NSString stringWithFormat:@"Played at %d%% speed · not saved as a record", int([r[@"speed"] doubleValue] * 100 + 0.5)], 14, NO, 400, GC_YELLOW); sp.left = 80; sp.top = 300; [stage addSubview:sp]; }
  if ((fc || newRecord) && !failed && ![r[@"bot"] boolValue]) gc::audio::Sfx::instance().playFanfare();
  _buttons = btns;
  _t0 = GCHostSeconds();
  [self paint];
}
- (void)paint { for (NSUInteger i = 0; i < _buttons.count; i++) { _buttons[i].layer.borderColor = GCColor((NSInteger)i == _idx ? GC_INK : GC_BORDER).CGColor; _buttons[i].layer.borderWidth = (NSInteger)i == _idx ? 2 : 1; } }
- (void)update:(double)dt {
  const double target = [_r[@"score"] doubleValue];
  const double p = std::min(1.0, (GCHostSeconds() - _t0) / 0.9);
  const double eased = 1 - pow(1 - p, 3);
  _scoreLabel.text = [NSNumberFormatter localizedStringFromNumber:@(int(target * eased)) numberStyle:NSNumberFormatterDecimalStyle];
  for (NSUInteger i = 0; i < _barFills.count; i++) { const double bp = std::min(1.0, std::max(0.0, (GCHostSeconds() - _t0 - 0.15 - i * 0.08) / 0.5)); _barFills[i].width = _barTargets[i] * (1 - pow(1 - bp, 3)); }
  if (p >= 1 && !_revealed) [self landStars];
  const double since = GCHostSeconds() - _t0 - 0.9;
  if (_revealed) {
    const int n = std::min(5, [_r[@"stars"] intValue] >= 6 ? 5 : [_r[@"stars"] intValue]);
    for (int i = 0; i < n; i++) if (since >= i * 0.12) _stars[i].color = GCColor([_r[@"stars"] intValue] >= 6 ? 0xFFF3B0 : GC_YELLOW);
  }
  [GCApp.shared.stage relayout];
}
- (void)landStars { _revealed = YES; }
- (void)exit {}
- (void)retry { GCApp* app = GCApp.shared; NSDictionary* r = _r; [app startSong:r[@"songId"] instrument:r[@"instrument"] difficulty:r[@"difficulty"] mode:r[@"mode"] practiceStart:[r[@"practiceStart"] doubleValue] practiceEnd:[r[@"practiceEnd"] doubleValue] speed:[r[@"speed"] doubleValue] loop:[r[@"loop"] boolValue]]; }
- (void)songSelect { NSString* mode = _r[@"mode"]; if ([mode isEqualToString:@"career"]) [GCApp.shared showCareer]; else [GCApp.shared showSongSelect:[mode isEqualToString:@"practice"] ? @"practice" : @"quickplay"]; }
- (void)practiceSection:(NSDictionary*)sec {
  NSDictionary* r = _r;
  [GCApp.shared startSong:r[@"songId"] instrument:r[@"instrument"] difficulty:r[@"difficulty"] mode:@"practice" practiceStart:[sec[@"start"] doubleValue] practiceEnd:[sec[@"end"] doubleValue] speed:1 loop:YES];
}
- (void)menuAction:(NSString*)action {
  if ([action isEqualToString:@"confirm"] && !_revealed) { _t0 = GCHostSeconds() - 2; [self landStars]; return; }
  const NSInteger n = (NSInteger)_buttons.count;
  if ([action isEqualToString:@"left"] || [action isEqualToString:@"up"]) _idx = (_idx - 1 + n) % n;
  else if ([action isEqualToString:@"right"] || [action isEqualToString:@"down"]) _idx = (_idx + 1) % n;
  else if ([action isEqualToString:@"confirm"]) { if (_idx == 0) [self retry]; else if (_idx == 1) [self songSelect]; else { GCButton* b = _buttons[_idx]; if (b.onClick) b.onClick(); } return; }
  else if ([action isEqualToString:@"back"]) { [self songSelect]; return; }
  [self paint];
}
@end

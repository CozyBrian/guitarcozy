#import "CareerScreen.h"
#import "Chrome.h"
#include <algorithm>
#include "app/Library.h"
#include "app/Settings.h"

using namespace gc;

static const char* kTierNames[] = {"Opening Act", "Local Legends", "On the Road", "Sold Out Show", "World Tour", "Stadium Gods", "Legends of the Highway", "Encore", "Beyond the Encore", "Hall of Flame"};
static const char* kTierCopy[][2] = {{"Every legend starts somewhere.", "Warm up the crowd."}, {"Make a name for yourself.", "The next stage is one song away."}, {"Pack the van. Learn the set.", "Every town wants an encore."}, {"The line goes around the block.", "Give them a reason."}, {"New cities, bigger rooms.", "Same five frets."}, {"Eighty thousand lighters.", "Do not miss the solo."}, {"They will talk about this one.", "Play it like you mean it."}, {"One more. Then one more.", ""}, {"Nobody has gone this far.", ""}, {"The last tier there is.", ""}};
constexpr int TIER_SIZE = 5, SONGS_TO_UNLOCK = 3;

struct Tier { std::string name; std::vector<const SongEntry*> songs; bool unlocked = false; int completed = 0; };

static NSString* starsRow(int stars) { NSMutableString* s = [NSMutableString new]; int n = std::min(5, stars >= 6 ? 5 : stars); for (int i = 0; i < n; i++) [s appendString:@"★"]; for (int i = n; i < 5; i++) [s appendString:@"☆"]; return s; }
static NSString* diffLabel(Difficulty d) { switch (d) { case Difficulty::Easy: return @"Easy"; case Difficulty::Medium: return @"Medium"; case Difficulty::Hard: return @"Hard"; case Difficulty::Expert: return @"Expert"; } return @"Expert"; }

@implementation CareerScreen {
  GCStage* _stage;
  std::vector<Tier> _tiers;
  std::map<std::string, int> _progress;
  int _tierIdx, _songIdx;
  Instrument _instrument;
  Difficulty _difficulty;
  GCElement *_strip, *_hero, *_setlist, *_setHead;
  GCButton* _play;
  GCLabel* _diffBtn;
}
- (void)enter:(GCStage*)stage {
  _stage = stage;
  _instrument = instrumentFromName(settings().lastInstrument);
  _difficulty = difficultyFromName(settings().lastDifficulty);
  __weak CareerScreen* weakSelf = self;
  GCButton* db = [[GCButton alloc] initWithFrame:NSZeroRect]; db.width = 220; db.height = 18; db.onClick = ^{ [weakSelf cycleDifficulty]; };
  _diffBtn = GCCrumb(@"", GC_INK); _diffBtn.right = 0; _diffBtn.top = 0; [db addSubview:_diffBtn];
  GCHeader(stage, @"GC / Career", db, NO);
  GCLabel* h1 = GCMakeLabel(@"From garage to glory.", 80, YES, 800, GC_INK); h1.left = 48; h1.top = 94; h1.lineHeight = 82; [stage addSubview:h1];
  GCLabel* sub = GCMakeLabel([NSString stringWithFormat:@"Your library. Your tour. Clear %d songs to unlock the next tier.", SONGS_TO_UNLOCK], 17, NO, 400, GC_MUTED); sub.left = 48; sub.top = 190; [stage addSubview:sub];
  _strip = [[GCElement alloc] initWithFrame:NSZeroRect]; _strip.left = 48; _strip.right = 48; _strip.top = 266; _strip.height = 136; [stage addSubview:_strip];
  GCBox* r1 = GCRule(); r1.left = 0; r1.right = 0; r1.top = 0; [_strip addSubview:r1];
  GCBox* r2 = GCRule(); r2.left = 0; r2.right = 0; r2.bottom = 0; [_strip addSubview:r2];
  _hero = [[GCElement alloc] initWithFrame:NSZeroRect]; _hero.left = 48; _hero.top = 454; _hero.width = 492; _hero.height = 300; [stage addSubview:_hero];
  _setHead = [[GCElement alloc] initWithFrame:NSZeroRect]; _setHead.left = 620; _setHead.right = 48; _setHead.top = 454; _setHead.height = 16; [stage addSubview:_setHead];
  _setlist = [[GCElement alloc] initWithFrame:NSZeroRect]; _setlist.left = 620; _setlist.right = 48; _setlist.top = 490; _setlist.bottom = 160; [stage addSubview:_setlist];
  _play = GCSlab(@"Play", @"Enter ↗", ^{ [weakSelf play]; }); _play.left = 620; _play.right = 48; _play.bottom = 90; _play.height = 56; ((GCLabel*)_play.subviews.firstObject).fontSize = 28; ((GCLabel*)_play.subviews.firstObject).top = 11; ((GCLabel*)_play.subviews.firstObject).left = 24; [stage addSubview:_play];
  GCFooter(stage, @[@[@"↑ ↓", @"Song"], @[@"← →", @"Tier"], @[@"Tab", @"Difficulty"], @[@"Enter", @"Play", @"g"], @[@"Esc", @"Back", @"r"]]);
  [self reload];
}
- (void)cycleDifficulty {
  const Difficulty order[] = {Difficulty::Easy, Difficulty::Medium, Difficulty::Hard, Difficulty::Expert};
  int i = 0; for (int k = 0; k < 4; k++) if (order[k] == _difficulty) i = k;
  _difficulty = order[(i + 1) % 4];
  settings().lastDifficulty = difficultyName(_difficulty); saveSettings();
  [self reload];
}
- (void)reload {
  _progress = Library::instance().careerProgress(_instrument, _difficulty);
  std::vector<const SongEntry*> songs;
  for (const auto& e : Library::instance().entries()) if ((settings().showDemoSong || !e.builtin) && e.find(_instrument, _difficulty)) songs.push_back(&e);
  auto rating = [&](const SongEntry* e) { auto it = e->meta.diff.find(_instrument); return it == e->meta.diff.end() || it->second < 0 ? 3 : it->second; };
  auto density = [&](const SongEntry* e) { const auto* a = e->find(_instrument, _difficulty); return e->meta.songLength ? a->noteCount / (e->meta.songLength / 1000.0) : a->noteCount / 180.0; };
  std::stable_sort(songs.begin(), songs.end(), [&](const SongEntry* a, const SongEntry* b) { if (rating(a) != rating(b)) return rating(a) < rating(b); if (density(a) != density(b)) return density(a) < density(b); return a->meta.name < b->meta.name; });
  _tiers.clear();
  for (size_t i = 0; i < songs.size(); i += TIER_SIZE) {
    Tier t;
    t.name = _tiers.size() < 10 ? kTierNames[_tiers.size()] : "Tier " + std::to_string(_tiers.size() + 1);
    for (size_t k = i; k < std::min(songs.size(), i + TIER_SIZE); k++) { t.songs.push_back(songs[k]); if (_progress[songs[k]->id] > 0) t.completed++; }
    _tiers.push_back(t);
  }
  for (size_t i = 0; i < _tiers.size(); i++) _tiers[i].unlocked = i == 0 || (_tiers[i - 1].unlocked && _tiers[i - 1].completed >= std::min<int>(SONGS_TO_UNLOCK, (int)_tiers[i - 1].songs.size()));
  int last = 0; for (size_t i = 0; i < _tiers.size(); i++) if (_tiers[i].unlocked) last = (int)i;
  _tierIdx = std::min(_tierIdx ? _tierIdx : last, std::max(0, (int)_tiers.size() - 1));
  _songIdx = std::min(_songIdx, std::max(0, (int)(_tiers.empty() ? 1 : _tiers[_tierIdx].songs.size()) - 1));
  [self render];
}
- (void)render {
  _diffBtn.text = [NSString stringWithFormat:@"%@ · %@   ↓", [@(instrumentName(_instrument)) capitalizedString], diffLabel(_difficulty)];
  for (NSView* v in [_strip.subviews copy]) if ([v isKindOfClass:GCButton.class]) [v removeFromSuperview];
  for (NSView* v in [_hero.subviews copy]) [v removeFromSuperview];
  for (NSView* v in [_setHead.subviews copy]) [v removeFromSuperview];
  for (NSView* v in [_setlist.subviews copy]) [v removeFromSuperview];
  __weak CareerScreen* weakSelf = self;
  if (_tiers.empty()) {
    GCLabel* none = GCMakeLabel([NSString stringWithFormat:@"Nothing in your library is charted for %@ on %@.\nAdd a songs folder in Quickplay, or change the difficulty above.", [@(instrumentName(_instrument)) capitalizedString], diffLabel(_difficulty)], 17, NO, 400, GC_MUTED);
    none.left = 0; none.top = 0; none.width = 480; none.wraps = YES; none.lineHeight = 26; [_hero addSubview:none];
    _play.enabled = NO; _play.fill = GCColor(GC_RULE); ((GCLabel*)_play.subviews.firstObject).text = @"Nothing to play";
    [_stage relayout];
    return;
  }
  const int visible = std::max(1, int((_stage.stageSize.width - 96 + 16) / 269));
  const int start = std::max(0, std::min(_tierIdx - visible / 2, (int)_tiers.size() - visible));
  for (int k = 0; k < visible && start + k < (int)_tiers.size(); k++) {
    const int i = start + k;
    const Tier& t = _tiers[i];
    const bool sel = i == _tierIdx;
    const int need = i > 0 ? std::min<int>(SONGS_TO_UNLOCK, (int)_tiers[i - 1].songs.size()) - _tiers[i - 1].completed : 0;
    NSString* status = !t.unlocked ? (need == 1 ? @"Clear 1 more song" : (i > 1 && !_tiers[i - 1].unlocked) ? @"Locked" : [NSString stringWithFormat:@"Clear %d more songs", need]) : t.completed >= (int)t.songs.size() ? @"Complete" : [NSString stringWithFormat:@"%d / %zu cleared", t.completed, t.songs.size()];
    GCButton* card = [[GCButton alloc] initWithFrame:NSZeroRect]; card.left = k * 269; card.top = 18; card.width = 253; card.height = 100; card.fill = sel ? GCColor(GC_YELLOW) : nil;
    card.onClick = ^{ CareerScreen* s = weakSelf; if (s) { s->_tierIdx = i; s->_songIdx = 0; [s render]; } };
    GCLabel* n = GCMakeLabel([NSString stringWithFormat:@"%02d%@", i + 1, t.unlocked ? @"" : @" / LOCKED"], 13, NO, 400, sel ? GC_BG : GC_MUTED); n.left = 20; n.top = 16; [card addSubview:n];
    GCLabel* nm = GCMakeLabel(@(t.name.c_str()), 28, YES, 700, sel ? GC_BG : GC_INK); nm.left = 20; nm.top = 34; nm.width = 213; nm.fitContent = NO; nm.height = 34; [card addSubview:nm];
    GCLabel* st = GCMakeLabel(status, 14, NO, 400, sel ? GC_ON_YELLOW_MUTED : GC_MUTED); st.left = 20; st.top = 70; [card addSubview:st];
    [_strip addSubview:card];
  }
  const Tier& tier = _tiers[_tierIdx];
  const bool hasNext = _tierIdx + 1 < (int)_tiers.size();
  const int needed = std::min<int>(SONGS_TO_UNLOCK, (int)tier.songs.size());
  GCLabel* k = GCMakeLabel([NSString stringWithFormat:@"TIER %02d / %@", _tierIdx + 1, tier.unlocked ? @"CURRENT STOP" : @"LOCKED"], 14, NO, 400, GC_YELLOW); k.tracking = 0.18; k.left = 0; k.top = 0; [_hero addSubview:k];
  GCLabel* nm = GCMakeLabel([NSString stringWithFormat:@"%s.", tier.name.c_str()], 76, YES, 800, GC_INK); nm.left = 0; nm.top = 30; nm.width = 480; nm.wraps = YES; nm.lineHeight = 70; [_hero addSubview:nm];
  const int ci = std::min(_tierIdx, 9);
  GCLabel* copy = GCMakeLabel([NSString stringWithFormat:@"%s\n%s", kTierCopy[ci][0], kTierCopy[ci][1]], 18, NO, 400, GC_MUTED); copy.left = 0; copy.top = 116 + (nm.text.length > 12 ? 70 : 0); copy.width = 390; copy.wraps = YES; copy.lineHeight = 28; [_hero addSubview:copy];
  const CGFloat by = copy.top + 76;
  GCLabel* big = GCMakeLabel([NSString stringWithFormat:@"%d / %d", std::min(tier.completed, needed), needed], 56, YES, 700, GC_INK); big.left = 0; big.top = by; [_hero addSubview:big];
  GCLabel* bl = GCMakeLabel([NSString stringWithFormat:@"%@\n%s", hasNext ? @"CLEARS TO UNLOCK" : @"CLEARS TO FINISH", hasNext ? _tiers[_tierIdx + 1].name.c_str() : "THE TOUR"], 14, NO, 400, GC_MUTED); bl.uppercase = YES; bl.left = 112; bl.top = by + 14; bl.width = 240; bl.wraps = YES; bl.lineHeight = 22; [_hero addSubview:bl];
  GCBox* track = [[GCBox alloc] initWithFrame:NSZeroRect]; track.left = 0; track.top = by + 82; track.width = 360; track.height = 6; track.fill = GCColor(GC_RULE); [_hero addSubview:track];
  GCBox* fill = [[GCBox alloc] initWithFrame:NSZeroRect]; fill.left = 0; fill.top = 0; fill.height = 6; fill.width = 360 * std::min(1.0, double(tier.completed) / needed); fill.fill = GCColor(GC_YELLOW); [track addSubview:fill];
  int stars = 0; for (auto* e : tier.songs) stars += std::min(5, _progress[e->id]);
  GCLabel* sh = GCSmallLabel(@"Tonight's setlist"); sh.left = 0; sh.top = 0; [_setHead addSubview:sh];
  GCLabel* sr = GCSmallLabel([NSString stringWithFormat:@"%d / %zu stars", stars, tier.songs.size() * 5]); sr.right = 0; sr.top = 0; [_setHead addSubview:sr];
  for (size_t i = 0; i < tier.songs.size(); i++) {
    const SongEntry* e = tier.songs[i];
    const int st = _progress[e->id];
    const bool sel = (int)i == _songIdx;
    GCButton* row = [[GCButton alloc] initWithFrame:NSZeroRect]; row.left = 0; row.right = 0; row.top = i * 50; row.height = 50; row.fill = sel ? GCColor(GC_PANEL) : nil; row.opacityValue = tier.unlocked ? 1 : 0.5;
    GCBox* bar = [[GCBox alloc] initWithFrame:NSZeroRect]; bar.left = 0; bar.top = 0; bar.bottom = 0; bar.width = 3; bar.fill = GCColor(sel ? GC_YELLOW : GC_BG); [row addSubview:bar];
    GCBox* rule = GCRule(); rule.left = 0; rule.right = 0; rule.bottom = 0; [row addSubview:rule];
    GCLabel* n = GCMakeLabel([NSString stringWithFormat:@"%02zu", i + 1], 14, NO, 400, GC_MUTED); n.left = 23; n.top = 16; [row addSubview:n];
    GCLabel* t = GCMakeLabel(@(e->meta.name.c_str()), 19, NO, 600, GC_INK); t.left = 73; t.top = 5; t.right = 180; t.fitContent = NO; t.height = 22; [row addSubview:t];
    GCLabel* a = GCMakeLabel(@(e->meta.artist.c_str()), 13, NO, 400, GC_MUTED); a.left = 73; a.top = 28; t.right = 180; a.fitContent = NO; a.height = 16; a.right = 180; [row addSubview:a];
    GCLabel* s = GCMakeLabel(starsRow(st), 21, NO, 400, st ? GC_YELLOW : GC_MUTED); s.right = 20; s.top = 12; s.width = 152; s.align = NSTextAlignmentRight; s.fitContent = NO; s.height = 26; [row addSubview:s];
    row.onClick = ^{ CareerScreen* sc = weakSelf; if (sc) { sc->_songIdx = (int)i; [sc render]; } };
    [_setlist addSubview:row];
  }
  const SongEntry* song = _songIdx < (int)tier.songs.size() ? tier.songs[_songIdx] : nullptr;
  _play.enabled = tier.unlocked; _play.fill = GCColor(tier.unlocked ? GC_YELLOW : GC_RULE);
  ((GCLabel*)_play.subviews.firstObject).text = tier.unlocked ? [NSString stringWithFormat:@"Play %s", song ? song->meta.name.c_str() : ""] : @"Locked";
  [_stage relayout];
}
- (void)play {
  if (_tiers.empty()) return;
  const Tier& t = _tiers[_tierIdx];
  if (!t.unlocked || _songIdx >= (int)t.songs.size()) return;
  [GCApp.shared startSong:@(t.songs[_songIdx]->id.c_str()) instrument:@(instrumentName(_instrument)) difficulty:@(difficultyName(_difficulty)) mode:@"career" practiceStart:0 practiceEnd:0 speed:1 loop:NO];
}
- (void)exit {}
- (void)menuAction:(NSString*)action {
  if (_tiers.empty()) { if ([action isEqualToString:@"back"]) [GCApp.shared showMainMenu]; return; }
  const int n = (int)_tiers[_tierIdx].songs.size();
  if ([action isEqualToString:@"up"]) _songIdx = (_songIdx - 1 + n) % n;
  else if ([action isEqualToString:@"down"]) _songIdx = (_songIdx + 1) % n;
  else if ([action isEqualToString:@"left"]) { _tierIdx = std::max(0, _tierIdx - 1); _songIdx = 0; }
  else if ([action isEqualToString:@"right"]) { _tierIdx = std::min((int)_tiers.size() - 1, _tierIdx + 1); _songIdx = 0; }
  else if ([action isEqualToString:@"tab"] || [action isEqualToString:@"backtab"]) { [self cycleDifficulty]; return; }
  else if ([action isEqualToString:@"confirm"]) { [self play]; return; }
  else if ([action isEqualToString:@"back"]) { [GCApp.shared showMainMenu]; return; }
  [self render];
}
@end

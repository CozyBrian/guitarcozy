#import "SongSelectScreen.h"
#import "Chrome.h"
#import "PracticeSetupScreen.h"
#include <algorithm>
#include <memory>
#include "app/Library.h"
#include "app/Settings.h"
#include "audio/decoder.h"
#include "audio/mixer.h"
#include "platform/song_loader.h"

using namespace gc;

static NSString* fmtLen(double ms) { int s = int(ms / 1000 + 0.5); return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60]; }
static NSString* starsText(int stars, bool fc) {
  int n = std::max(0, std::min(5, stars >= 6 ? 5 : stars));
  NSMutableString* s = [NSMutableString new];
  for (int i = 0; i < n; i++) [s appendString:@"★"];
  for (int i = n; i < 5; i++) [s appendString:@"☆"];
  if (fc || stars >= 6) [s appendString:@" FC"];
  return s;
}
static NSString* instLabel(Instrument i) { switch (i) { case Instrument::Guitar: return @"Guitar"; case Instrument::Bass: return @"Bass"; case Instrument::Rhythm: return @"Rhythm"; case Instrument::Keys: return @"Keys"; case Instrument::Coop: return @"Co-op"; } return @"Guitar"; }
static NSString* diffLabel(Difficulty d) { switch (d) { case Difficulty::Easy: return @"Easy"; case Difficulty::Medium: return @"Medium"; case Difficulty::Hard: return @"Hard"; case Difficulty::Expert: return @"Expert"; } return @"Expert"; }

@interface GCSearchField : NSTextField
@end
@implementation GCSearchField
@end

// Search box: lays out its NSTextField in design units.
@interface GCSearchBox : GCBox
@property(nonatomic, strong) GCSearchField* field;
@end
@implementation GCSearchBox
- (void)layoutChildrenWithScale:(CGFloat)s {
  [super layoutChildrenWithScale:s];
  self.field.font = GCBodyFont(16 * s, 400);
  self.field.frame = NSMakeRect(52 * s, 17 * s, self.bounds.size.width - 72 * s, 22 * s);
  NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
  self.field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Search songs, artists, charters..." attributes:@{NSFontAttributeName: GCBodyFont(16 * s, 400), NSForegroundColorAttributeName: GCColor(GC_MUTED), NSParagraphStyleAttributeName: ps}];
}
@end

@implementation SongSelectScreen {
  NSString* _mode;
  GCStage* _stage;
  std::vector<const SongEntry*> _filtered;
  NSInteger _selected;
  Instrument _instrument;
  Difficulty _difficulty;
  int _sortKey;  // 0 title 1 artist 2 charter 3 diff 4 length
  bool _moreInstruments;
  NSString* _query;
  GCElement* _list;
  GCBox* _info;
  GCLabel* _status;
  GCBox* _scanBar;
  GCBox* _scanFill;
  GCLabel* _scanNote;
  GCLabel* _sortLabel;
  GCSearchField* _search;
  CGFloat _scroll;
  std::unique_ptr<audio::Mixer> _preview;
  int _previewToken;
  std::string _selectedId;  // tracked by id: library entries move when a background scan merges
}
- (instancetype)initWithMode:(NSString*)mode {
  if ((self = [super init])) {
    _mode = mode ?: @"quickplay";
    _instrument = instrumentFromName(settings().lastInstrument);
    _difficulty = difficultyFromName(settings().lastDifficulty);
    _query = @"";
  }
  return self;
}

- (void)enter:(GCStage*)stage {
  _stage = stage;
  GCApp* app = GCApp.shared;
  GCLabel* status = GCCrumb(@"PLAYER 01 · KEYBOARD");
  GCHeader(stage, [_mode isEqualToString:@"practice"] ? @"Practice / Your library" : @"Quickplay / Your library", status, YES);
  GCLabel* h1 = GCMakeLabel([_mode isEqualToString:@"practice"] ? @"Pick a song to drill." : @"Pick your next encore.", 72, YES, 800, GC_INK);
  h1.left = 48; h1.top = 92; h1.lineHeight = 80;
  [stage addSubview:h1];
  __weak SongSelectScreen* weakSelf = self;
  GCButton* add = GCGhost(@"+ Add songs folder", ^{ [weakSelf addFolder]; });
  add.right = 48; add.top = 104; add.width = 188;
  [stage addSubview:add];
  // search + sort
  GCSearchBox* searchBox = [[GCSearchBox alloc] initWithFrame:NSZeroRect];
  searchBox.left = 48; searchBox.right = 584 + 272; searchBox.top = 196; searchBox.height = 56; searchBox.fill = GCColor(GC_PANEL); searchBox.border = GCColor(GC_RULE);
  [stage addSubview:searchBox];
  GCLabel* icon = GCMakeLabel(@"⌕", 22, NO, 400, GC_MUTED); icon.left = 18; icon.top = 14; [searchBox addSubview:icon];
  _search = [[GCSearchField alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)];
  _search.bezeled = NO; _search.drawsBackground = NO; _search.textColor = GCColor(GC_INK); _search.focusRingType = NSFocusRingTypeNone;
  _search.target = self; _search.action = @selector(searchChanged:);
  [_search setContinuous:YES];
  [searchBox addSubview:_search];
  searchBox.field = _search;
  GCButton* sort = [[GCButton alloc] initWithFrame:NSZeroRect];
  sort.right = 584; sort.top = 196; sort.width = 256; sort.height = 56; sort.border = GCColor(GC_RULE);
  _sortLabel = GCMakeLabel(@"Sort: Title", 16, NO, 400, GC_INK); _sortLabel.left = 20; _sortLabel.top = 18; [sort addSubview:_sortLabel];
  GCLabel* arrow = GCMakeLabel(@"↓", 16, NO, 400, GC_INK); arrow.right = 20; arrow.top = 18; [sort addSubview:arrow];
  sort.onClick = ^{ [weakSelf cycleSort]; };
  [stage addSubview:sort];
  // table head
  GCElement* head = [[GCElement alloc] initWithFrame:NSZeroRect];
  head.left = 68; head.right = 604; head.top = 278; head.height = 16;
  GCLabel* c1 = GCSmallLabel(@"#"); c1.left = 0; c1.top = 0; [head addSubview:c1];
  GCLabel* c2 = GCSmallLabel(@"Song / Artist"); c2.left = 56; c2.top = 0; [head addSubview:c2];
  GCLabel* c3 = GCSmallLabel(@"Best"); c3.right = 104 + 40; c3.top = 0; c3.width = 100; [head addSubview:c3];
  GCLabel* c4 = GCSmallLabel(@"Length"); c4.right = 0; c4.top = 0; c4.align = NSTextAlignmentRight; c4.width = 104; [head addSubview:c4];
  [stage addSubview:head];
  GCBox* listClip = [[GCBox alloc] initWithFrame:NSZeroRect];
  listClip.left = 48; listClip.right = 584; listClip.top = 310; listClip.bottom = 178; listClip.clips = YES;
  [stage addSubview:listClip];
  _list = [[GCElement alloc] initWithFrame:NSZeroRect];
  _list.left = 0; _list.right = 0; _list.top = 0; _list.height = 2000;
  [listClip addSubview:_list];
  _status = GCMakeLabel(@"", 14, NO, 400, GC_MUTED); _status.left = 48; _status.bottom = 134; [stage addSubview:_status];
  _scanBar = [[GCBox alloc] initWithFrame:NSZeroRect]; _scanBar.left = 300; _scanBar.bottom = 140; _scanBar.width = 200; _scanBar.height = 4; _scanBar.fill = GCColor(GC_RULE); _scanBar.hidden = YES; [stage addSubview:_scanBar];
  _scanFill = [[GCBox alloc] initWithFrame:NSZeroRect]; _scanFill.left = 0; _scanFill.top = 0; _scanFill.height = 4; _scanFill.width = 0; _scanFill.fill = GCColor(GC_YELLOW); [_scanBar addSubview:_scanFill];
  _scanNote = GCMakeLabel(@"Keep browsing while we scan.", 14, NO, 400, GC_MUTED); _scanNote.left = 524; _scanNote.bottom = 134; _scanNote.hidden = YES; [stage addSubview:_scanNote];
  _info = [[GCBox alloc] initWithFrame:NSZeroRect];
  _info.right = 48; _info.top = 196; _info.width = 488; _info.bottom = 130; _info.fill = GCColor(GC_PANEL); _info.border = GCColor(GC_RULE); _info.clips = YES;
  [stage addSubview:_info];
  GCFooter(stage, GCDefaultHints());
  Library::instance().onChanged = ^{ [weakSelf refresh]; };
  Library::instance().onScan = ^(ScanProgress) { [weakSelf renderStatus]; [GCApp.shared.stage relayout]; };
  _selected = 0;
  [self refresh];
  [self.class cancelPreviousPerformRequestsWithTarget:self];
}

- (void)exit {
  Library::instance().onChanged = nullptr;
  Library::instance().onScan = nullptr;
  if (_preview) _preview->stop();
  _preview.reset();
  _previewToken++;
}

- (void)searchChanged:(id)sender { _query = _search.stringValue ?: @""; [self refresh]; }
- (void)cycleSort { _sortKey = (_sortKey + 1) % 6; _sortLabel.text = @[@"Sort: Title", @"Sort: Artist", @"Sort: Charter", @"Sort: Difficulty", @"Sort: Length", @"Sort: Recent"][_sortKey]; [self refresh]; }

- (void)addFolder {
  NSOpenPanel* p = [NSOpenPanel openPanel];
  p.canChooseDirectories = YES; p.canChooseFiles = NO; p.allowsMultipleSelection = NO; p.title = @"Choose your songs folder";
  if ([p runModal] == NSModalResponseOK && p.URL) Library::instance().addFolder(p.URL.path.UTF8String);
}

- (void)refresh {
  const std::string prevId = _selectedId;
  _filtered.clear();
  const std::string q = [_query lowercaseString].UTF8String;
  for (const auto& e : Library::instance().entries()) {
    if (e.builtin && !settings().showDemoSong) continue;
    if (!q.empty()) {
      std::string hay = e.meta.name + " " + e.meta.artist + " " + e.meta.charter + " " + e.meta.album;
      for (auto& c : hay) c = char(tolower(c));
      if (hay.find(q) == std::string::npos) continue;
    }
    _filtered.push_back(&e);
  }
  auto cmp = [](const std::string& a, const std::string& b) { return [@(a.c_str()) localizedCaseInsensitiveCompare:@(b.c_str())]; };
  std::stable_sort(_filtered.begin(), _filtered.end(), [&](const SongEntry* a, const SongEntry* b) {
    switch (_sortKey) {
      case 1: { auto r = cmp(a->meta.artist, b->meta.artist); return r != NSOrderedSame ? r == NSOrderedAscending : cmp(a->meta.name, b->meta.name) == NSOrderedAscending; }
      case 2: { auto r = cmp(a->meta.charter, b->meta.charter); return r != NSOrderedSame ? r == NSOrderedAscending : cmp(a->meta.name, b->meta.name) == NSOrderedAscending; }
      case 3: { int da = a->meta.diff.count(_instrument) ? a->meta.diff.at(_instrument) : -1, db = b->meta.diff.count(_instrument) ? b->meta.diff.at(_instrument) : -1; return da != db ? da < db : cmp(a->meta.name, b->meta.name) == NSOrderedAscending; }
      case 4: return a->meta.songLength != b->meta.songLength ? a->meta.songLength < b->meta.songLength : cmp(a->meta.name, b->meta.name) == NSOrderedAscending;
      case 5: { const double la = Library::instance().lastPlayed(a->id), lb = Library::instance().lastPlayed(b->id); return la != lb ? la > lb : cmp(a->meta.name, b->meta.name) == NSOrderedAscending; }
      default: { auto r = cmp(a->meta.name, b->meta.name); return r != NSOrderedSame ? r == NSOrderedAscending : cmp(a->meta.artist, b->meta.artist) == NSOrderedAscending; }
    }
  });
  NSInteger idx = -1;
  for (size_t i = 0; i < _filtered.size(); i++) if (_filtered[i]->id == prevId) idx = (NSInteger)i;
  if (idx < 0) idx = _filtered.empty() ? -1 : 0;
  const bool changed = idx < 0 || prevId.empty() || _filtered[idx]->id != prevId;
  _selected = idx;
  _selectedId = idx >= 0 ? _filtered[idx]->id : "";
  [self renderList];
  [self renderStatus];
  [self renderInfo:changed];
  [_stage relayout];
}

- (void)renderList {
  for (NSView* v in [_list.subviews copy]) [v removeFromSuperview];
  if (_filtered.empty()) {
    const auto& all = Library::instance().entries();
    bool empty = true;
    for (const auto& e : all) if (!e.builtin || settings().showDemoSong) { empty = false; break; }
    if (!empty && _query.length) {
      GCLabel* none = GCMakeLabel(@"No songs match your search.", 17, NO, 400, GC_MUTED); none.left = 20; none.top = 40; [_list addSubview:none];
      return;
    }
    GCBox* card = [[GCBox alloc] initWithFrame:NSZeroRect];
    card.left = 0; card.top = 24; card.width = 432; card.height = 266; card.fill = GCColor(GC_PANEL); card.border = GCColor(GC_RULE);
    GCLabel* k = GCMakeLabel(@"01 / EMPTY LIBRARY", 12, NO, 400, GC_YELLOW); k.tracking = 0.1; k.left = 24; k.top = 22; [card addSubview:k];
    GCLabel* t = GCMakeLabel(@"Your setlist starts here.", 30, YES, 700, GC_INK); t.left = 24; t.top = 52; [card addSubview:t];
    GCLabel* d = GCMakeLabel(@"Drop a songs folder or .sng file.\nOr play the built-in Highway Burn demo.", 15, NO, 400, GC_MUTED); d.left = 24; d.top = 98; d.width = 384; d.wraps = YES; d.lineHeight = 24; [card addSubview:d];
    __weak SongSelectScreen* weakSelf = self;
    GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect]; b.left = 24; b.top = 176; b.width = 384; b.height = 44; b.fill = GCColor(GC_YELLOW); b.onClick = ^{ [weakSelf addFolder]; };
    GCLabel* bl = GCMakeLabel(@"Add songs folder", 23, YES, 700, GC_BG); bl.left = 0; bl.right = 0; bl.top = 8; bl.align = NSTextAlignmentCenter; [b addSubview:bl];
    [card addSubview:b];
    GCButton* demo = [[GCButton alloc] initWithFrame:NSZeroRect]; demo.left = 24; demo.top = 230; demo.width = 384; demo.height = 24;
    demo.onClick = ^{ settings().showDemoSong = true; saveSettings(); [weakSelf refresh]; };
    GCLabel* dl = GCMakeLabel(@"Try the demo", 15, NO, 400, GC_INK); dl.left = 0; dl.top = 2; [demo addSubview:dl];
    [card addSubview:demo];
    [_list addSubview:card];
    return;
  }
  CGFloat y = 0;
  for (size_t i = 0; i < _filtered.size(); i++) {
    const SongEntry* e = _filtered[i];
    const bool sel = (NSInteger)i == _selected;
    GCButton* row = [[GCButton alloc] initWithFrame:NSZeroRect];
    row.left = 0; row.right = 0; row.top = y; row.height = 68;
    row.fill = sel ? GCColor(GC_YELLOW) : nil;
    __weak SongSelectScreen* weakSelf = self;
    row.onClick = ^{ [weakSelf selectIndex:(NSInteger)i preview:YES]; };
    GCBox* rule = GCRule(); rule.left = 0; rule.right = 0; rule.bottom = 0; [row addSubview:rule];
    GCLabel* n = GCMakeLabel([NSString stringWithFormat:@"%02zu", i + 1], 14, NO, 400, sel ? GC_BG : GC_MUTED); n.left = 20; n.top = 25; [row addSubview:n];
    GCLabel* title = GCMakeLabel(@(e->meta.name.c_str()), 20, NO, sel ? 700 : 500, sel ? GC_BG : GC_INK); title.left = 76; title.top = 12; title.right = 270; title.fitContent = NO; title.height = 24; [row addSubview:title];
    std::string artist = e->meta.artist + (e->meta.charter.empty() ? "" : "  ·  " + e->meta.charter);
    GCLabel* sub = GCMakeLabel(@(artist.c_str()), 14, NO, 400, sel ? GC_ON_YELLOW_MUTED : GC_MUTED); sub.left = 76; sub.top = 40; sub.right = 270; sub.fitContent = NO; sub.height = 18; [row addSubview:sub];
    const ScoreRecord* sc = Library::instance().score(e->id, _instrument, _difficulty);
    GCLabel* best = GCMakeLabel(sc ? starsText(sc->stars, sc->fullCombo) : @"—", 17, NO, 400, sel ? GC_BG : GC_YELLOW); best.right = 124; best.top = 23; best.width = 140; best.fitContent = NO; best.height = 22; [row addSubview:best];
    GCLabel* len = GCMakeLabel(e->meta.songLength ? fmtLen(e->meta.songLength) : @"—", 16, NO, 400, sel ? GC_BG : GC_INK); len.right = 20; len.top = 24; len.width = 104; len.align = NSTextAlignmentRight; len.fitContent = NO; len.height = 20; [row addSubview:len];
    [_list addSubview:row];
    y += 68;
  }
  _list.height = y;
  // keep the selection visible
  const CGFloat visible = _stage.stageSize.height - 310 - 178;
  const CGFloat selTop = _selected * 68;
  if (selTop < _scroll) _scroll = selTop;
  if (selTop + 68 > _scroll + visible) _scroll = selTop + 68 - visible;
  _scroll = std::max<CGFloat>(0, std::min(_scroll, std::max<CGFloat>(0, y - visible)));
  _list.top = -_scroll;
}

- (void)renderStatus {
  const ScanProgress sp = Library::instance().scan();
  if (sp.scanning) {
    _status.text = sp.total ? [NSString stringWithFormat:@"Parsing charts...  %d / %d", sp.done, sp.total] : @"Scanning folders...";
    _status.color = GCColor(GC_INK);
    _scanBar.hidden = NO; _scanNote.hidden = NO;
    _scanFill.width = sp.total ? 200.0 * sp.done / sp.total : 0;
    _scanBar.left = [_status contentSizeForScale:1].width + 48 + 24;
    _scanNote.left = _scanBar.left + 224;
    return;
  }
  _scanBar.hidden = YES; _scanNote.hidden = YES;
  _status.color = GCColor(GC_MUTED);
  const size_t folders = settings().songFolders.size();
  _status.text = [NSString stringWithFormat:@"%zu song%@   ·   %zu folder%@ connected   ·   .chart / .mid / .sng supported", _filtered.size(), _filtered.size() == 1 ? @"" : @"s", folders, folders == 1 ? @"" : @"s"];
}

- (void)renderInfo:(BOOL)preview {
  for (NSView* v in [_info.subviews copy]) [v removeFromSuperview];
  if (_selected < 0 || _selected >= (NSInteger)_filtered.size()) return;
  const SongEntry* e = _filtered[_selected];
  __weak SongSelectScreen* weakSelf = self;
  // art tile
  GCBox* art = [[GCBox alloc] initWithFrame:NSZeroRect];
  art.left = 32; art.top = 32; art.width = 172; art.height = 172; art.fill = GCColor(GC_YELLOW); art.clips = YES;
  NSImage* img = e->hasAlbumArt ? [[NSImage alloc] initWithContentsOfFile:@(e->albumPath.c_str())] : nil;
  if (img) { art.layer.contents = img; art.layer.contentsGravity = kCAGravityResizeAspectFill; art.fill = GCColor(0x111111); }
  else {
    GCLabel* k = GCMakeLabel(e->builtin ? @"GUITARCOZY ORIGINAL" : @"COMMUNITY CHART", 10, NO, 400, GC_BG); k.tracking = 0.1; k.left = 16; k.top = 16; [art addSubview:k];
    GCLabel* t = GCMakeLabel(@(e->meta.name.c_str()), 34, YES, 900, GC_BG); t.left = 16; t.top = 56; t.width = 140; t.wraps = YES; t.lineHeight = 32; [art addSubview:t];
    GCBox* bar = [[GCBox alloc] initWithFrame:NSZeroRect]; bar.left = 16; bar.bottom = 16; bar.width = 136; bar.height = 6; bar.fill = GCColor(GC_BG); [art addSubview:bar];
  }
  [_info addSubview:art];
  GCLabel* now = GCSmallLabel(@"Now previewing", GC_YELLOW); now.left = 228; now.top = 36; [_info addSubview:now];
  GCLabel* name = GCMakeLabel(@(e->meta.name.c_str()), 42, YES, 800, GC_INK); name.left = 228; name.top = 60; name.width = 228; name.wraps = YES; name.lineHeight = 42;
  // long titles: drop to a smaller size rather than running into the artist line
  if ([name contentSizeForScale:1].height > 2 * 42 + 4) { name.fontSize = 30; name.lineHeight = 30; }
  const CGFloat nameH = std::min<CGFloat>([name contentSizeForScale:1].height, 3 * 30);
  name.fitContent = NO; name.height = nameH;
  [_info addSubview:name];
  const CGFloat below = 60 + std::max<CGFloat>(nameH, 84) + 6;
  GCLabel* artist = GCMakeLabel(@(e->meta.artist.c_str()), 17, NO, 400, GC_INK); artist.left = 228; artist.top = below; artist.width = 228; [_info addSubview:artist];
  const SongAvailability* avail = e->find(_instrument, _difficulty);
  NSMutableArray* metaLines = [NSMutableArray new];
  [metaLines addObject:[NSString stringWithFormat:@"%@%@", e->builtin ? @"Built-in original" : (e->meta.album.empty() ? @"Community chart" : @(e->meta.album.c_str())), e->meta.genre.empty() ? @"" : [NSString stringWithFormat:@" · %s", e->meta.genre.c_str()]]];
  NSMutableArray* l2 = [NSMutableArray new];
  if (e->meta.songLength) [l2 addObject:fmtLen(e->meta.songLength)];
  if (avail) [l2 addObject:[NSString stringWithFormat:@"%d notes", avail->noteCount]];
  if (!e->meta.year.empty()) [l2 addObject:@(e->meta.year.c_str())];
  if (l2.count) [metaLines addObject:[l2 componentsJoinedByString:@" · "]];
  if (!e->meta.charter.empty()) [metaLines addObject:[NSString stringWithFormat:@"Chart by %s", e->meta.charter.c_str()]];
  GCLabel* meta = GCMakeLabel([metaLines componentsJoinedByString:@"\n"], 14, NO, 400, GC_MUTED); meta.left = 228; meta.top = below + 30; meta.width = 228; meta.wraps = YES; meta.lineHeight = 22; [_info addSubview:meta];
  // instrument chips
  GCLabel* il = GCSmallLabel(@"Instrument"); il.tracking = 0.12; il.left = 32; il.top = 236; [_info addSubview:il];
  CGFloat x = 32;
  std::vector<Instrument> shown = _moreInstruments ? std::vector<Instrument>{Instrument::Guitar, Instrument::Bass, Instrument::Rhythm, Instrument::Keys, Instrument::Coop} : std::vector<Instrument>{Instrument::Guitar, Instrument::Bass};
  if (!_moreInstruments && _instrument != Instrument::Guitar && _instrument != Instrument::Bass) shown.push_back(_instrument);
  for (Instrument inst : shown) {
    bool has = e->available.empty() || std::any_of(e->available.begin(), e->available.end(), [&](const SongAvailability& a) { return a.instrument == inst; });
    GCButton* chip = [[GCButton alloc] initWithFrame:NSZeroRect];
    const bool sel = inst == _instrument;
    NSString* lbl = instLabel(inst);
    CGFloat w = 36 + [GCMakeLabel(lbl, 16, NO, 400, GC_INK) contentSizeForScale:1].width;
    chip.left = x; chip.top = 260; chip.width = w; chip.height = 44;
    chip.fill = sel ? GCColor(GC_INK) : nil; chip.border = sel ? nil : GCColor(GC_BORDER); chip.opacityValue = has ? 1 : 0.35;
    GCLabel* cl = GCMakeLabel(lbl, 16, NO, 400, sel ? GC_BG : GC_INK); cl.left = 18; cl.top = 12; [chip addSubview:cl];
    chip.onClick = ^{ if (!has) return; weakSelf.instrument = inst; };
    [_info addSubview:chip];
    x += w + 8;
  }
  if (!_moreInstruments) {
    GCButton* more = [[GCButton alloc] initWithFrame:NSZeroRect]; more.left = x; more.top = 260; more.width = 80; more.height = 44;
    GCLabel* ml = GCMakeLabel(@"More ↓", 16, NO, 400, GC_MUTED); ml.left = 10; ml.top = 12; [more addSubview:ml];
    more.onClick = ^{ weakSelf.moreInstruments = YES; };
    [_info addSubview:more];
  }
  // difficulty segmented
  GCLabel* dl = GCSmallLabel(@"Difficulty"); dl.tracking = 0.12; dl.left = 32; dl.top = 330; [_info addSubview:dl];
  // chart intensity from song.ini (diff_guitar etc., 0-6) as six bars
  if (e->meta.diff.count(_instrument) && e->meta.diff.at(_instrument) >= 0) {
    const int lvl = std::min(6, e->meta.diff.at(_instrument));
    GCLabel* il2 = GCSmallLabel(@"Intensity"); il2.tracking = 0.12; il2.right = 32 + 6 * 12 + 10; il2.top = 330; [_info addSubview:il2];
    for (int i = 0; i < 6; i++) { GCBox* b = [[GCBox alloc] initWithFrame:NSZeroRect]; b.right = 32 + (5 - i) * 12; b.top = 331; b.width = 8; b.height = 12; b.fill = GCColor(i < lvl ? (lvl >= 5 ? GC_RED : lvl >= 3 ? GC_YELLOW : GC_GREEN) : GC_RULE); [_info addSubview:b]; }
  }
  GCBox* seg = [[GCBox alloc] initWithFrame:NSZeroRect]; seg.left = 32; seg.top = 354; seg.width = 424; seg.height = 46; seg.border = GCColor(GC_BORDER); [_info addSubview:seg];
  x = 0;
  for (Difficulty d : {Difficulty::Easy, Difficulty::Medium, Difficulty::Hard, Difficulty::Expert}) {
    const bool has = e->available.empty() || e->find(_instrument, d) != nullptr;
    const bool sel = d == _difficulty;
    NSString* lbl = diffLabel(d);
    CGFloat w = 38 + [GCMakeLabel(lbl, 15, NO, sel ? 700 : 400, GC_INK) contentSizeForScale:1].width;
    GCButton* opt = [[GCButton alloc] initWithFrame:NSZeroRect]; opt.left = x; opt.top = 0; opt.width = w; opt.height = 44; opt.fill = sel ? GCColor(GC_YELLOW) : nil; opt.opacityValue = has ? 1 : 0.35;
    GCLabel* ol = GCMakeLabel(lbl, 15, NO, sel ? 700 : 400, sel ? GC_BG : GC_INK); ol.left = 19; ol.top = 13; [opt addSubview:ol];
    opt.onClick = ^{ if (!has) return; weakSelf.difficulty = d; };
    [seg addSubview:opt];
    x += w;
  }
  // quickplay modifiers: speed chips + no fail
  if (![_mode isEqualToString:@"practice"]) {
    GCLabel* sl = GCSmallLabel(@"Speed"); sl.tracking = 0.12; sl.left = 32; sl.top = 412; [_info addSubview:sl];
    x = 32;
    for (int pct : {70, 80, 90, 100}) {
      const bool sel = fabs(settings().quickplaySpeed * 100 - pct) < 0.5;
      GCButton* chip = [[GCButton alloc] initWithFrame:NSZeroRect]; chip.left = x; chip.top = 434; chip.width = 66; chip.height = 32;
      chip.fill = sel ? GCColor(GC_YELLOW) : nil; chip.border = sel ? nil : GCColor(GC_BORDER);
      GCLabel* cl = GCMakeLabel([NSString stringWithFormat:@"%d%%", pct], 14, NO, sel ? 700 : 400, sel ? GC_BG : GC_INK); cl.left = 0; cl.right = 0; cl.top = 7; cl.align = NSTextAlignmentCenter; cl.fitContent = NO; cl.height = 18; [chip addSubview:cl];
      chip.onClick = ^{ settings().quickplaySpeed = pct / 100.0; saveSettings(); [weakSelf renderInfo:NO]; [GCApp.shared.stage relayout]; };
      [_info addSubview:chip];
      x += 72;
    }
    GCButton* nf = [[GCButton alloc] initWithFrame:NSZeroRect]; nf.right = 32; nf.top = 434; nf.width = 110; nf.height = 32;
    const bool noFail = settings().noFail;
    nf.fill = noFail ? GCColor(GC_YELLOW) : nil; nf.border = noFail ? nil : GCColor(GC_BORDER);
    GCLabel* nl = GCMakeLabel(noFail ? @"No fail: on" : @"No fail: off", 14, NO, noFail ? 700 : 400, noFail ? GC_BG : GC_INK); nl.left = 0; nl.right = 0; nl.top = 7; nl.align = NSTextAlignmentCenter; nl.fitContent = NO; nl.height = 18; [nf addSubview:nl];
    nf.onClick = ^{ settings().noFail = !settings().noFail; saveSettings(); [weakSelf renderInfo:NO]; [GCApp.shared.stage relayout]; };
    [_info addSubview:nf];
  }
  // personal best
  const bool compact = ![_mode isEqualToString:@"practice"];
  const ScoreRecord* sc = Library::instance().score(e->id, _instrument, _difficulty);
  if (compact) {
    // one-line personal best so the speed row fits above the slab
    GCBox* rule = GCRule(); rule.left = 32; rule.width = 424; rule.bottom = 100; [_info addSubview:rule];
    GCLabel* pbl = GCSmallLabel(@"Personal best"); pbl.tracking = 0.12; pbl.left = 32; pbl.bottom = 72; [_info addSubview:pbl];
    GCLabel* pbr = GCMakeLabel(sc ? [NSString stringWithFormat:@"%@   ·   %@   ·   %d%%", [NSNumberFormatter localizedStringFromNumber:@(sc->score) numberStyle:NSNumberFormatterDecimalStyle], starsText(sc->stars, sc->fullCombo), int(sc->accuracy * 100)] : @"No score yet", 16, NO, sc ? 600 : 400, sc ? GC_YELLOW : GC_MUTED);
    pbr.right = 32; pbr.bottom = 70; [_info addSubview:pbr];
  } else {
    GCBox* rule = GCRule(); rule.left = 32; rule.width = 424; rule.bottom = 130; [_info addSubview:rule];
    GCLabel* pbl = GCSmallLabel(@"Personal best"); pbl.tracking = 0.12; pbl.left = 32; pbl.bottom = 106; [_info addSubview:pbl];
    GCLabel* pb = GCMakeLabel(sc ? [NSString stringWithFormat:@"%@", [NSNumberFormatter localizedStringFromNumber:@(sc->score) numberStyle:NSNumberFormatterDecimalStyle]] : @"—", 40, YES, 700, GC_INK); pb.left = 32; pb.bottom = 66; [_info addSubview:pb];
    GCLabel* pbr = GCMakeLabel(sc ? [NSString stringWithFormat:@"%@\n%d%% accuracy", starsText(sc->stars, sc->fullCombo), int(sc->accuracy * 100)] : @"No score yet", sc ? 16 : 14, NO, 400, sc ? GC_YELLOW : GC_MUTED);
    pbr.right = 32; pbr.bottom = 72; pbr.width = 200; pbr.align = NSTextAlignmentRight; pbr.wraps = YES; pbr.lineHeight = 26; [_info addSubview:pbr];
  }
  const bool canPlay = e->available.empty() || avail != nullptr;
  GCButton* slab = GCSlab(canPlay ? ([_mode isEqualToString:@"practice"] ? @"Let's work on it" : @"Take the stage") : @"Not charted", canPlay ? @"Enter ↗" : nil, ^{ [weakSelf play]; });
  slab.left = 0; slab.right = 0; slab.bottom = 0;
  if (!canPlay) { slab.fill = GCColor(GC_RULE); slab.enabled = NO; }
  [_info addSubview:slab];
  if (preview) [self startPreview:e];
}

- (void)setInstrument:(Instrument)inst { _instrument = inst; settings().lastInstrument = instrumentName(inst); saveSettings(); [self refresh]; }
- (Instrument)instrument { return _instrument; }
- (void)setDifficulty:(Difficulty)d { _difficulty = d; settings().lastDifficulty = difficultyName(d); saveSettings(); [self refresh]; }
- (Difficulty)difficulty { return _difficulty; }
- (void)setMoreInstruments:(BOOL)m { _moreInstruments = m; [self renderInfo:NO]; [_stage relayout]; }
- (BOOL)moreInstruments { return _moreInstruments; }

- (void)startPreview:(const SongEntry*)e {
  if (!GCApp.shared.screenshotPath.empty()) return;
  const int token = ++_previewToken;
  const std::string songPath = e->path;
  const double start = e->meta.previewStart;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (token != self->_previewToken) return;
    const std::string folder = resolveSongFolder(songPath, nullptr);
    if (folder.empty()) return;
    std::string stem;
    for (const char* n : {"song", "guitar", "rhythm"}) {
      for (const char* ext : {".ogg", ".opus", ".mp3", ".wav", ".flac"}) {
        std::string p = folder + "/" + n + ext;
        if ([[NSFileManager defaultManager] fileExistsAtPath:@(p.c_str())]) { stem = p; break; }
      }
      if (!stem.empty()) break;
    }
    if (stem.empty()) return;
    auto pcm = audio::decodeAudioFile(stem);
    if (!pcm || token != self->_previewToken) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (token != self->_previewToken) return;
      if (!self->_preview) { self->_preview = std::make_unique<audio::Mixer>(); self->_preview->start(); }
      self->_preview->clearStems();
      self->_preview->setMusicGain(float(0.7 * settings().musicVolume * settings().masterVolume));
      self->_preview->addStem(std::move(*pcm));
      self->_preview->play(std::min(start / 1000.0, std::max(0.0, self->_preview->duration() - 10)));
    });
  });
}

- (void)selectIndex:(NSInteger)i preview:(BOOL)preview {
  if (i < 0 || i >= (NSInteger)_filtered.size()) return;
  _selected = i;
  _selectedId = _filtered[i]->id;
  [self renderList];
  [self renderInfo:preview];
  [_stage relayout];
}

- (void)play {
  if (_selected < 0 || _selected >= (NSInteger)_filtered.size()) return;
  const SongEntry* e = _filtered[_selected];
  if (!e->available.empty() && !e->find(_instrument, _difficulty)) return;
  GCApp* app = GCApp.shared;
  NSString* id = @(e->id.c_str());
  if ([_mode isEqualToString:@"practice"]) { [app showScreen:[[PracticeSetupScreen alloc] initWithSongId:id instrument:@(instrumentName(_instrument)) difficulty:@(difficultyName(_difficulty))]]; return; }
  [app startSong:id instrument:@(instrumentName(_instrument)) difficulty:@(difficultyName(_difficulty)) mode:@"quickplay" practiceStart:0 practiceEnd:0 speed:settings().quickplaySpeed loop:NO];
}

- (void)menuAction:(NSString*)action {
  if (_search.currentEditor) return;
  if ([action isEqualToString:@"up"]) { if (!_filtered.empty()) [self selectIndex:(_selected - 1 + (NSInteger)_filtered.size()) % (NSInteger)_filtered.size() preview:YES]; }
  else if ([action isEqualToString:@"down"]) { if (!_filtered.empty()) [self selectIndex:(_selected + 1) % (NSInteger)_filtered.size() preview:YES]; }
  else if ([action isEqualToString:@"left"] || [action isEqualToString:@"right"]) {
    const Difficulty order[] = {Difficulty::Easy, Difficulty::Medium, Difficulty::Hard, Difficulty::Expert};
    int i = 0; for (int k = 0; k < 4; k++) if (order[k] == _difficulty) i = k;
    [self setDifficulty:order[(i + ([action isEqualToString:@"right"] ? 1 : 3)) % 4]];
  } else if ([action isEqualToString:@"confirm"]) [self play];
  else if ([action isEqualToString:@"back"]) [GCApp.shared showMainMenu];
}
@end

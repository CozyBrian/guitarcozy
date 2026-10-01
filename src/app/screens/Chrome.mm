#import "Chrome.h"
#import "app/App.h"

GCElement* GCHeader(NSView* stage, NSString* crumb, GCElement* right, BOOL withLogo) {
  GCElement* h = [[GCElement alloc] initWithFrame:NSZeroRect];
  h.left = 48; h.right = 48; h.top = 32; h.height = 34;
  CGFloat x = 0;
  if (withLogo) {
    GCLabel* gc = GCMakeLabel(@"GC", 28, YES, 900, GC_YELLOW);
    gc.left = 0; gc.top = 0;
    [h addSubview:gc];
    x = 56;
  }
  GCLabel* c = GCCrumb(crumb);
  c.left = x; c.top = withLogo ? 8 : 8;
  [h addSubview:c];
  if (right) { right.right = 0; right.top = 8; [h addSubview:right]; }
  [stage addSubview:h];
  return h;
}

NSArray<NSArray<NSString*>*>* GCDefaultHints(void) { return @[@[@"↑ ↓", @"Navigate"], @[@"Enter", @"Select", @"g"], @[@"Esc", @"Back", @"r"]]; }

GCElement* GCFooter(NSView* stage, NSArray<NSArray<NSString*>*>* hints) {
  GCBox* f = [[GCBox alloc] initWithFrame:NSZeroRect];
  f.left = 48; f.right = 48; f.bottom = 16; f.height = 64;
  GCBox* rule = GCRule(); rule.left = 0; rule.right = 0; rule.top = 0; [f addSubview:rule];
  CGFloat x = 0;
  for (NSArray* hint in hints) {
    if (hint.count > 2) {
      GCBox* dot = [[GCBox alloc] initWithFrame:NSZeroRect];
      dot.width = 20; dot.height = 20; dot.left = x; dot.top = 22;
      dot.fill = GCColor([hint[2] isEqualToString:@"g"] ? GC_GREEN : GC_RED);
      dot.layer.cornerRadius = 10;
      [f addSubview:dot];
      x += 30;
    }
    GCLabel* l = GCMakeLabel([NSString stringWithFormat:@"%@ %@", hint[0], hint[1]], 15, NO, 400, GC_INK);
    l.left = x; l.top = 23;
    [f addSubview:l];
    // approximate width (labels are fit-content but we need x advance now)
    x += [l contentSizeForScale:1].width + 28;
  }
  GCLabel* tag = GCMakeLabel(@"COMMUNITY CHARTS. INDEPENDENT SPIRIT.", 15, NO, 400, GC_MUTED);
  tag.right = 0; tag.top = 23;
  [f addSubview:tag];
  [stage addSubview:f];
  return f;
}

@implementation GCMenuList {
  NSMutableArray<GCButton*>* _items;
  NSMutableArray<GCLabel*>* _labels;
  NSMutableArray<GCLabel*>* _numbers;
  NSMutableArray<GCLabel*>* _arrows;
  NSArray<void (^)(void)>* _actions;
  NSArray<NSNumber*>* _dim;
  BOOL _numbered;
  CGFloat _width;
}
- (instancetype)initWithItems:(NSArray<NSString*>*)labels dim:(NSArray<NSNumber*>*)dim numbered:(BOOL)numbered width:(CGFloat)width actions:(NSArray<void (^)(void)>*)actions {
  if ((self = [super init])) {
    _actions = actions; _dim = dim; _numbered = numbered; _width = width;
    _items = [NSMutableArray new]; _labels = [NSMutableArray new]; _numbers = [NSMutableArray new]; _arrows = [NSMutableArray new];
    self.view = [[GCElement alloc] initWithFrame:NSZeroRect];
    self.view.width = width;
    for (NSUInteger i = 0; i < labels.count; i++) {
      GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect];
      b.left = 0; b.width = width; b.height = 68;
      __weak GCMenuList* weakSelf = self;
      b.onHover = ^(BOOL in) { if (in) [weakSelf select:(NSInteger)i]; };
      b.onClick = ^{ [weakSelf select:(NSInteger)i]; [weakSelf confirm]; };
      GCLabel* n = GCMakeLabel([NSString stringWithFormat:@"%02lu", (unsigned long)(i + 1)], 14, NO, 400, GC_MUTED);
      n.left = 28; n.top = 25; n.width = 32;
      if (numbered) [b addSubview:n];
      GCLabel* l = GCMakeLabel(labels[i], 40, YES, 700, GC_INK);
      l.left = numbered ? 84 : 28; l.top = 10;
      [b addSubview:l];
      GCLabel* a = GCMakeLabel(@"↗", 30, NO, 400, GC_BG);
      a.right = 28; a.top = 24; a.opacityValue = 0;
      [b addSubview:a];
      [self.view addSubview:b];
      [_items addObject:b]; [_labels addObject:l]; [_numbers addObject:n]; [_arrows addObject:a];
    }
    [self select:0];
  }
  return self;
}
- (void)relayout {
  CGFloat y = 0;
  for (NSUInteger i = 0; i < _items.count; i++) {
    const BOOL sel = (NSInteger)i == _selected;
    const BOOL dim = i < _dim.count && _dim[i].boolValue;
    GCButton* b = _items[i];
    GCLabel* l = _labels[i];
    b.top = y;
    b.height = sel ? 88 : 68;
    b.fill = sel ? GCColor(GC_YELLOW) : nil;
    l.color = GCColor(sel ? GC_BG : (dim ? GC_MUTED : GC_INK));
    l.fontSize = sel ? 48 : (dim ? 28 : 40);
    l.weight = sel ? 800 : (dim ? 600 : 700);
    l.top = sel ? 15 : (dim ? 17 : 10);
    _numbers[i].color = GCColor(sel ? GC_BG : GC_MUTED);
    _numbers[i].top = sel ? 35 : 25;
    _arrows[i].opacityValue = sel ? 1 : 0;
    y += b.height;
  }
  self.view.height = y;
  [GCApp.shared.stage relayout];
}
- (void)select:(NSInteger)i {
  if (i < 0 || i >= (NSInteger)_items.count) return;
  _selected = i;
  [self relayout];
}
- (void)confirm { if (_selected < (NSInteger)_actions.count) _actions[_selected](); }
- (BOOL)handle:(NSString*)action {
  if ([action isEqualToString:@"up"]) { [self select:(_selected - 1 + (NSInteger)_items.count) % (NSInteger)_items.count]; if (self.onMove) self.onMove(); }
  else if ([action isEqualToString:@"down"]) { [self select:(_selected + 1) % (NSInteger)_items.count]; if (self.onMove) self.onMove(); }
  else if ([action isEqualToString:@"confirm"]) [self confirm];
  else return NO;
  return YES;
}
@end

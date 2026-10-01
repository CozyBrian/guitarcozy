#import "Stage.h"
#import <CoreText/CoreText.h>
#include <cmath>
#include <string>
#include <vector>

const CGFloat GCUnset = NAN;
static inline BOOL isSet(CGFloat v) { return !std::isnan(v); }

NSColor* GCColor(uint32_t hex, CGFloat alpha) {
  return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:alpha];
}

static BOOL gFontsRegistered = NO;
void GCRegisterFonts(NSString* dir) {
  if (gFontsRegistered) return;
  gFontsRegistered = YES;
  for (NSString* f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
    if (![f.pathExtension isEqualToString:@"ttf"]) continue;
    CFErrorRef err = nullptr;
    CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:f]], kCTFontManagerScopeProcess, &err);
  }
}

NSFont* GCDisplayFont(CGFloat size, CGFloat weight) {
  NSString* name = weight >= 850 ? @"BarlowCondensed-Black" : weight >= 750 ? @"BarlowCondensed-ExtraBold" : weight >= 650 ? @"BarlowCondensed-Bold" : @"BarlowCondensed-SemiBold";
  return [NSFont fontWithName:name size:size] ?: [NSFont boldSystemFontOfSize:size];
}
NSFont* GCBodyFont(CGFloat size, CGFloat weight) {
  NSFontWeight w = weight >= 650 ? NSFontWeightBold : weight >= 550 ? NSFontWeightSemibold : weight >= 450 ? NSFontWeightMedium : NSFontWeightRegular;
  return [NSFont systemFontOfSize:size weight:w];
}
NSString* GCUpper(NSString* s) { return [s uppercaseString]; }

// ------------------------------------------------------------------ GCElement
@implementation GCElement {
  BOOL _dirty, _subtreeDirty;
  NSRect _laidOutBounds;
  CGFloat _laidOutScale;
}
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    _left = _right = _top = _bottom = _width = _height = GCUnset;
    _opacityValue = 1;
    _dirty = YES;
    self.wantsLayer = YES;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)markDirty {
  _dirty = YES;
  for (NSView* v = self.superview; v; v = v.superview) {
    if ([v isKindOfClass:GCElement.class]) { if (((GCElement*)v)->_subtreeDirty) break; ((GCElement*)v)->_subtreeDirty = YES; }
    else if ([v isKindOfClass:GCStage.class]) { [(GCStage*)v noteChildDirty]; break; }
  }
}
- (BOOL)needsLayout { return _dirty || _subtreeDirty; }
- (void)clearLayoutFlags { _dirty = NO; _subtreeDirty = NO; }
- (void)didAddSubview:(NSView*)v { [super didAddSubview:v]; [self markDirty]; }
- (void)willRemoveSubview:(NSView*)v { [super willRemoveSubview:v]; [self markDirty]; }
#define GC_DIRTY_SETTER(T, name, Name) - (void)set##Name:(T)v { if (_##name == v) return; _##name = v; [self markDirty]; }
GC_DIRTY_SETTER(CGFloat, left, Left) GC_DIRTY_SETTER(CGFloat, right, Right) GC_DIRTY_SETTER(CGFloat, top, Top) GC_DIRTY_SETTER(CGFloat, bottom, Bottom)
GC_DIRTY_SETTER(CGFloat, width, Width) GC_DIRTY_SETTER(CGFloat, height, Height) GC_DIRTY_SETTER(BOOL, centerX, CenterX) GC_DIRTY_SETTER(BOOL, fitContent, FitContent) GC_DIRTY_SETTER(CGFloat, opacityValue, OpacityValue)
- (NSSize)contentSizeForScale:(CGFloat)s { return NSMakeSize(0, 0); }
- (void)layoutChildrenWithScale:(CGFloat)s {
  const CGFloat W = self.bounds.size.width / s, H = self.bounds.size.height / s;
  const BOOL frameChanged = !NSEqualRects(self.bounds, _laidOutBounds) || s != _laidOutScale;
  _laidOutBounds = self.bounds; _laidOutScale = s;
  for (NSView* v in self.subviews) {
    if (![v isKindOfClass:GCElement.class]) continue;
    GCElement* e = (GCElement*)v;
    if (!frameChanged && !e.needsLayout) continue;
    CGFloat w = e.width, h = e.height;
    if (e.fitContent) {
      NSSize cs = [e contentSizeForScale:s];
      if (!isSet(w) && !(isSet(e.left) && isSet(e.right))) w = cs.width / s;
      if (!isSet(h) && !(isSet(e.top) && isSet(e.bottom))) h = cs.height / s;
    }
    CGFloat x = 0, y = 0;
    if (e.centerX) x = (W - (isSet(w) ? w : 0)) / 2;
    else if (isSet(e.left) && isSet(e.right)) { x = e.left; w = W - e.left - e.right; }
    else if (isSet(e.left)) x = e.left;
    else if (isSet(e.right)) x = W - e.right - (isSet(w) ? w : 0);
    if (isSet(e.top) && isSet(e.bottom)) { y = e.top; h = H - e.top - e.bottom; }
    else if (isSet(e.top)) y = e.top;
    else if (isSet(e.bottom)) y = H - e.bottom - (isSet(h) ? h : 0);
    if (!isSet(w)) w = 0;
    if (!isSet(h)) h = 0;
    if (e.fitContent && [e isKindOfClass:GCLabel.class] && ((GCLabel*)e).wraps && isSet(e.width)) {
      NSSize cs = [e contentSizeForScale:s];
      h = cs.height / s;
    }
    e.frame = NSMakeRect(std::round(x * s), std::round(y * s), std::round(w * s), std::round(h * s));
    e.alphaValue = e.opacityValue;
    [e layoutChildrenWithScale:s];
    [e clearLayoutFlags];
  }
}
@end

// ------------------------------------------------------------------ GCBox
@implementation GCBox
- (void)setFill:(NSColor*)v { if (_fill == v || [_fill isEqual:v]) return; _fill = v; [self markDirty]; }
- (void)setBorder:(NSColor*)v { if (_border == v || [_border isEqual:v]) return; _border = v; [self markDirty]; }
- (void)setBorderWidth:(CGFloat)v { if (_borderWidth == v) return; _borderWidth = v; [self markDirty]; }
- (void)setClips:(BOOL)v { if (_clips == v) return; _clips = v; [self markDirty]; }
- (void)layoutChildrenWithScale:(CGFloat)s {
  self.layer.backgroundColor = self.fill.CGColor;
  self.layer.borderColor = self.border.CGColor;
  self.layer.borderWidth = self.border ? std::max<CGFloat>(1, std::round((self.borderWidth ?: 1) * s)) : 0;
  self.layer.masksToBounds = self.clips;
  [super layoutChildrenWithScale:s];
}
@end

// ------------------------------------------------------------------ GCLabel
// GCLabel rasterises its text itself (CoreText via NSAttributedString into a CGBitmapContext) and hands the
// finished image to its layer. Letting AppKit draw text into layer backing stores stalls the main thread
// for 25-35 ms whenever Core Animation decides to spin up its GPU-accelerated CoreGraphics renderer.
@implementation GCLabel {
  NSString* _cacheKey;
  NSAttributedString* _cached;
  NSSize _cachedSize;
  BOOL _cachedSizeValid;
  CGImageRef _image;
  NSString* _imageKey;
  CGFloat _imageScale;
}
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    _fontSize = 16;
    _weight = 400;
    _color = GCColor(GC_INK);
    _align = NSTextAlignmentLeft;
    self.fitContent = YES;
    self.layer.contentsGravity = kCAGravityResize;
  }
  return self;
}
- (void)dealloc { if (_image) CGImageRelease(_image); }
#define GC_LABEL_SETTER(T, name, Name) - (void)set##Name:(T)v { if (_##name == v) return; _##name = v; [self markDirty]; }
GC_LABEL_SETTER(CGFloat, fontSize, FontSize) GC_LABEL_SETTER(BOOL, display, Display) GC_LABEL_SETTER(CGFloat, weight, Weight) GC_LABEL_SETTER(CGFloat, tracking, Tracking)
GC_LABEL_SETTER(BOOL, uppercase, Uppercase) GC_LABEL_SETTER(NSTextAlignment, align, Align) GC_LABEL_SETTER(CGFloat, lineHeight, LineHeight) GC_LABEL_SETTER(BOOL, wraps, Wraps)
- (void)setColor:(NSColor*)v { if (_color == v || [_color isEqual:v]) return; _color = v; [self markDirty]; }
- (void)setText:(NSString*)text {
  static const bool log = getenv("GC_CLOCKLOG") != nullptr;
  if (log && _text != text && ![_text isEqualToString:text]) fprintf(stderr, "label %.1fpx '%s' -> '%s'\n", self.fontSize, [_text substringToIndex:MIN(24u, (unsigned)_text.length)].UTF8String ?: "", [text substringToIndex:MIN(24u, (unsigned)text.length)].UTF8String ?: "");
  if (_text == text || [_text isEqualToString:text]) return;
  _text = [text copy];
  [self markDirty];
}
- (NSAttributedString*)attributedForScale:(CGFloat)s {
  NSString* key = [NSString stringWithFormat:@"%@|%.4f|%.2f|%.0f|%d|%d|%.3f|%ld|%.2f|%d|%@", self.text ?: @"", s, self.fontSize, self.weight, (int)self.display, (int)self.uppercase, self.tracking, (long)self.align, self.lineHeight, (int)self.wraps, self.color.description];
  if (_cached && [key isEqualToString:_cacheKey]) return _cached;
  _cacheKey = key;
  _cachedSizeValid = NO;
  NSString* t = self.uppercase ? [self.text uppercaseString] : (self.text ?: @"");
  NSFont* font = self.display ? GCDisplayFont(self.fontSize * s, self.weight) : GCBodyFont(self.fontSize * s, self.weight);
  NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
  ps.alignment = self.align;
  ps.lineBreakMode = self.wraps ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
  if (self.lineHeight > 0) { ps.minimumLineHeight = self.lineHeight * s; ps.maximumLineHeight = self.lineHeight * s; }
  NSMutableDictionary* attrs = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: self.color, NSParagraphStyleAttributeName: ps} mutableCopy];
  if (self.tracking != 0) attrs[NSKernAttributeName] = @(self.tracking * self.fontSize * s);
  _cached = [[NSAttributedString alloc] initWithString:t attributes:attrs];
  return _cached;
}
- (NSSize)contentSizeForScale:(CGFloat)s {
  NSAttributedString* a = [self attributedForScale:s];
  if (_cachedSizeValid && a == _cached) return _cachedSize;
  NSSize out;
  if (self.wraps && isSet(self.width)) {
    NSRect r = [a boundingRectWithSize:NSMakeSize(self.width * s, 1e6) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading context:nil];
    out = NSMakeSize(std::ceil(r.size.width), std::ceil(r.size.height) + 2);
  } else {
    NSSize sz = a.size;
    out = NSMakeSize(std::ceil(sz.width) + 8 + std::fabs(self.tracking) * self.fontSize * s, std::ceil(std::max<CGFloat>(sz.height, self.lineHeight * s)));
  }
  _cachedSize = out;
  _cachedSizeValid = YES;
  return out;
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
  self.layer.contents = _image ? (__bridge id)_image : nil;
  if (_image) self.layer.contentsScale = _imageScale;
}
- (void)layoutChildrenWithScale:(CGFloat)s {
  NSAttributedString* a = [self attributedForScale:s];
  const CGFloat bs = self.window.backingScaleFactor ?: 2;
  const NSSize pt = self.bounds.size;
  const size_t w = size_t(std::ceil(pt.width * bs)), h = size_t(std::ceil(pt.height * bs));
  NSString* key = [NSString stringWithFormat:@"%@|%zux%zu|%.2f", _cacheKey, w, h, bs];
  if (_imageKey && [key isEqualToString:_imageKey]) return;
  _imageKey = key;
  if (_image) { CGImageRelease(_image); _image = nullptr; }
  if (w > 0 && h > 0 && a.length > 0) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (ctx) {
      CGContextTranslateCTM(ctx, 0, CGFloat(h));
      CGContextScaleCTM(ctx, bs, -bs);  // flipped, in points
      [NSGraphicsContext saveGraphicsState];
      [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES]];
      const CGFloat inset = 2 * s;  // NSTextField's cell padding, which the layouts were tuned against
      [a drawWithRect:NSMakeRect(inset, 0, std::max<CGFloat>(0, pt.width - 2 * inset), pt.height) options:NSStringDrawingUsesLineFragmentOrigin | (self.wraps ? 0 : NSStringDrawingTruncatesLastVisibleLine) context:nil];
      [NSGraphicsContext restoreGraphicsState];
      _image = CGBitmapContextCreateImage(ctx);
      _imageScale = bs;
      CGContextRelease(ctx);
    }
  }
  [self setNeedsDisplay:YES];
}
@end

// ------------------------------------------------------------------ GCButton
@implementation GCButton {
  NSTrackingArea* _tracking;
}
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) _enabled = YES;
  return self;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow) owner:self userInfo:nil];
  [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent*)e { if (self.onHover && self.enabled) self.onHover(YES); }
- (void)mouseExited:(NSEvent*)e { if (self.onHover && self.enabled) self.onHover(NO); }
- (void)mouseDown:(NSEvent*)e { if (self.onClick && self.enabled) self.onClick(); }
@end

// ------------------------------------------------------------------ GCStageArt
static const char* kArtPaths[] = {
    "M110 0L310 640L0 640Z M650 0L800 640L400 640Z",                                                                                                         // spotlights (fill yellow 5.5%)
    "M365 310C333 310 320 337 329 360L340 384L316 410L291 498L327 512L358 452L380 487L357 555L334 686H375L411 573L431 554L483 679H526L495 541L467 466L450 398L408 381L401 348C408 322 390 310 365 310Z",  // guitarist
    "M304 472L466 504L635 344L653 361L490 532L348 562L293 536L282 508Z",                                                                                     // guitar
    "M0 690L800 665V820H0Z",                                                                                                                                  // stage floor
    "M0 733L170 750L260 729L390 772L510 736L645 751L800 720V820H0Z",                                                                                          // crowd
};

static NSBezierPath* parseSvgPath(const char* d) {
  NSBezierPath* p = [NSBezierPath bezierPath];
  const char* s = d;
  char cmd = 0;
  CGPoint cur = {0, 0};
  auto skip = [&]() { while (*s == ' ' || *s == ',') s++; };
  auto num = [&]() -> CGFloat { skip(); char* end; double v = strtod(s, &end); s = end; return v; };
  while (*s) {
    skip();
    if (!*s) break;
    if (isalpha((unsigned char)*s)) cmd = *s++;
    switch (cmd) {
      case 'M': { cur = CGPointMake(num(), num()); [p moveToPoint:cur]; cmd = 'L'; break; }
      case 'L': { cur = CGPointMake(num(), num()); [p lineToPoint:cur]; break; }
      case 'H': { cur.x = num(); [p lineToPoint:cur]; break; }
      case 'V': { cur.y = num(); [p lineToPoint:cur]; break; }
      case 'C': { CGPoint c1 = CGPointMake(num(), num()), c2 = CGPointMake(num(), num()); cur = CGPointMake(num(), num()); [p curveToPoint:cur controlPoint1:c1 controlPoint2:c2]; break; }
      case 'Z': case 'z': { [p closePath]; cmd = 0; break; }
      default: s++; break;
    }
  }
  return p;
}

@implementation GCStageArt
- (instancetype)initWithFrame:(NSRect)f { if ((self = [super initWithFrame:f])) _artOpacity = 1; return self; }
- (void)drawRect:(NSRect)dirty {
  NSRect b = self.bounds;
  const CGFloat s = b.size.height / 820.0;  // art is authored at 800x820
  // radial gradient background
  NSGradient* g = [[NSGradient alloc] initWithColors:@[GCColor(0x3B3A2C), GCColor(0x1A1A17), GCColor(0x0F0F0F)] atLocations:(const CGFloat[]){0, 0.32, 0.72} colorSpace:NSColorSpace.sRGBColorSpace];
  [g drawInRect:b relativeCenterPosition:NSMakePoint(0.2, -0.36)];
  NSAffineTransform* t = [NSAffineTransform transform];
  [t translateXBy:b.size.width - 800 * s yBy:0];
  [t scaleBy:s];
  [NSGraphicsContext saveGraphicsState];
  [t concat];
  NSBezierPath* spots = parseSvgPath(kArtPaths[0]);
  [GCColor(GC_YELLOW, 0.055 * _artOpacity) setFill]; [spots fill];
  // truss
  NSBezierPath* truss = [NSBezierPath bezierPath];
  truss.lineWidth = 3;
  [truss moveToPoint:NSMakePoint(0, 135)]; [truss lineToPoint:NSMakePoint(800, 135)];
  [truss moveToPoint:NSMakePoint(0, 155)]; [truss lineToPoint:NSMakePoint(800, 155)];
  for (int x = 20; x < 800; x += 40) { [truss moveToPoint:NSMakePoint(x, 135)]; [truss lineToPoint:NSMakePoint(x + 20, 155)]; [truss lineToPoint:NSMakePoint(x + 40, 135)]; }
  [GCColor(0x454537, _artOpacity) setStroke]; [truss stroke];
  [GCColor(0x070707, _artOpacity) setFill]; [parseSvgPath(kArtPaths[1]) fill];
  NSBezierPath* guitar = parseSvgPath(kArtPaths[2]);
  [GCColor(0x11110E, _artOpacity) setFill]; [guitar fill];
  guitar.lineWidth = 2; [GCColor(0x55513B, _artOpacity) setStroke]; [guitar stroke];
  [GCColor(0x050505, _artOpacity) setFill]; [parseSvgPath(kArtPaths[3]) fill];
  [GCColor(0x141411, _artOpacity) setFill]; [parseSvgPath(kArtPaths[4]) fill];
  NSBezierPath* hands = [NSBezierPath bezierPath];
  hands.lineWidth = 10;
  const CGFloat hx[] = {65, 80, 285, 300, 590, 608}, hy0[] = {791, 790, 789, 790, 790, 790}, hy1[] = {765, 749, 756, 731, 750, 767};
  for (int i = 0; i < 6; i++) { [hands moveToPoint:NSMakePoint(hx[i], hy0[i])]; [hands lineToPoint:NSMakePoint(hx[i], hy1[i])]; }
  [GCColor(0x25251C, _artOpacity) setStroke]; [hands stroke];
  [NSGraphicsContext restoreGraphicsState];
}
@end

// ------------------------------------------------------------------ GCStage
@implementation GCStage
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) { self.wantsLayer = YES; _scale = 1; _stageSize = NSMakeSize(1440, 900); _childDirty = YES; }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)clear { for (NSView* v in [self.subviews copy]) [v removeFromSuperview]; }
- (void)noteChildDirty { _childDirty = YES; }
- (void)relayout {
  const NSSize sz = self.bounds.size;
  _scale = std::min(sz.width / 1440.0, sz.height / 900.0);
  if (_scale <= 0) _scale = 1;
  _stageSize = NSMakeSize(std::ceil(sz.width / _scale), std::ceil(sz.height / _scale));
  const BOOL force = !NSEqualSizes(sz, _laidOutSize);
  _laidOutSize = sz;
  if (!force && !_childDirty) return;
  _childDirty = NO;
  // lay out children like a GCElement whose bounds are the whole stage
  const CGFloat s = _scale, W = _stageSize.width, H = _stageSize.height;
  for (NSView* v in self.subviews) {
    if (![v isKindOfClass:GCElement.class]) continue;
    GCElement* e = (GCElement*)v;
    if (!force && !e.needsLayout) continue;
    CGFloat w = e.width, h = e.height;
    if (e.fitContent) {
      NSSize cs = [e contentSizeForScale:s];
      if (!isSet(w) && !(isSet(e.left) && isSet(e.right))) w = cs.width / s;
      if (!isSet(h) && !(isSet(e.top) && isSet(e.bottom))) h = cs.height / s;
    }
    CGFloat x = 0, y = 0;
    if (e.centerX) x = (W - (isSet(w) ? w : 0)) / 2;
    else if (isSet(e.left) && isSet(e.right)) { x = e.left; w = W - e.left - e.right; }
    else if (isSet(e.left)) x = e.left;
    else if (isSet(e.right)) x = W - e.right - (isSet(w) ? w : 0);
    if (isSet(e.top) && isSet(e.bottom)) { y = e.top; h = H - e.top - e.bottom; }
    else if (isSet(e.top)) y = e.top;
    else if (isSet(e.bottom)) y = H - e.bottom - (isSet(h) ? h : 0);
    if (!isSet(w)) w = 0;
    if (!isSet(h)) h = 0;
    if (e.fitContent && [e isKindOfClass:GCLabel.class] && ((GCLabel*)e).wraps && isSet(e.width)) h = [e contentSizeForScale:s].height / s;
    e.frame = NSMakeRect(std::round(x * s), std::round(y * s), std::round(w * s), std::round(h * s));
    e.alphaValue = e.opacityValue;
    [e layoutChildrenWithScale:s];
    [e clearLayoutFlags];
  }
}
- (void)didAddSubview:(NSView*)v { [super didAddSubview:v]; _childDirty = YES; }
- (void)willRemoveSubview:(NSView*)v { [super willRemoveSubview:v]; _childDirty = YES; }
- (void)setFrameSize:(NSSize)newSize { [super setFrameSize:newSize]; [self relayout]; }
@end

// ------------------------------------------------------------------ builders
GCLabel* GCMakeLabel(NSString* text, CGFloat size, BOOL display, CGFloat weight, uint32_t color) {
  GCLabel* l = [[GCLabel alloc] initWithFrame:NSZeroRect];
  l.text = text; l.fontSize = size; l.display = display; l.weight = weight; l.color = GCColor(color);
  if (display) l.uppercase = YES;
  return l;
}
GCLabel* GCCrumb(NSString* text, uint32_t color) { GCLabel* l = GCMakeLabel(text, 14, NO, 400, color); l.tracking = 0.15; l.uppercase = YES; return l; }
GCLabel* GCSmallLabel(NSString* text, uint32_t color) { GCLabel* l = GCMakeLabel(text, 13, NO, 400, color); l.tracking = 0.15; l.uppercase = YES; return l; }
GCBox* GCRule(void) { GCBox* b = [[GCBox alloc] initWithFrame:NSZeroRect]; b.fill = GCColor(GC_RULE); b.height = 1; return b; }

GCButton* GCSlab(NSString* label, NSString* kbd, void (^onClick)(void)) {
  GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect];
  b.fill = GCColor(GC_YELLOW);
  b.height = 64;
  b.onClick = onClick;
  GCLabel* l = GCMakeLabel(label, 30, YES, 800, GC_BG);
  l.left = 32; l.top = 14;
  [b addSubview:l];
  if (kbd) { GCLabel* k = GCMakeLabel(kbd, 16, NO, 400, GC_BG); k.right = 32; k.top = 22; [b addSubview:k]; }
  return b;
}
GCButton* GCGhost(NSString* label, void (^onClick)(void), CGFloat fontSize) {
  GCButton* b = [[GCButton alloc] initWithFrame:NSZeroRect];
  b.border = GCColor(GC_BORDER);
  b.onClick = onClick;
  GCLabel* l = GCMakeLabel(label, fontSize, NO, 400, GC_INK);
  l.fitContent = YES;
  l.left = 24; l.top = 16;
  [b addSubview:l];
  b.fitContent = NO;
  b.height = fontSize + 36;
  b.width = 200;
  b.onHover = ^(BOOL in) { b.layer.borderColor = GCColor(in ? GC_INK : GC_BORDER).CGColor; };
  return b;
}

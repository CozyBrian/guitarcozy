// Scaled 1440x900 "stage" UI layer built from AppKit views.
// Elements use design-unit coordinates with CSS-like anchors; GCStage computes a
// uniform scale (min(w/1440, h/900)) and lays everything out in real points.
#pragma once
#import <Cocoa/Cocoa.h>

extern const CGFloat GCUnset;  // NAN marker for "anchor not set"

// Design palette
NSColor* GCColor(uint32_t hex, CGFloat alpha = 1.0);
enum { GC_BG = 0x090909, GC_PANEL = 0x191919, GC_CELL = 0x292929, GC_RULE = 0x383838, GC_BORDER = 0x535353, GC_MUTED = 0xA8A8A8, GC_INK = 0xF5F5F0, GC_YELLOW = 0xFFD335, GC_ON_YELLOW_MUTED = 0x29230D, GC_GREEN = 0x59BD65, GC_RED = 0xE25853, GC_BLUE = 0x548ED8, GC_ORANGE = 0xF29A47 };

void GCRegisterFonts(NSString* fontsDir);
NSFont* GCDisplayFont(CGFloat size, CGFloat weight);  // Barlow Condensed
NSFont* GCBodyFont(CGFloat size, CGFloat weight);     // system font

@interface GCElement : NSView
@property(nonatomic) CGFloat left, right, top, bottom, width, height;  // design units, GCUnset when unused
@property(nonatomic) BOOL centerX;  // centre horizontally in the parent using the fit-content/explicit width (keeps text layers small)
@property(nonatomic) BOOL fitContent;
@property(nonatomic) CGFloat opacityValue;
- (void)layoutChildrenWithScale:(CGFloat)s;
- (NSSize)contentSizeForScale:(CGFloat)s;  // for fitContent elements
- (void)markDirty;          // anchors / content changed: relayout this element and let ancestors know
- (BOOL)needsLayout;        // dirty or has a dirty descendant
- (void)clearLayoutFlags;
@end

@interface GCBox : GCElement
@property(nonatomic, strong) NSColor* fill;
@property(nonatomic, strong) NSColor* border;
@property(nonatomic) CGFloat borderWidth;
@property(nonatomic) BOOL clips;
@end

@interface GCLabel : GCElement
@property(nonatomic, copy) NSString* text;
@property(nonatomic) CGFloat fontSize;      // design units
@property(nonatomic) BOOL display;          // Barlow Condensed vs body
@property(nonatomic) CGFloat weight;        // 400..900
@property(nonatomic, strong) NSColor* color;
@property(nonatomic) CGFloat tracking;      // em
@property(nonatomic) BOOL uppercase;
@property(nonatomic) NSTextAlignment align;
@property(nonatomic) CGFloat lineHeight;    // design units, 0 = natural
@property(nonatomic) BOOL wraps;
@end

@interface GCButton : GCBox
@property(nonatomic, copy) void (^onClick)(void);
@property(nonatomic, copy) void (^onHover)(BOOL inside);
@property(nonatomic) BOOL enabled;
@end

// Rasterises the stage-art SVG paths (spotlights, truss, guitarist, crowd).
@interface GCStageArt : GCElement
@property(nonatomic) CGFloat artOpacity;
@end

@interface GCStage : NSView {
  @private
  BOOL _childDirty;
  NSSize _laidOutSize;
}
@property(nonatomic, readonly) CGFloat scale;
@property(nonatomic, readonly) NSSize stageSize;  // design units (>= 1440x900)
- (void)relayout;
- (void)clear;
- (void)noteChildDirty;
@end

// ---- convenience builders (Objective-C++)
GCLabel* GCMakeLabel(NSString* text, CGFloat size, BOOL display, CGFloat weight, uint32_t color);
GCLabel* GCCrumb(NSString* text, uint32_t color = GC_MUTED);           // 14px tracked uppercase
GCLabel* GCSmallLabel(NSString* text, uint32_t color = GC_MUTED);      // 13px tracked uppercase
GCBox* GCRule(void);                                                    // 1px rule
GCButton* GCSlab(NSString* label, NSString* kbd, void (^onClick)(void));       // yellow slab
GCButton* GCGhost(NSString* label, void (^onClick)(void), CGFloat fontSize = 16); // outlined button
NSString* GCUpper(NSString* s);

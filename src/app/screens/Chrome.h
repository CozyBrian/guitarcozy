// Shared screen chrome: header crumb, footer hints, numbered menu list.
#pragma once
#import "ui/Stage.h"
#include <vector>

GCElement* GCHeader(NSView* stage, NSString* crumb, GCElement* right, BOOL withLogo);
GCElement* GCFooter(NSView* stage, NSArray<NSArray<NSString*>*>* hints);  // @[@[key,label,dot?]]
NSArray<NSArray<NSString*>*>* GCDefaultHints(void);

@interface GCMenuList : NSObject
@property(nonatomic, strong) GCElement* view;
@property(nonatomic, readonly) NSInteger selected;
@property(nonatomic, copy) void (^onMove)(void);
- (instancetype)initWithItems:(NSArray<NSString*>*)labels dim:(NSArray<NSNumber*>*)dim numbered:(BOOL)numbered width:(CGFloat)width actions:(NSArray<void (^)(void)>*)actions;
- (void)select:(NSInteger)i;
- (BOOL)handle:(NSString*)action;
- (void)relayout;
@end

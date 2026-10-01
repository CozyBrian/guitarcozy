#pragma once
#import "app/App.h"
@interface OptionsScreen : NSObject <GCScreen>
@property(nonatomic, copy) void (^onClose)(void);   // overlay mode: called on Back
@property(nonatomic, copy) void (^onChange)(void);  // called after any setting changes
- (instancetype)initWithTab:(NSString*)tab;  // gameplay | calibration | controls | audio | video
- (instancetype)initWithTab:(NSString*)tab overlay:(BOOL)overlay;  // overlay: renders over the paused highway
@end

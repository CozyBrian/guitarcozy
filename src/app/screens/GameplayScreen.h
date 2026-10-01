#pragma once
#import "app/App.h"
#import <Metal/Metal.h>

// Gameplay: engine + mixer + Metal renderer + HUD (stage labels) + pause overlay.
@interface GameplayScreen : NSObject <GCScreen>
- (instancetype)initWithSongId:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty mode:(NSString*)mode;
- (void)setPracticeStart:(double)start end:(double)end speed:(double)speed loop:(BOOL)loop;
- (void)setSpeed:(double)speed;  // quickplay / career song speed (records only save at 1.0)
- (void)setReplayPath:(NSString*)path;  // play back a recorded input stream instead of live input
- (void)renderFrame:(MTKView*)view;
- (void)drawableSizeChanged:(CGSize)size;
- (id<MTLTexture>)lastFrameTexture;
@end

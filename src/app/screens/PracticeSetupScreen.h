#pragma once
#import "app/App.h"
@interface PracticeSetupScreen : NSObject <GCScreen>
- (instancetype)initWithSongId:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty;
@end

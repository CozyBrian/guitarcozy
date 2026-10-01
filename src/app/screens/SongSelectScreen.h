#pragma once
#import "app/App.h"
#include "core/types.h"
@interface SongSelectScreen : NSObject <GCScreen>
- (instancetype)initWithMode:(NSString*)mode;  // quickplay | practice
@property(nonatomic) gc::Instrument instrument;
@property(nonatomic) gc::Difficulty difficulty;
@property(nonatomic) BOOL moreInstruments;
@end

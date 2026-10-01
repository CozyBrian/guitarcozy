#pragma once
#import "app/App.h"
@interface ResultsScreen : NSObject <GCScreen>
- (instancetype)initWithResult:(NSDictionary*)result;
@end

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
@interface IFEngine : NSObject
+ (BOOL)startWithShared:(NSString *)shared user:(NSString *)user error:(NSError **)error;
+ (void)stop;
- (BOOL)key:(int)key modifiers:(int)modifiers;
- (BOOL)event:(NSEvent *)event;
// A changed count takes effect when the session is no longer composing.
- (void)setCandidateCount:(NSInteger)count;
@property (readonly) NSInteger candidateCount;
- (void)select:(NSUInteger)index;
- (void)commit;
- (void)clear;
- (NSString *)takeCommit;
- (NSDictionary *)snapshot;
@end

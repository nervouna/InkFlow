#import <AppKit/AppKit.h>
extern NSNotificationName const IFSettingsDidChangeNotification;
@interface IFSettings : NSObject
+ (instancetype)sharedSettings;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property NSInteger candidateCount;
@property NSInteger fontSize;
@property BOOL vertical;
@end
@interface IFSettingsWindowController : NSWindowController
+ (instancetype)sharedController;
- (void)present;
@end

#import <InputMethodKit/InputMethodKit.h>
#import "Engine.h"
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSBundle *bundle=NSBundle.mainBundle;
    NSString *shared=[bundle.resourcePath stringByAppendingPathComponent:@"Rime"];
    NSString *user=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/InkFlow"];
    NSError *error=nil;
    if (![IFEngine startWithShared:shared user:user error:&error]) {
        NSLog(@"InkFlow initialization failed: %@",error.localizedDescription); return 1;
    }
    __attribute__((objc_precise_lifetime)) IMKServer *server=[[IMKServer alloc] initWithName:[bundle objectForInfoDictionaryKey:@"InputMethodConnectionName"] bundleIdentifier:bundle.bundleIdentifier];
    if (!server) { NSLog(@"InkFlow could not create its input method server."); [IFEngine stop]; return 1; }
    [NSApp run];
    (void)server;
    [IFEngine stop];
} return 0; }

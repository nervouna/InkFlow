#import <InputMethodKit/InputMethodKit.h>
#import "Engine.h"
#import "IsolatedSettings.h"

@interface InkFlowInputController : IMKInputController
@end

#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL initialization line %d: %s\n",__LINE__,#c); return 1; } } while(0)

int main(int argc, const char **argv) { @autoreleasepool {
    isolateSettings(); CHECK(argc==3);
    [NSApplication sharedApplication];
    NSError *error=nil;
    CHECK([IFEngine startWithShared:@(argv[1]) user:@(argv[2]) error:&error]);
    NSString *name=[@"io.damao.inkflow.initialization-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    IMKServer *server=[[IMKServer alloc] initWithName:name bundleIdentifier:name];
    CHECK(server);
    __weak InkFlowInputController *releasedController;
    @autoreleasepool {
        // Exercise the production initializer and real candidate panel, without a client or stubs.
        InkFlowInputController *controller;
        @autoreleasepool {
            controller=[[InkFlowInputController alloc] initWithServer:server delegate:nil client:nil];
        }
        CHECK(controller);
        releasedController=controller;
        IMKCandidates *panel=[controller valueForKey:@"panel"];
        CHECK(panel);
        TISInputSourceRef layout=[panel selectionKeysKeylayout];
        CHECK(layout);
        CHECK(CFEqual(TISGetInputSourceProperty(layout,kTISPropertyInputSourceID),CFSTR("com.apple.keylayout.US")));
        CHECK([[panel selectionKeys] isEqual:(@[@18,@19,@20,@21,@23])]);
        // Reuse the borrowed layout after initialization, as the native panel does when drawing.
        [panel setSelectionKeys:@[@18,@19,@20,@21,@23]];
        [panel setCandidateData:@[@"啊",@"阿",@"吖",@"呵",@"腌"]];
        [panel hide];
        panel=nil;
        controller=nil;
    }
    CHECK(!releasedController);
    [IFEngine stop]; cleanupSettings();
    puts("PASS initialization: real controller, selection-key configuration, layout reuse and teardown");
} return 0; }

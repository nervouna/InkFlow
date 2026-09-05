#import <InputMethodKit/InputMethodKit.h>
#import <objc/runtime.h>
#import "Engine.h"
#import "IsolatedSettings.h"
@interface InkFlowInputController : IMKInputController
- (void)refresh:(id<IMKTextInput>)client;
@end
@interface RecordingClient : NSObject
@property NSMutableArray<NSString *> *mutations;
@end
@implementation RecordingClient
- (instancetype)init { if ((self=[super init])) _mutations=[NSMutableArray array]; return self; }
- (void)insertText:(id)text replacementRange:(NSRange)range {
    (void)range; [_mutations addObject:[@"insert:" stringByAppendingString:text]];
}
- (void)setMarkedText:(id)text selectionRange:(NSRange)selection replacementRange:(NSRange)range {
    (void)range; (void)selection; [_mutations addObject:[@"mark:" stringByAppendingString:text]];
}
@end
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL controller line %d: %s\n",__LINE__,#c); return 1; } } while(0)
static NSEvent *key(unsigned short code, NSString *text, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}
static void ignoreServerDeactivation(id object, SEL selector, id sender) { (void)object; (void)selector; (void)sender; }
int main(int argc, const char **argv) { @autoreleasepool {
    isolateSettings(); CHECK(argc==3); NSError *error=nil;
    CHECK([IFEngine startWithShared:@(argv[1]) user:@(argv[2]) error:&error]);
    // Stub only the framework server teardown, which requires a GUI server.
    method_setImplementation(class_getInstanceMethod(IMKInputController.class,@selector(deactivateServer:)),(IMP)ignoreServerDeactivation);
    // Bypass the server/window initializer for a headless test of the real controller.
    // The nil panel receives harmless no-op messages; the engine and client are real/recording.
    InkFlowInputController *controller=class_createInstance(InkFlowInputController.class,0);
    [controller setValue:[IFEngine new] forKey:@"engine"];
    RecordingClient *client=[RecordingClient new];
    CHECK(![controller handleEvent:key(123,@"",0) client:client]);
    CHECK(client.mutations.count==0);
    CHECK(![controller handleEvent:key(0,@"a",NSEventModifierFlagCommand) client:client]);
    CHECK(client.mutations.count==0);
    CHECK([controller handleEvent:key(49,@" ",NSEventModifierFlagControl|NSEventModifierFlagShift) client:client]);
    CHECK(client.mutations.count==0);
    CHECK(![controller handleEvent:key(0,@"a",0) client:client]);
    [controller commitComposition:client]; [controller deactivateServer:client];
    CHECK(client.mutations.count==0);
    CHECK([controller handleEvent:key(49,@" ",NSEventModifierFlagControl|NSEventModifierFlagShift) client:client]);
    CHECK([controller handleEvent:key(45,@"n",0) client:client]);
    CHECK([client.mutations isEqual:@[@"mark:n"]]);
    CHECK([controller handleEvent:key(53,@"",0) client:client]);
    CHECK([client.mutations isEqual:(@[@"mark:n",@"mark:"])]);
    [controller commitComposition:client]; [controller deactivateServer:client];
    CHECK(client.mutations.count==2);
    [client.mutations removeAllObjects];
    for (NSString *letter in @[@"n",@"i",@"h",@"a",@"o"]) [controller handleEvent:key(0,letter,0) client:client];
    [client.mutations removeAllObjects];
    CHECK([controller handleEvent:key(49,@" ",0) client:client]);
    CHECK([client.mutations isEqual:@[@"insert:你好"]]);
    [controller commitComposition:client]; [controller deactivateServer:client];
    CHECK([client.mutations isEqual:@[@"insert:你好"]]);
    controller=nil; [IFEngine stop]; cleanupSettings();
    puts("PASS controller: idle client unchanged, Escape clears owned mark once, commit inserts once without empty replacement");
} return 0; }

// Explicit diagnostic only. Private framework inspection is never linked into InkFlow.
#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL keepAlive = argc == 2 && strcmp(argv[1], "--keep-alive") == 0;
        BOOL trigger = argc == 2 && strcmp(argv[1], "--trigger") == 0;
        if (argc > 2 || (argc == 2 && !keepAlive && !trigger)) return 64;
        [NSApplication sharedApplication];
        NSString *name = [@"io.damao.inkflow.lifetime-probe." stringByAppendingString:NSUUID.UUID.UUIDString];
        IMKServer *server = [[IMKServer alloc] initWithName:name bundleIdentifier:name];
        Ivar ivar = class_getInstanceVariable(server.class, "_private");
        id storage = ivar ? object_getIvar(server, ivar) : nil;
        SEL getter = NSSelectorFromString(@"_candidates");
        SEL deactivate = NSSelectorFromString(@"deactivateServer_CommonWithClientWrapper:controller:");
        if (!storage || ![storage respondsToSelector:getter] || ![server respondsToSelector:deactivate]) {
            fprintf(stderr, "UNSUPPORTED: native legacy candidate inspection unavailable\n");
            return 2;
        }
        // Read pointer identity without retaining or messaging the possibly freed object.
        void *(*getCandidates)(id, SEL) = (void *(*)(id, SEL))[storage methodForSelector:getter];
        __weak IMKCandidates *releasedPanel;
        __attribute__((objc_precise_lifetime)) IMKCandidates *retainedPanel = nil;
        uintptr_t identity = 0;
        @autoreleasepool {
            IMKCandidates *panel = [[IMKCandidates alloc] initWithServer:server panelType:kIMKSingleRowSteppingCandidatePanel];
            if (!panel) return 2;
            releasedPanel = panel;
            identity = (uintptr_t)(__bridge void *)panel;
            if (keepAlive) retainedPanel = panel;
            printf("server=%s storage=%s registered=%d\n", object_getClassName(server), object_getClassName(storage),
                   (uintptr_t)getCandidates(storage, getter) == identity);
            [panel hide];
        }
        BOOL released = releasedPanel == nil;
        BOOL referenced = (uintptr_t)getCandidates(storage, getter) == identity;
        printf("panel_released=%d server_still_references_panel=%d\n", released, referenced);
        fflush(stdout);
        if (trigger || keepAlive) {
            printf("calling_native_deactivation\n");
            fflush(stdout);
            ((void (*)(id, SEL, id, id))[server methodForSelector:deactivate])(server, deactivate, nil, nil);
            printf("native_deactivation_returned\n");
        }
        // Exit zero means the requested experiment matched, not that the product is fixed.
        return referenced && (keepAlive ? !released : released) ? 0 : 3;
    }
}

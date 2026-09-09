#import <AppKit/AppKit.h>
#import <InputMethodKit/InputMethodKit.h>

// Public-API-only feasibility probe. Does not register or install an input source.
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        IMKServer *server = [[IMKServer alloc] initWithName:[@"inkflow.native-panel-probe." stringByAppendingString:NSUUID.UUID.UUIDString]
                                        bundleIdentifier:NSBundle.mainBundle.bundleIdentifier];
        IMKCandidates *ordinary = [[IMKCandidates alloc] initWithServer:server panelType:kIMKSingleRowSteppingCandidatePanel];
        IMKCandidates *ai = [[IMKCandidates alloc] initWithServer:server panelType:kIMKSingleRowSteppingCandidatePanel];
        [ordinary setCandidateData:@[@"普通候选", @"第二候选"]];
        [ai setCandidateData:@[@"AI 其实我平常也不是打这种长句的  Tab 采纳"]];
        [ordinary setCandidateFrameTopLeft:NSMakePoint(200, 500)];
        [ai setCandidateFrameTopLeft:NSMakePoint(200, 430)];
        [ordinary showCandidates]; [ai showCandidates];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        NSLog(@"PROBE ordinary visible=%d frame=%@ firstID=%ld ai visible=%d frame=%@ firstID=%ld visibleWindows=%lu",
              ordinary.isVisible, NSStringFromRect(ordinary.candidateFrame), (long)[ordinary candidateIdentifierAtLineNumber:0],
              ai.isVisible, NSStringFromRect(ai.candidateFrame), (long)[ai candidateIdentifierAtLineNumber:0],
              (unsigned long)[[NSApp.windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSWindow *window, NSDictionary *bindings) { return window.isVisible; }]] count]);
        [ordinary setCandidateFrameTopLeft:NSMakePoint(200, 500)];
        [ai setCandidateFrameTopLeft:NSMakePoint(200, 430)];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        NSLog(@"POST-SHOW ordinary=%@ ai=%@", NSStringFromRect(ordinary.candidateFrame), NSStringFromRect(ai.candidateFrame));
        NSArray<NSWindow *> *windows = [NSApp.windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSWindow *window, NSDictionary *bindings) { return window.isVisible; }]];
        for (NSWindow *window in windows) NSLog(@"WINDOW number=%ld frame=%@ key=%d", (long)window.windowNumber, NSStringFromRect(window.frame), window.isKeyWindow);
        BOOL visible = ordinary.isVisible && ai.isVisible;
        BOOL separated = windows.count == 2 && !NSIntersectsRect(windows[0].frame, windows[1].frame);
        [ai hide];
        BOOL independent = ordinary.isVisible && !ai.isVisible;
        [ordinary hide];
        printf("RESULT visible=%d separated=%d independentHide=%d\n", visible, separated, independent);
        printf("LIMIT keyboard/click routing, rendered content and live input-method acceptance are not established by this standalone probe.\n");
        return visible && separated && independent ? 0 : 1;
    }
}

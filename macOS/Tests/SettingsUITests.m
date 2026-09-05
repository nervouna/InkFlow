#import <InputMethodKit/InputMethodKit.h>
#import "Engine.h"
#import "IsolatedSettings.h"
@interface InkFlowInputController : IMKInputController
@end
// Simulate an OS without the private selector while retaining the public API.
@interface PublicFontOnlyCandidates : IMKCandidates
@property NSUInteger privateFontCalls;
@end
@implementation PublicFontOnlyCandidates
- (BOOL)respondsToSelector:(SEL)selector {
 return selector==NSSelectorFromString(@"setFontSize:") ? NO : [super respondsToSelector:selector];
}
- (void)setFontSize:(double)size { (void)size; self.privateFontCalls++; }
@end
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL settings UI line %d: %s\n",__LINE__,#c); return 1; } } while(0)
static BOOL checkCandidateFont(IMKCandidates *panel, IFEngine *engine, NSDictionary *composition, NSInteger size, BOOL vertical, const char *phase) {
 // Test-only inspection: the public attributes getter does not prove rendering.
 NSFont *font=nil;
 @try {
  Ivar field=class_getInstanceVariable(panel.class,"_private");
  id implementation=field ? object_getIvar(panel,field) : nil;
  id layout=[implementation valueForKeyPath:@"candidateWindowController.itemLayout"];
  font=[layout valueForKey:@"titleAttributes"][NSFontAttributeName];
 } @catch (NSException *exception) {
  fprintf(stderr,"FAIL native font inspection: %s\n",exception.reason.UTF8String);
 }
 BOOL preserved=[[engine snapshot] isEqual:composition] && ![engine takeCommit].length;
 BOOL keys=[panel.selectionKeys isEqual:(@[@18,@19,@20,@21,@23])];
 BOOL matches=[font isKindOfClass:NSFont.class] && font.pointSize==size;
 BOOL configured=panel.panelType==(vertical ? kIMKSingleColumnScrollingCandidatePanel : kIMKSingleRowSteppingCandidatePanel)
  && [(NSFont *)panel.attributes[NSFontAttributeName] pointSize]==size;
 BOOL passed=matches && configured && preserved && keys;
 printf("%s native font: %s %s requested=%ld itemLayout.title=%g composition=%s digitKeys=%s\n",passed ? "PASS" : "FAIL",phase,vertical ? "vertical" : "horizontal",(long)size,font.pointSize,preserved ? "preserved" : "CHANGED",keys ? "preserved" : "CHANGED");
 fflush(stdout);
 return passed;
}
int main(int argc, const char **argv) { @autoreleasepool {
 CHECK(argc>=3); isolateSettings(); [NSApplication sharedApplication]; [NSApp finishLaunching];
 NSError *error=nil; CHECK([IFEngine startWithShared:@(argv[1]) user:@(argv[2]) error:&error]);
 NSString *name=[@"inkflow.settings-ui." stringByAppendingString:NSUUID.UUID.UUIDString];
 IMKServer *server=[[IMKServer alloc] initWithName:name bundleIdentifier:name]; CHECK(server);
 InkFlowInputController *controller=[[InkFlowInputController alloc] initWithServer:server delegate:nil client:nil]; CHECK(controller);
 NSMenuItem *item=controller.menu.itemArray.firstObject; CHECK(item.action==@selector(showPreferences:));
 [controller doCommandBySelector:item.action commandDictionary:@{kIMKCommandMenuItemName:item}];
 NSWindow *window=IFSettingsWindowController.sharedController.window;
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1];
 while (deadline.timeIntervalSinceNow>0) { NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES]; if (event) [NSApp sendEvent:event]; }
 CHECK(window.visible); CHECK(window.keyWindow); CHECK(NSApp.active);
 CHECK(window.styleMask & NSWindowStyleMaskResizable);
 CHECK(window.styleMask & NSWindowStyleMaskFullSizeContentView);
 CHECK([window.contentViewController isKindOfClass:NSSplitViewController.class]);
 NSSplitViewController *split=(NSSplitViewController *)window.contentViewController;
 CHECK(split.splitViewItems.count==2);
 NSRect initialFrame=window.frame;
 for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(700,380)],[NSValue valueWithSize:NSMakeSize(700,560)]]) {
  [window setContentSize:size.sizeValue];
  [window.contentView layoutSubtreeIfNeeded];
  NSView *sidebar=split.splitViewItems[0].viewController.view;
  NSRect sidebarFrame=[sidebar convertRect:sidebar.bounds toView:nil];
  CHECK(NSMaxY(sidebarFrame)>NSMaxY(window.contentLayoutRect)+1);
  NSButton *closeButton=[window standardWindowButton:NSWindowCloseButton];
  NSRect closeFrame=[closeButton convertRect:closeButton.bounds toView:nil];
  CHECK(NSContainsRect(sidebarFrame,closeFrame));
  NSView *form=split.splitViewItems[1].viewController.view.subviews.firstObject;
  CHECK(form && NSWidth(form.bounds)>0 && NSHeight(form.bounds)>0);
  CHECK(NSContainsRect(window.contentLayoutRect,[form convertRect:form.bounds toView:nil]));
 }
 [window setFrame:initialFrame display:YES];
 puts("PASS settings layout: full-height sidebar behind traffic lights, form within content layout at minimum and enlarged sizes");
 [window close];
 [controller doCommandBySelector:item.action commandDictionary:@{kIMKCommandMenuItemName:item}];
 CHECK(IFSettingsWindowController.sharedController.window==window && window.visible && window.keyWindow);
 IMKCandidates *panel=[controller valueForKey:@"panel"];
 IFEngine *engine=[controller valueForKey:@"engine"];
 for (const char *key="shi";*key;key++) [engine key:*key modifiers:0];
 NSDictionary *before=[engine snapshot];
 CHECK([before[@"preedit"] length] && [before[@"candidates"] count]==5);
 [panel setCandidateData:before[@"candidates"]];
 NSUInteger fontFailures=0;
 for (NSNumber *vertical in @[@NO,@YES]) {
  testSettings.vertical=vertical.boolValue;
  for (NSNumber *size in @[@14,@36,@14,@16,@18,@24,@36]) {
   testSettings.fontSize=size.integerValue;
   fontFailures+=!checkCandidateFont(panel,engine,before,size.integerValue,vertical.boolValue,"resize");
  }
 }
 for (NSNumber *size in @[@36,@14]) {
  testSettings.fontSize=size.integerValue;
  for (NSNumber *vertical in @[@NO,@YES,@NO]) {
   testSettings.vertical=vertical.boolValue;
   fontFailures+=!checkCandidateFont(panel,engine,before,size.integerValue,vertical.boolValue,"direction switch");
  }
 }
 PublicFontOnlyCandidates *publicPanel=[[PublicFontOnlyCandidates alloc] initWithServer:server panelType:kIMKSingleRowSteppingCandidatePanel];
 CHECK(publicPanel); publicPanel.privateFontCalls=0;
 [controller setValue:publicPanel forKey:@"panel"];
 testSettings.fontSize=36;
 CHECK(publicPanel.privateFontCalls==0);
 CHECK([(NSFont *)publicPanel.attributes[NSFontAttributeName] pointSize]==36);
 CHECK([[engine snapshot] isEqual:before] && ![engine takeCommit].length);
 [controller setValue:panel forKey:@"panel"]; [publicPanel hide];
 puts("PASS private selector unavailable: documented attributes applied, private setter skipped, composition preserved");
 testSettings.vertical=YES; testSettings.fontSize=36; testSettings.candidateCount=9;
 CHECK([[engine snapshot] isEqual:before]); CHECK(panel.panelType==kIMKSingleColumnScrollingCandidatePanel);
 CHECK(panel.selectionKeys.count==5);
 CHECK([(NSFont *)[panel attributes][NSFontAttributeName] pointSize]==36);
 [engine clear]; [engine key:'s' modifiers:0]; [engine key:'h' modifiers:0]; [engine key:'i' modifiers:0];
 // Reapply settings through the notification path to synchronize effective digit keys.
 testSettings.vertical=NO;
 CHECK(panel.panelType==kIMKSingleRowSteppingCandidatePanel);
 CHECK([panel.selectionKeys isEqual:(@[@18,@19,@20,@21,@23,@22,@26,@28,@25])]);
 CHECK([[engine snapshot][@"candidates"] count]==9);
 [panel setCandidateData:[engine snapshot][@"candidates"]]; [panel hide];
 [engine clear]; testSettings.candidateCount=5; testSettings.fontSize=14;
 if (fontFailures) {
  [window close]; controller=nil; [IFEngine stop]; cleanupSettings();
  fprintf(stderr,"FAIL native candidate font: %lu layout checks failed\n",(unsigned long)fontFailures); return 1;
 }
 puts("PASS settings UI: actual IMK dictionary dispatch, singleton reopen/focus, native direction/font/digit keys, composition preserved, deferred count"); fflush(stdout);
 if (argc>3 && strcmp(argv[3],"--hold")==0) { puts("HOLD: isolated settings window ready for CUA; close process to finish"); fflush(stdout); [NSApp run]; }
 [window close]; controller=nil; [IFEngine stop]; cleanupSettings();
} return 0; }

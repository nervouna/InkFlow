#import <InputMethodKit/InputMethodKit.h>
#import "Engine.h"
#import "Settings.h"
@interface IMKCandidates (InkFlowFontCompatibility)
- (void)setFontSize:(double)size;
@end
// Optional private layout accessors observed on macOS 26.6.2.
@protocol IFNativeCandidateLayout <NSObject>
- (id<IFNativeCandidateLayout>)candidateWindowController;
- (id<IFNativeCandidateLayout>)layoutTraits;
- (void)setLineDefaultLength:(double)length;
@end
@interface IMKCandidates (InkFlowWidthCompatibility)
- (void)if_applyMinimumVerticalWidth;
@end
@implementation IMKCandidates (InkFlowWidthCompatibility)
- (void)if_applyMinimumVerticalWidth {
    if (self.panelType!=kIMKSingleColumnScrollingCandidatePanel) return;
    // The SDK exposes this protected implementation reference. Avoid KVC or raw offsets.
    id<IFNativeCandidateLayout> implementation=(id)_private;
    if (![implementation respondsToSelector:@selector(candidateWindowController)]) return;
    id<IFNativeCandidateLayout> controller=[implementation candidateWindowController];
    if (![controller respondsToSelector:@selector(layoutTraits)]) return;
    id<IFNativeCandidateLayout> traits=[controller layoutTraits];
    if ([traits respondsToSelector:@selector(setLineDefaultLength:)]) [traits setLineDefaultLength:150.0];
}
@end
@interface InkFlowInputController : IMKInputController
@end
@implementation InkFlowInputController {
    IFEngine *_engine;
    IMKCandidates *_panel;
    TISInputSourceRef _selectionLayout;
    NSArray<NSString *> *_strings;
    BOOL _updating;
    BOOL _ownsMarkedText;
}
- (id)initWithServer:(IMKServer *)server delegate:(id)delegate client:(id)client {
    if ((self=[super initWithServer:server delegate:delegate client:client])) {
        _engine=[IFEngine new];
        _panel=[[IMKCandidates alloc] initWithServer:server panelType:kIMKSingleRowSteppingCandidatePanel];
        // An explicit layout lets the native panel render labels for these key codes.
        CFArrayRef layouts=TISCreateInputSourceList((__bridge CFDictionaryRef)@{(__bridge NSString *)kTISPropertyInputSourceID:@"com.apple.keylayout.US"},true);
        if (layouts) {
            if (CFArrayGetCount(layouts)) {
                // IMKCandidates borrows this source; retain it until after panel teardown.
                _selectionLayout=(TISInputSourceRef)CFRetain(CFArrayGetValueAtIndex(layouts,0));
                [_panel setSelectionKeysKeylayout:_selectionLayout];
            }
            CFRelease(layouts);
        }
        [_panel setDismissesAutomatically:NO];
        [self applySettings];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:) name:IFSettingsDidChangeNotification object:IFSettings.sharedSettings];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _panel=nil;
    if (_selectionLayout) CFRelease(_selectionLayout);
}
- (NSMenu *)menu {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"InkFlow"];
    [menu addItemWithTitle:@"打开设置" action:@selector(showPreferences:) keyEquivalent:@""].target=self;
    return menu;
}
- (void)showPreferences:(id)sender {
    // IMK dispatches an action dictionary, not an NSMenuItem.
    (void)sender; [IFSettingsWindowController.sharedController present];
}
- (void)applySettings {
    IFSettings *settings=IFSettings.sharedSettings;
    [_engine setCandidateCount:settings.candidateCount];
    BOOL updating=_updating; _updating=YES;
    [_panel setPanelType:settings.vertical ? kIMKSingleColumnScrollingCandidatePanel : kIMKSingleRowSteppingCandidatePanel];
    NSArray *keys=@[@18,@19,@20,@21,@23,@22,@26,@28,@25];
    [_panel setSelectionKeys:[keys subarrayWithRange:NSMakeRange(0,_engine.candidateCount ?: 5)]];
    [_panel setAttributes:@{IMKCandidatesSendServerKeyEventFirst:@YES,NSFontAttributeName:[NSFont systemFontOfSize:settings.fontSize]}];
    // macOS 26.6.2 stores public font attributes without updating the native layout.
    // Use the optional private setter with its double ABI; retain the public path above.
    if ([_panel respondsToSelector:@selector(setFontSize:)]) [_panel setFontSize:(double)settings.fontSize];
    // Font/direction changes rebuild the layout traits, so apply the width afterward.
    [_panel if_applyMinimumVerticalWidth];
    _updating=updating;
}
- (void)settingsChanged:(NSNotification *)notification {
    (void)notification; [self applySettings];
    if ([[ _engine snapshot][@"preedit"] length] && self.client) [self refresh:self.client];
}
- (void)refresh:(id<IMKTextInput>)client {
    NSString *commit=[_engine takeCommit];
    if (commit.length) {
        // Inserting a commit consumes our marked range. Do not then replace the
        // client's resulting selection with an empty marked string.
        _ownsMarkedText=NO;
        [client insertText:commit replacementRange:NSMakeRange(NSNotFound,0)];
    }

    NSDictionary *state=[_engine snapshot];
    NSString *preedit=state[@"preedit"] ?: @"";
    if (preedit.length) {
        _ownsMarkedText=YES;
        [client setMarkedText:preedit selectionRange:NSMakeRange([state[@"cursor"] unsignedIntegerValue],0) replacementRange:NSMakeRange(NSNotFound,0)];
    } else if (_ownsMarkedText) {
        _ownsMarkedText=NO;
        [client setMarkedText:@"" selectionRange:NSMakeRange(0,0) replacementRange:NSMakeRange(NSNotFound,0)];
    }

    _strings=state[@"candidates"] ?: @[];
    _updating=YES;
    [self applySettings];
    [_panel updateCandidates];
    if (_strings.count) {
        NSUInteger index=MIN([state[@"highlight"] unsignedIntegerValue],_strings.count-1);
        [_panel selectCandidateWithIdentifier:[_panel candidateStringIdentifier:_strings[index]]];
        [_panel show:kIMKLocateCandidatesBelowHint];
    } else [_panel hide];
    _updating=NO;
}
- (BOOL)handleEvent:(NSEvent *)event client:(id)client {
    if (!_engine || event.type!=NSEventTypeKeyDown) return NO;
    BOOL handled=[_engine event:event];
    if (!handled && [[_engine snapshot][@"preedit"] length]) [_engine commit];
    [self refresh:client];
    return handled;
}
- (NSArray *)candidates:(id)sender { (void)sender; return _strings ?: @[]; }
- (void)candidateSelected:(NSAttributedString *)candidate {
    if (_updating) return;
    NSUInteger index=[_strings indexOfObject:candidate.string];
    if (index!=NSNotFound) { [_engine select:index]; [self refresh:self.client]; }
}
- (void)commitComposition:(id)sender {
    [_engine commit]; [self refresh:sender ?: self.client]; [_panel hide];
}
- (void)deactivateServer:(id)sender {
    [self commitComposition:sender]; [super deactivateServer:sender];
}
@end

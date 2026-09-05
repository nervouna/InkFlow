#import <InputMethodKit/InputMethodKit.h>
#import "Engine.h"
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
        [_panel setSelectionKeys:@[@18,@19,@20,@21,@23]];
        [_panel setDismissesAutomatically:NO];
        [_panel setAttributes:@{IMKCandidatesSendServerKeyEventFirst:@YES}];
    }
    return self;
}
- (void)dealloc {
    _panel=nil;
    if (_selectionLayout) CFRelease(_selectionLayout);
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

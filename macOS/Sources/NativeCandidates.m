#import "NativeCandidates.h"

@interface IMKCandidates (InkFlowFontCompatibility)
- (void)setFontSize:(double)size;
@end

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
    // The SDK's protected reference is unavailable to Swift. Avoid KVC/raw offsets.
    id<IFNativeCandidateLayout> implementation=(id)_private;
    if (![implementation respondsToSelector:@selector(candidateWindowController)]) return;
    id<IFNativeCandidateLayout> controller=[implementation candidateWindowController];
    if (![controller respondsToSelector:@selector(layoutTraits)]) return;
    id<IFNativeCandidateLayout> traits=[controller layoutTraits];
    if ([traits respondsToSelector:@selector(setLineDefaultLength:)]) [traits setLineDefaultLength:150.0];
}
@end

void IFApplyCandidateFont(IMKCandidates *panel, double size) {
    if ([panel respondsToSelector:@selector(setFontSize:)]) [panel setFontSize:size];
}

void IFApplyMinimumVerticalWidth(IMKCandidates *panel) {
    [panel if_applyMinimumVerticalWidth];
}

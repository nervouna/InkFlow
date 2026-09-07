#import <InputMethodKit/InputMethodKit.h>

NS_ASSUME_NONNULL_BEGIN
void IFStubHeadlessControllerFramework(void);
NSFont * _Nullable IFNativeCandidateFont(IMKCandidates *panel);
NSArray<NSDictionary<NSString *, id> *> *IFAccessibilityTree(id root);
BOOL IFPressAccessibility(id root, NSString *identifier);
BOOL IFPressAccessibilityDisclosure(id root, NSString *label);
@interface PublicFontOnlyCandidates : IMKCandidates
@property NSUInteger privateFontCalls;
@end
NS_ASSUME_NONNULL_END

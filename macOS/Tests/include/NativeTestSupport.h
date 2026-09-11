#import <InputMethodKit/InputMethodKit.h>

NS_ASSUME_NONNULL_BEGIN
void IFStubHeadlessControllerFramework(void);
BOOL IFSendMouseDown(IMKInputController *controller, NSUInteger index, id<IMKTextInput> client, BOOL *keepTracking);
NSFont * _Nullable IFNativeCandidateFont(IMKCandidates *panel);
NSArray<NSDictionary<NSString *, id> *> *IFAccessibilityTree(id root);
BOOL IFPressAccessibility(id root, NSString *identifier);
BOOL IFPressAccessibilityDisclosure(id root, NSString *label);
NSDictionary * _Nullable IFSerializedInputSourceMenu(IMKServer *server, IMKInputController *controller);
@interface PublicFontOnlyCandidates : IMKCandidates
@property NSUInteger privateFontCalls;
@end
NS_ASSUME_NONNULL_END

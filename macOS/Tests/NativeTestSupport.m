#import "NativeTestSupport.h"
#import <objc/runtime.h>

// Intercept only framework initialization/teardown and the supplied test client lookup. The Swift subclass's real initializer
// still initializes every stored property. Never class_createInstance a Swift class.
static char testClientKey;
static id initializeWithoutServer(id object, SEL selector, id server, id delegate, id client) {
    (void)selector; (void)server; (void)delegate;
    IMP initialize=class_getMethodImplementation(NSObject.class,@selector(init));
    id initialized=((id (*)(id,SEL))initialize)(object,@selector(init));
    objc_setAssociatedObject(initialized,&testClientKey,client,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return initialized;
}
static id suppliedTestClient(id object, SEL selector) { (void)selector; return objc_getAssociatedObject(object,&testClientKey); }
static void ignoreServerDeactivation(id object, SEL selector, id sender) {
    (void)object; (void)selector; (void)sender;
}
void IFStubHeadlessControllerFramework(void) {
    method_setImplementation(class_getInstanceMethod(IMKInputController.class,@selector(initWithServer:delegate:client:)),(IMP)initializeWithoutServer);
    method_setImplementation(class_getInstanceMethod(IMKInputController.class,@selector(deactivateServer:)),(IMP)ignoreServerDeactivation);
    method_setImplementation(class_getInstanceMethod(IMKInputController.class,@selector(client)),(IMP)suppliedTestClient);
}

NSFont *IFNativeCandidateFont(IMKCandidates *panel) {
    // Test-only private inspection requires Objective-C exception handling.
    @try {
        Ivar field=class_getInstanceVariable(panel.class,"_private");
        id implementation=field ? object_getIvar(panel,field) : nil;
        id layout=[implementation valueForKeyPath:@"candidateWindowController.itemLayout"];
        id font=[layout valueForKey:@"titleAttributes"][NSFontAttributeName];
        return [font isKindOfClass:NSFont.class] ? font : nil;
    } @catch (NSException *exception) {
        fprintf(stderr,"FAIL native font inspection: %s\n",exception.reason.UTF8String);
        return nil;
    }
}

@implementation PublicFontOnlyCandidates
- (BOOL)respondsToSelector:(SEL)selector {
    return selector==NSSelectorFromString(@"setFontSize:") ? NO : [super respondsToSelector:selector];
}
- (void)setFontSize:(double)size { (void)size; self.privateFontCalls++; }
@end

static void collectAccessibility(id object, NSMutableArray *result, NSHashTable *visited) {
    // SwiftUI accessibility objects expose these public selectors without necessarily
    // declaring NSAccessibility protocol conformance. Do not discard those children.
    if ([visited containsObject:object]) return;
    [visited addObject:object];
    id<NSAccessibility> element=object;
    NSMutableDictionary *entry=[NSMutableDictionary dictionary];
    if ([object respondsToSelector:@selector(accessibilityRole)]) entry[@"role"]=element.accessibilityRole ?: @"";
    if ([object respondsToSelector:@selector(accessibilityIdentifier)]) entry[@"id"]=element.accessibilityIdentifier ?: @"";
    if ([object respondsToSelector:@selector(accessibilityLabel)]) entry[@"label"]=element.accessibilityLabel ?: @"";
    if ([object respondsToSelector:@selector(accessibilityValue)]) entry[@"value"]=element.accessibilityValue ?: @"";
    if ([object respondsToSelector:@selector(isAccessibilityEnabled)]) entry[@"enabled"]=@(element.isAccessibilityEnabled);
    if ([object respondsToSelector:@selector(accessibilityFrame)]) entry[@"frame"]=[NSValue valueWithRect:element.accessibilityFrame];
    [result addObject:entry];
    if ([object respondsToSelector:@selector(accessibilityChildren)]) {
        for (id child in element.accessibilityChildren) collectAccessibility(child,result,visited);
    }
}

NSArray<NSDictionary<NSString *, id> *> *IFAccessibilityTree(id root) {
    NSMutableArray *result=[NSMutableArray array];
    collectAccessibility(root,result,[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
    return result;
}

#import "include/NativeTestSupport.h"
#import <objc/runtime.h>

// Test-only inspection of the actual dictionary sent to the input-source menu host.
// This private diagnostic must fail explicitly if a future OS removes it.
@interface IMKServer (MenuSerializationInspection)
- (NSDictionary *)menusDictionary_CommonWithController:(IMKInputController *)controller;
@end

NSDictionary *IFSerializedInputSourceMenu(IMKServer *server, IMKInputController *controller) {
    if (![server respondsToSelector:@selector(menusDictionary_CommonWithController:)]) return nil;
    return [server menusDictionary_CommonWithController:controller];
}

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

BOOL IFSendMouseDown(IMKInputController *controller, NSUInteger index, id<IMKTextInput> client, BOOL *keepTracking) {
    return [controller mouseDownOnCharacterIndex:index coordinate:NSZeroPoint withModifier:0
                                continueTracking:keepTracking client:client];
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

static id findAccessibility(id object, BOOL (^matches)(id), NSHashTable *visited) {
    if ([visited containsObject:object]) return nil;
    [visited addObject:object];
    id<NSAccessibility> element=object;
    if (matches(object)) return object;
    if ([object respondsToSelector:@selector(accessibilityChildren)]) {
        for (id child in element.accessibilityChildren) {
            id found=findAccessibility(child,matches,visited);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL pressAccessibility(id object) {
    return [object respondsToSelector:@selector(accessibilityPerformPress)] &&
        [(id<NSAccessibility>)object accessibilityPerformPress];
}

BOOL IFPressAccessibility(id root, NSString *identifier) {
    id element=findAccessibility(root,^BOOL(id object) {
        return [object respondsToSelector:@selector(accessibilityIdentifier)] &&
            [[(id<NSAccessibility>)object accessibilityIdentifier] isEqualToString:identifier];
    },[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
    return pressAccessibility(element);
}

BOOL IFPressAccessibilityDisclosure(id root, NSString *label) {
    id element=findAccessibility(root,^BOOL(id object) {
        return [object respondsToSelector:@selector(accessibilityRole)] &&
            [[(id<NSAccessibility>)object accessibilityRole] isEqualToString:NSAccessibilityDisclosureTriangleRole] &&
            [object respondsToSelector:@selector(accessibilityLabel)] &&
            [[(id<NSAccessibility>)object accessibilityLabel] isEqualToString:label];
    },[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
    return pressAccessibility(element);
}

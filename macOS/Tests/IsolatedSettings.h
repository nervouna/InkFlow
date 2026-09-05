#import "Settings.h"
#import <objc/runtime.h>
static IFSettings *testSettings;
static NSString *testSuite;
static NSUserDefaults *testDefaults;
static id isolatedSettings(id object, SEL selector) { (void)object; (void)selector; return testSettings; }
static void isolateSettings(void) {
 testSuite=[@"inkflow.test." stringByAppendingString:NSUUID.UUID.UUIDString];
 testDefaults=[[NSUserDefaults alloc] initWithSuiteName:testSuite];
 testSettings=[[IFSettings alloc] initWithDefaults:testDefaults];
 method_setImplementation(class_getClassMethod(IFSettings.class,@selector(sharedSettings)),(IMP)isolatedSettings);
}
static void cleanupSettings(void) { [testDefaults removePersistentDomainForName:testSuite]; }

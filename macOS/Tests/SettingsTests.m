#import "Settings.h"
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL settings line %d: %s\n",__LINE__,#c); return 1; } } while(0)
int main(void) { @autoreleasepool {
 NSString *suite=[@"inkflow.settings-test." stringByAppendingString:NSUUID.UUID.UUIDString];
 NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];
 IFSettings *s=[[IFSettings alloc] initWithDefaults:defaults];
 CHECK(s.candidateCount==5 && !s.vertical && s.fontSize==14);
 for (id bad in @[@2,@10,@3.5,@"9",@[],@YES]) {
  [defaults setObject:bad forKey:@"candidateCount"]; CHECK(s.candidateCount==5);
 }
 for (id bad in @[@15,@0,@"18",@[]]) { [defaults setObject:bad forKey:@"fontSize"]; CHECK(s.fontSize==14); }
 [defaults setObject:@"yes" forKey:@"vertical"]; CHECK(!s.vertical);
 s.candidateCount=9; s.fontSize=36; s.vertical=YES;
 IFSettings *reload=[[IFSettings alloc] initWithDefaults:defaults];
 CHECK(reload.candidateCount==9 && reload.fontSize==36 && reload.vertical);
 for (NSNumber *count in @[@3,@4,@5,@6,@7,@8,@9]) { s.candidateCount=count.integerValue; CHECK(s.candidateCount==count.integerValue); }
 for (NSNumber *size in @[@14,@16,@18,@24,@36]) { s.fontSize=size.integerValue; CHECK(s.fontSize==size.integerValue); }
 s.candidateCount=1; s.fontSize=15; CHECK(s.candidateCount==5 && s.fontSize==14);
 [defaults removePersistentDomainForName:suite];
 puts("PASS settings: defaults, malformed values, bounds, persistence");
} return 0; }

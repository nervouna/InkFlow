#import "Engine.h"
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); return 1; } } while(0)
static NSEvent *event(unsigned short code, NSString *chars) {
 return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}
static void type
(IFEngine *e, NSString *s) { for (NSUInteger i=0;i<s.length;i++) [e key:[s characterAtIndex:i] modifiers:0]; }
int main(int argc, const char **argv) { @autoreleasepool {
 CHECK(argc==3); NSError *error=nil;
 CHECK(![IFEngine startWithShared:@"/nonexistent/inkflow" user:@(argv[2]) error:&error]); CHECK(error!=nil); error=nil;
 CHECK([IFEngine startWithShared:@(argv[1]) user:@(argv[2]) error:&error]);
 IFEngine *a=[IFEngine new], *b=[IFEngine new]; CHECK(a && b);
 type(a,@"nihao"); CHECK([[a snapshot][@"candidates"] containsObject:@"你好"]);
 CHECK([[b snapshot][@"preedit"] length]==0);
 [a select:0]; CHECK([[a takeCommit] isEqual:@"你好"]);
 type(a,@"zhongguo"); CHECK([[a snapshot][@"candidates"] containsObject:@"中国"]);
 [a key:0xff1b modifiers:0]; CHECK([[a snapshot][@"preedit"] length]==0);
 type(a,@"ni"); [a key:0xff08 modifiers:0]; CHECK([[a snapshot][@"preedit"] isEqual:@"n"]);
 [a clear]; type(a,@"ni"); CHECK([a event:event(51,@"\b")]); CHECK([[a snapshot][@"preedit"] isEqual:@"n"]); CHECK([a event:event(53,@"\e")]); CHECK([[a snapshot][@"preedit"] length]==0);
 [a clear]; type(a,@"shi"); NSArray *first=[a snapshot][@"candidates"];
 CHECK(first.count==5);
 [a event:event(121,@"")]; CHECK([[a snapshot][@"page"] intValue]==1);
 NSArray *second=[a snapshot][@"candidates"]; CHECK(second.count==5);
 CHECK(![second isEqual:first]);
 [a event:event(116,@"")]; CHECK([[a snapshot][@"page"] intValue]==0);
 CHECK([[a snapshot][@"candidates"] isEqual:first]);
 [a event:event(19,@"2")]; CHECK([[a takeCommit] isEqual:first[1]]);
 type(a,@"shi"); [a event:event(121,@"")];
 second=[a snapshot][@"candidates"]; CHECK(second.count==5);
 [a event:event(23,@"5")]; CHECK([[a takeCommit] isEqual:second[4]]);
 type(a,@"nihao"); [a key:' ' modifiers:0]; CHECK([[a takeCommit] isEqual:@"你好"]);
 NSEvent *toggle=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagControl|NSEventModifierFlagShift timestamp:0 windowNumber:0 context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
 CHECK([a event:toggle]); CHECK(![a key:'a' modifiers:0]);
 CHECK([a event:toggle]); type(a,@"nihao"); [a commit]; CHECK([[a takeCommit] isEqual:@"你好"]);
 NSEvent *cmd=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
 CHECK(![a event:cmd]);
 a=nil;b=nil; [IFEngine stop]; puts("PASS engine: Chinese, sessions, edit, cancel, paging, number/space selection, English toggle, shortcut passthrough");
 } return 0; }

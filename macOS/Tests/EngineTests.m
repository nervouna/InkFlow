#import "Engine.h"
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); return 1; } } while(0)
static NSEvent *modifiedEvent(unsigned short code, NSString *chars, NSEventModifierFlags flags) {
 return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}
static NSEvent *event(unsigned short code, NSString *chars) {
 return modifiedEvent(code,chars,0);
}
static void type
(IFEngine *e, NSString *s) { for (NSUInteger i=0;i<s.length;i++) [e key:[s characterAtIndex:i] modifiers:0]; }
static int testPunctuation(void) {
 // Input, exact committed text, ANSI key code, Shift. Include the existing mappings.
 NSArray<NSArray *> *cases=@[
  @[@"{",@"「",@33,@YES], @[@"}",@"」",@30,@YES],
  @[@"[",@"【",@33,@NO], @[@"]",@"】",@30,@NO],
  @[@"<",@"《",@43,@YES], @[@">",@"》",@47,@YES],
  @[@"\\",@"、",@42,@NO], @[@"|",@"｜",@42,@YES],
  @[@"`",@"·",@50,@NO], @[@"~",@"～",@50,@YES],
  @[@"$",@"\u00a5",@21,@YES], @[@"^",@"\u2026\u2026",@22,@YES],
  @[@"_",@"\u2014\u2014",@27,@YES],
  @[@",",@"，",@43,@NO], @[@".",@"。",@47,@NO],
  @[@";",@"；",@41,@NO], @[@":",@"：",@41,@YES],
  @[@"!",@"！",@18,@YES], @[@"?",@"？",@44,@YES],
  @[@"(",@"（",@25,@YES], @[@")",@"）",@29,@YES]
 ];
 NSEvent *toggle=modifiedEvent(49,@" ",NSEventModifierFlagControl|NSEventModifierFlagShift);
 for (NSArray *row in cases) {
  IFEngine *engine=[IFEngine new]; CHECK(engine);
  NSEventModifierFlags flags=[row[3] boolValue] ? NSEventModifierFlagShift : 0;
  NSEvent *key=modifiedEvent([row[2] unsignedShortValue],row[0],flags);
  CHECK([engine event:key]);
  CHECK([[engine takeCommit] isEqual:row[1]]);
  CHECK([[engine snapshot][@"preedit"] length]==0);
  CHECK([engine event:toggle]);
  CHECK(![engine event:key]);
  CHECK([[engine takeCommit] length]==0);
 }
 // Single and double quotes alternate independently, including interleaved input.
 for (NSArray *row in @[@[@"\"\"\"\"",@"“”“”"], @[@"''''",@"‘’‘’"], @[@"\"'\"'",@"“‘”’"]]) {
  IFEngine *engine=[IFEngine new];
  NSString *input=row[0], *expected=row[1];
  for (NSUInteger i=0;i<input.length;i++) {
   NSString *quote=[input substringWithRange:NSMakeRange(i,1)];
   CHECK([engine event:modifiedEvent(39,quote,[quote isEqual:@"\""] ? NSEventModifierFlagShift : 0)]);
   CHECK([[engine takeCommit] isEqual:[expected substringWithRange:NSMakeRange(i,1)]]);
   CHECK([[engine snapshot][@"preedit"] length]==0);
  }
  CHECK([engine event:toggle]);
  CHECK(![engine event:modifiedEvent(39,@"\"",NSEventModifierFlagShift)]);
  CHECK(![engine event:event(39,@"'")]);
  CHECK([[engine takeCommit] length]==0);
 }
 IFEngine *engine=[IFEngine new];
 type(engine,@"xi'an "); CHECK([[engine takeCommit] isEqual:@"西安"]);
 // A quote can surround committed Chinese without treating its delimiter as punctuation.
 CHECK([engine event:modifiedEvent(39,@"\"",NSEventModifierFlagShift)]);
 CHECK([[engine takeCommit] isEqual:@"“"]);
 type(engine,@"xi'an "); CHECK([[engine takeCommit] isEqual:@"西安"]);
 CHECK([engine event:modifiedEvent(39,@"\"",NSEventModifierFlagShift)]);
 CHECK([[engine takeCommit] isEqual:@"”"]);
 // Candidate paging retains priority over bracket punctuation.
 type(engine,@"shi"); NSArray *first=[engine snapshot][@"candidates"];
 CHECK([engine event:event(30,@"]")]); CHECK([[engine snapshot][@"page"] intValue]==1);
 CHECK([[engine takeCommit] length]==0);
 CHECK([engine event:event(33,@"[")]);
 CHECK([[engine snapshot][@"candidates"] isEqual:first]);
 CHECK([[engine takeCommit] length]==0); [engine clear];
 CHECK([engine event:event(33,@"[")]); CHECK([[engine takeCommit] isEqual:@"【"]);
 // These symbols remain ASCII in Chinese mode when no composition is active.
 for (NSString *text in @[@"@",@"#",@"%",@"&",@"*",@"-",@"=",@"+",@"/"]) {
  CHECK(![engine event:event(0,text)]); CHECK([[engine takeCommit] length]==0);
 }
 for (NSNumber *modifier in @[@(NSEventModifierFlagCommand),@(NSEventModifierFlagControl),@(NSEventModifierFlagOption)]) {
  CHECK(![engine event:modifiedEvent(22,@"^",modifier.unsignedIntegerValue|NSEventModifierFlagShift)]);
  CHECK([[engine takeCommit] length]==0);
 }
 // Include unhandled digits as the client would, rather than counting only Rime commits.
 for (NSString *input in @[@"3.14",@"10:30"]) {
  IFEngine *numbers=[IFEngine new]; NSMutableString *document=[NSMutableString string];
  for (NSUInteger i=0;i<input.length;i++) {
   NSString *character=[input substringWithRange:NSMakeRange(i,1)];
   BOOL handled=[numbers key:[character characterAtIndex:0] modifiers:0];
   [document appendString:[numbers takeCommit]];
   if (!handled) [document appendString:character];
  }
  CHECK([document isEqual:input]); CHECK([[numbers snapshot][@"preedit"] length]==0);
 }
 puts("PASS punctuation: exact mappings, Shift, independent quotes, apostrophe delimiter, bracket paging, ASCII/shortcut passthrough, decimal/time input");
 return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
 CHECK(argc==3); NSError *error=nil;
 CHECK(![IFEngine startWithShared:@"/nonexistent/inkflow" user:@(argv[2]) error:&error]); CHECK(error!=nil); error=nil;
 CHECK([IFEngine startWithShared:@(argv[1]) user:@(argv[2]) error:&error]);
 NSString *schemaPath=[@(argv[2]) stringByAppendingPathComponent:@"build/inkflow_pinyin.schema.yaml"];
 NSData *schemaBefore=[NSData dataWithContentsOfFile:schemaPath]; CHECK(schemaBefore);
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
 [a clear]; type(a,@"shi"); NSDictionary *before=[a snapshot];
 [a setCandidateCount:9]; CHECK([[a snapshot] isEqual:before]);
 CHECK([[a takeCommit] length]==0);
 [a clear]; type(a,@"shi"); CHECK([[a snapshot][@"candidates"] count]==9);
 [a event:event(121,@"")]; NSArray *nine=[a snapshot][@"candidates"]; CHECK(nine.count==9);
 [a event:event(25,@"9")]; CHECK([[a takeCommit] isEqual:nine[8]]);
 IFEngine *fresh=[IFEngine new]; type(fresh,@"shi"); CHECK([[fresh snapshot][@"candidates"] count]==5);
 [fresh clear]; [fresh setCandidateCount:9]; type(fresh,@"shi"); CHECK([[fresh snapshot][@"candidates"] count]==9); fresh=nil;
 [b clear]; type(b,@"shi"); CHECK([[b snapshot][@"candidates"] count]==5);
 [a setCandidateCount:3]; type(a,@"shi"); CHECK([[a snapshot][@"candidates"] count]==3);
 CHECK(testPunctuation()==0);
 a=nil;b=nil; [IFEngine stop]; CHECK([[NSData dataWithContentsOfFile:schemaPath] isEqual:schemaBefore]); puts("PASS engine: Chinese, sessions, edit, cancel, paging, number/space selection, English toggle, shortcut passthrough, deferred 3/9 paging, digit 9, existing/new session isolation");
 } return 0; }

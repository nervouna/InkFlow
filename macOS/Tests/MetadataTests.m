#import <Foundation/Foundation.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL metadata line %d: %s\n",__LINE__,#c); return 1; } } while(0)
int main(int argc, const char **argv) { @autoreleasepool {
    CHECK(argc==2);
    NSBundle *bundle=[NSBundle bundleWithPath:@(argv[1])]; CHECK(bundle!=nil);
    NSString *modeID=@"io.damao.inputmethod.inkflow.Hans";
    NSDictionary *group=bundle.infoDictionary[@"ComponentInputModeDict"];
    NSDictionary *modes=group[@"tsInputModeListKey"];
    CHECK(modes.count==1); NSDictionary *mode=modes[modeID]; CHECK(mode!=nil);
    CHECK([group[@"tsVisibleInputModeOrderedArrayKey"] isEqual:@[modeID]]);
    CHECK([mode[@"TISInputSourceID"] isEqual:modeID]);
    CHECK([mode[@"TISIntendedLanguage"] isEqual:@"zh-Hans"]);
    CHECK([mode[@"tsInputModeIsVisibleKey"] boolValue]);
    CHECK([mode[@"tsInputModeDefaultStateKey"] boolValue]);
    CHECK([mode[@"tsInputModePrimaryInScriptKey"] boolValue]);
    CHECK([mode[@"tsInputModeScriptKey"] isEqual:@"smUnicodeScript"]);
    for (NSString *key in @[@"tsInputModeMenuIconFileKey",@"tsInputModeAlternateMenuIconFileKey",@"tsInputModePaletteIconFileKey"]) {
        NSString *file=mode[key]; CHECK(file.length>0);
        CHECK([[NSFileManager defaultManager] isReadableFileAtPath:[bundle.resourcePath stringByAppendingPathComponent:file]]);
    }
    for (NSString *language in @[@"en",@"zh-Hans"]) {
        NSString *path=[bundle.resourcePath stringByAppendingPathComponent:[language stringByAppendingString:@".lproj/InfoPlist.strings"]];
        NSDictionary *names=[NSDictionary dictionaryWithContentsOfFile:path];
        CHECK([names[modeID] hasPrefix:@"InkFlow"]);
        CHECK([names[@"CFBundleDisplayName"] isEqual:@"InkFlow"]);
    }
    puts("PASS metadata: one named visible/default Chinese mode with packaged icons and localizations");
} return 0; }

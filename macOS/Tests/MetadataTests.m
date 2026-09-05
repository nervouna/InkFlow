#import <AppKit/AppKit.h>
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
    CHECK([bundle.infoDictionary[@"TISIconIsTemplate"] boolValue]);
    CHECK([mode[@"TISIconIsTemplate"] boolValue]);
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
        NSString *productName=[language isEqual:@"zh-Hans"] ? @"墨流拼音" : @"InkFlow";
        NSString *modeName=[language isEqual:@"zh-Hans"] ? @"墨流拼音" : @"InkFlow Pinyin";
        CHECK([names[modeID] isEqual:modeName]);
        CHECK([names[@"CFBundleName"] isEqual:productName]);
        CHECK([names[@"CFBundleDisplayName"] isEqual:productName]);
    }
    CHECK([mode[@"tsInputModeMenuIconFileKey"] isEqual:@"MenuIconTemplate.tiff"]);
    CHECK([mode[@"tsInputModeAlternateMenuIconFileKey"] isEqual:mode[@"tsInputModeMenuIconFileKey"]]);
    NSImage *menuIcon=[bundle imageForResource:@"MenuIconTemplate"];
    CHECK(menuIcon!=nil && menuIcon.isTemplate);
    CHECK(NSEqualSizes(menuIcon.size,NSMakeSize(22,16)));
    CHECK(menuIcon.representations.count==2);
    NSMutableSet *widths=[NSMutableSet set];
    for (NSBitmapImageRep *rep in menuIcon.representations) {
        CHECK([rep isKindOfClass:NSBitmapImageRep.class] && rep.hasAlpha);
        CHECK(rep.pixelsHigh*22==rep.pixelsWide*16);
        CHECK(NSEqualSizes(rep.size,NSMakeSize(22,16)));
        [widths addObject:@(rep.pixelsWide)];
        CHECK([rep colorAtX:0 y:0].alphaComponent<0.1);
        NSUInteger clearInterior=0,solidInterior=0;
        for (NSInteger y=rep.pixelsHigh/4;y<rep.pixelsHigh*3/4;y++) {
            for (NSInteger x=rep.pixelsWide/3;x<rep.pixelsWide*2/3;x++) {
                CGFloat alpha=[rep colorAtX:x y:y].alphaComponent;
                if (alpha<0.5) clearInterior++;
                else solidInterior++;
            }
        }
        CHECK(clearInterior>0 && solidInterior>0);
    }
    CHECK(([widths isEqual:[NSSet setWithArray:@[@22,@44]]]));
    puts("PASS metadata: one named visible/default Chinese mode with packaged icons and localizations");
} return 0; }

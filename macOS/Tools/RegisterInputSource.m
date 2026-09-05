#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
static id property(TISInputSourceRef source, CFStringRef key) {
    return (__bridge id)TISGetInputSourceProperty(source,key);
}
static CFArrayRef copySource(NSString *sourceID) {
    NSDictionary *filter=@{(__bridge NSString *)kTISPropertyBundleID:@"io.damao.inputmethod.inkflow",
                          (__bridge NSString *)kTISPropertyInputSourceID:sourceID};
    return TISCreateInputSourceList((__bridge CFDictionaryRef)filter,true);
}
static BOOL enabled(NSString *identifier) {
    CFArrayRef sources=copySource(identifier);
    BOOL result=sources && CFArrayGetCount(sources)==1 && [property((TISInputSourceRef)CFArrayGetValueAtIndex(sources,0),kTISPropertyInputSourceIsEnabled) boolValue];
    if (sources) CFRelease(sources);
    return result;
}
int main(int argc, const char **argv) { @autoreleasepool {
    BOOL verify=argc==3 && strcmp(argv[2],"--verify-enabled")==0;
    if (argc!=2 && !verify) { fprintf(stderr,"Usage: register-input-source /path/to/InkFlow.app [--verify-enabled]\n"); return 2; }
    NSURL *url=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSBundle *bundle=[NSBundle bundleWithURL:url];
    if (![bundle.bundleIdentifier isEqual:@"io.damao.inputmethod.inkflow"]) {
        fprintf(stderr,"Unexpected input method bundle identifier.\n"); return 2;
    }
    if (!verify) {
        OSStatus launchStatus=LSRegisterURL((__bridge CFURLRef)url,true);
        printf("launch_services_status=%d\n",(int)launchStatus);
        if (launchStatus!=noErr) return 1;
        OSStatus result=TISRegisterInputSource((__bridge CFURLRef)url);
        printf("registration_status=%d\n",(int)result);
        if (result!=noErr) return 1;
    }
    CFArrayRef sources=copySource(@"io.damao.inputmethod.inkflow.Hans");
    CFIndex count=sources ? CFArrayGetCount(sources) : 0;
    printf("registered_mode_count=%ld\n",count);
    BOOL valid=count==1;
    if (valid) {
        TISInputSourceRef source=(TISInputSourceRef)CFArrayGetValueAtIndex(sources,0);
        NSString *name=property(source,kTISPropertyLocalizedName);
        BOOL selectable=[property(source,kTISPropertyInputSourceIsSelectCapable) boolValue];
        BOOL keyboardMode=[property(source,kTISPropertyInputSourceType) isEqual:(__bridge NSString *)kTISTypeKeyboardInputMode];
        printf("mode_name=%s\nmode_select_capable=%d\n",name.UTF8String ?: "",selectable);
        valid=[name hasPrefix:@"InkFlow"] && selectable && keyboardMode;
    }
    if (sources) CFRelease(sources);
    // A separate invocation observes persistent state without registering again.
    if (valid && verify) {
        BOOL parentEnabled=enabled(@"io.damao.inputmethod.inkflow");
        BOOL modeEnabled=enabled(@"io.damao.inputmethod.inkflow.Hans");
        printf("parent_enabled=%d\nmode_enabled=%d\n",parentEnabled,modeEnabled);
        valid=parentEnabled && modeEnabled;
    }
    if (!valid) {
        fprintf(stderr,"Expected named, selectable Chinese mode is unavailable%s.\n",verify ? " or not enabled" : ""); return 1;
    }
    if (!verify) puts("Registered only. Add InkFlow in System Settings, then run --verify-enabled. Registration does not enable or select it.");
    return 0;
}}

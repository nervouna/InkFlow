#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc!=2) { fprintf(stderr,"Usage: register-input-source /path/to/InkFlow.app\n"); return 2; }
    NSURL *url=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSBundle *bundle=[NSBundle bundleWithURL:url];
    NSString *identifier=@"io.damao.inputmethod.inkflow";
    if (![bundle.bundleIdentifier isEqual:identifier]) {
        fprintf(stderr,"Unexpected input method bundle identifier.\n"); return 2;
    }
    OSStatus result=TISRegisterInputSource((__bridge CFURLRef)url);
    printf("registration_status=%d\n",(int)result);
    NSDictionary *filter=@{(__bridge NSString *)kTISPropertyBundleID:identifier};
    CFArrayRef sources=TISCreateInputSourceList((__bridge CFDictionaryRef)filter,true);
    CFIndex count=sources ? CFArrayGetCount(sources) : 0;
    printf("registered_source_count=%ld\n",count);
    for (CFIndex i=0;i<count;i++) {
        TISInputSourceRef source=(TISInputSourceRef)CFArrayGetValueAtIndex(sources,i);
        CFStringRef sourceID=TISGetInputSourceProperty(source,kTISPropertyInputSourceID);
        if (sourceID) printf("source_id=%s\n",[(__bridge NSString *)sourceID UTF8String]);
    }
    if (sources) CFRelease(sources);
    if (result!=noErr || count==0) {
        fprintf(stderr,"Input source is not registered. Installation requires further diagnosis.\n"); return 1;
    }
    return 0;
}}

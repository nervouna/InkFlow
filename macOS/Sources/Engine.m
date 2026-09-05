#import "Engine.h"
#include <rime_api.h>
static RimeApi *api;
static BOOL ready;
@implementation IFEngine { RimeSessionId _session; }
+ (BOOL)startWithShared:(NSString *)shared user:(NSString *)user error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Engine must run on main thread");
    if (ready) return YES;
    for (NSString *name in @[@"default.yaml", @"inkflow_pinyin.schema.yaml", @"pinyin_simp.dict.yaml"]) {
        if (![[NSFileManager defaultManager] isReadableFileAtPath:[shared stringByAppendingPathComponent:name]]) {
            if (error) *error=[NSError errorWithDomain:@"io.damao.inkflow" code:2 userInfo:@{NSLocalizedDescriptionKey:@"InkFlow 缺少内置拼音资源，请重新构建并安装。"}];
            return NO;
        }
    }

    if (![[NSFileManager defaultManager] createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir=shared.fileSystemRepresentation;
    traits.user_data_dir=user.fileSystemRepresentation;
    traits.distribution_name="InkFlow"; traits.distribution_code_name="inkflow";
    traits.distribution_version="1.0"; traits.app_name="rime.inkflow";
    traits.min_log_level=3; traits.log_dir="";
    api=rime_get_api(); api->setup(&traits); api->initialize(&traits);
    if (api->start_maintenance(False)) api->join_maintenance_thread();
    RimeSessionId probe=api->create_session();
    ready=probe && api->select_schema(probe,"inkflow_pinyin");
    // Selecting a missing schema can succeed in librime; require an actual translator result.
    if (ready) {
        for (const char *key="nihao"; *key; ++key) api->process_key(probe,*key,0);
        RIME_STRUCT(RimeContext, context);
        ready=api->get_context(probe,&context);
        if (ready) { ready=context.menu.num_candidates>0; api->free_context(&context); }
    }
    if (probe) { api->clear_composition(probe); api->destroy_session(probe); }

    if (!ready) {
        api->finalize();
        if (error) *error=[NSError errorWithDomain:@"io.damao.inkflow" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法载入拼音方案，请重新构建并安装 InkFlow。"}];
    }
    return ready;
}
+ (void)stop { if (ready) { api->finalize(); ready=NO; } }
- (instancetype)init {
    if ((self=[super init])) {
        if (!ready || !(_session=api->create_session())) return nil;
        if (!api->select_schema(_session,"inkflow_pinyin")) { api->destroy_session(_session); _session=0; return nil; }
    }
    return self;
}
- (void)dealloc { if (ready && _session) api->destroy_session(_session); }
- (BOOL)key:(int)key modifiers:(int)modifiers {
    NSAssert(NSThread.isMainThread, @"Engine must run on main thread");
    return api->process_key(_session,key,modifiers);
}
- (BOOL)event:(NSEvent *)event {
    NSEventModifierFlags flags=event.modifierFlags;
    if (event.keyCode==49 && (flags & (NSEventModifierFlagControl|NSEventModifierFlagShift)) == (NSEventModifierFlagControl|NSEventModifierFlagShift) && !(flags & (NSEventModifierFlagCommand|NSEventModifierFlagOption))) {
        [self commit]; api->set_option(_session,"ascii_mode",!api->get_option(_session,"ascii_mode")); return YES;
    }
    if (flags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)) return NO;
    int key=0;
    switch(event.keyCode) {
        case 36: case 76: key=0xff0d; break;
        case 48: key=0xff09; break;
        case 51: key=0xff08; break;
        case 53: key=0xff1b; break;
        case 117: key=0xffff; break;
        case 123: key=0xff51; break;
        case 124: key=0xff53; break;
        case 125: key=0xff54; break;
        case 126: key=0xff52; break;
        case 115: key=0xff50; break;
        case 119: key=0xff57; break;
        case 116: key=0xff55; break;
        case 121: key=0xff56; break;
        default:
            if (event.characters.length!=1 || [event.characters characterAtIndex:0]>127) return NO;
            key=[event.characters characterAtIndex:0];
    }
    return [self key:key modifiers:(flags & NSEventModifierFlagShift) ? 1 : 0];
}
- (void)select:(NSUInteger)index { api->select_candidate_on_current_page(_session,index); }
- (void)commit { api->commit_composition(_session); }
- (void)clear { api->clear_composition(_session); }
- (NSString *)takeCommit {
    RIME_STRUCT(RimeCommit, commit);
    if (!api->get_commit(_session,&commit)) return @"";
    NSString *text=commit.text ? @(commit.text) : @""; api->free_commit(&commit); return text;
}
- (NSDictionary *)snapshot {
    RIME_STRUCT(RimeContext, ctx);
    if (!api->get_context(_session,&ctx)) return @{@"preedit":@"",@"cursor":@0,@"candidates":@[],@"page":@0,@"highlight":@0};
    NSString *preedit=ctx.composition.preedit ? @(ctx.composition.preedit) : @"";
    NSUInteger bytes=MIN((NSUInteger)MAX(ctx.composition.cursor_pos,0),[preedit lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    NSString *prefix=[[NSString alloc] initWithBytes:preedit.UTF8String length:bytes encoding:NSUTF8StringEncoding];
    NSMutableArray *candidates=[NSMutableArray array];
    for(int i=0;i<ctx.menu.num_candidates;i++) [candidates addObject:@(ctx.menu.candidates[i].text)];
    NSDictionary *result=@{@"preedit":preedit,@"cursor":@(prefix.length),@"candidates":candidates,@"page":@(ctx.menu.page_no),@"highlight":@(ctx.menu.highlighted_candidate_index)};
    api->free_context(&ctx); return result;
}
@end

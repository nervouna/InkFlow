#import "Settings.h"
#include <rime_api.h>
NSNotificationName const IFSettingsDidChangeNotification=@"IFSettingsDidChange";
@implementation IFSettings { NSUserDefaults *_defaults; }
+ (instancetype)sharedSettings { static IFSettings *settings; static dispatch_once_t once; dispatch_once(&once,^{ settings=[[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; }); return settings; }
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults { if ((self=[super init])) _defaults=defaults; return self; }
- (NSInteger)integerForKey:(NSString *)key allowed:(NSArray *)allowed fallback:(NSInteger)fallback {
 id value=[_defaults objectForKey:key];
 return [value isKindOfClass:NSNumber.class] && [allowed containsObject:value] ? [value integerValue] : fallback;
}
- (NSInteger)candidateCount { return [self integerForKey:@"candidateCount" allowed:@[@3,@4,@5,@6,@7,@8,@9] fallback:5]; }
- (NSInteger)fontSize { return [self integerForKey:@"fontSize" allowed:@[@14,@16,@18,@24,@36] fallback:14]; }
- (BOOL)vertical { return [self integerForKey:@"vertical" allowed:@[@0,@1] fallback:0]; }
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:IFSettingsDidChangeNotification object:self]; }
- (void)setCandidateCount:(NSInteger)value { [_defaults setInteger:(value>=3 && value<=9 ? value : 5) forKey:@"candidateCount"]; [self changed]; }
- (void)setFontSize:(NSInteger)value { [_defaults setInteger:([@[@14,@16,@18,@24,@36] containsObject:@(value)] ? value : 14) forKey:@"fontSize"]; [self changed]; }
- (void)setVertical:(BOOL)value { [_defaults setBool:value forKey:@"vertical"]; [self changed]; }
@end

@interface IFSettingsWindowController () <NSTableViewDataSource,NSTableViewDelegate>
@end
@implementation IFSettingsWindowController { NSViewController *_detail; NSTableView *_sidebar; }
+ (instancetype)sharedController { static IFSettingsWindowController *controller; static dispatch_once_t once; dispatch_once(&once,^{ controller=[self new]; }); return controller; }
- (instancetype)init { return [super initWithWindow:nil]; }
- (void)loadWindow {
 NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,340) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
 window.title=@"墨流拼音设置"; window.releasedWhenClosed=NO;
 NSSplitViewController *split=[NSSplitViewController new];
 NSViewController *side=[NSViewController new];
 NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,150,340)];
 _sidebar=[[NSTableView alloc] initWithFrame:scroll.bounds];
 [_sidebar addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"section"]];
 _sidebar.headerView=nil; _sidebar.dataSource=self; _sidebar.delegate=self; _sidebar.style=NSTableViewStyleSourceList;
 scroll.documentView=_sidebar; side.view=scroll;
 NSSplitViewItem *item=[NSSplitViewItem sidebarWithViewController:side]; item.minimumThickness=140; item.maximumThickness=180;
 [split addSplitViewItem:item];
 _detail=[NSViewController new]; _detail.view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,440,340)];
 [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:_detail]];
 window.contentViewController=split; self.window=window;
 [_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
 [self showSection:0]; [window center];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return 2; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
 (void)tableView; (void)column; return [NSTextField labelWithString:row==0 ? @"外观" : @"关于"];
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification { (void)notification; [self showSection:_sidebar.selectedRow]; }
- (void)showSection:(NSInteger)section {
 for (NSView *view in _detail.view.subviews.copy) [view removeFromSuperview];
 NSStackView *stack=[NSStackView new]; stack.orientation=NSUserInterfaceLayoutOrientationVertical; stack.alignment=NSLayoutAttributeLeading; stack.spacing=18; stack.translatesAutoresizingMaskIntoConstraints=NO;
 [_detail.view addSubview:stack];
 [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:_detail.view.leadingAnchor constant:28],[stack.topAnchor constraintEqualToAnchor:_detail.view.topAnchor constant:28],[stack.trailingAnchor constraintLessThanOrEqualToAnchor:_detail.view.trailingAnchor constant:-20]]];
 if (section==1) {
  NSBundle *bundle=NSBundle.mainBundle;
  NSImageView *icon=[NSImageView new]; icon.image=[bundle imageForResource:[bundle objectForInfoDictionaryKey:@"CFBundleIconFile"] ?: @"AppIcon"];
  [icon.widthAnchor constraintEqualToConstant:64].active=YES; [icon.heightAnchor constraintEqualToConstant:64].active=YES;
  [stack addArrangedSubview:icon];
  [stack addArrangedSubview:[NSTextField labelWithString:[bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"墨流拼音"]];
  NSString *version=[NSString stringWithFormat:@"版本 %@ (%@)",[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0",[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1"];
  [stack addArrangedSubview:[NSTextField labelWithString:version]];
  [stack addArrangedSubview:[NSTextField labelWithString:[NSString stringWithFormat:@"librime %s",rime_get_api()->get_version()]]];
  return;
 }
 IFSettings *s=IFSettings.sharedSettings;
 [self addPopup:@"候选词方向" titles:@[@"水平",@"竖直"] values:@[@0,@1] selected:@(s.vertical) tag:0 stack:stack];
 [self addPopup:@"候选词数量" titles:@[@"3",@"4",@"5",@"6",@"7",@"8",@"9"] values:@[@3,@4,@5,@6,@7,@8,@9] selected:@(s.candidateCount) tag:1 stack:stack];
 [self addPopup:@"候选词字号" titles:@[@"14",@"16",@"18",@"24",@"36"] values:@[@14,@16,@18,@24,@36] selected:@(s.fontSize) tag:2 stack:stack];
 [stack addArrangedSubview:[NSTextField wrappingLabelWithString:@"候选词数量在当前输入结束后生效。"]];
}
- (void)addPopup:(NSString *)label titles:(NSArray *)titles values:(NSArray *)values selected:(NSNumber *)selected tag:(NSInteger)tag stack:(NSStackView *)stack {
 NSPopUpButton *popup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; [popup addItemsWithTitles:titles];
 for (NSUInteger i=0;i<values.count;i++) [popup itemAtIndex:i].representedObject=values[i];
 [popup selectItemAtIndex:[values indexOfObject:selected]]; popup.tag=tag; popup.target=self; popup.action=@selector(change:);
 NSStackView *row=[NSStackView stackViewWithViews:@[[NSTextField labelWithString:label],popup]]; [popup.widthAnchor constraintEqualToConstant:120].active=YES; row.spacing=16; [stack addArrangedSubview:row];
}
- (void)change:(NSPopUpButton *)sender {
 IFSettings *s=IFSettings.sharedSettings; NSInteger value=[sender.selectedItem.representedObject integerValue];
 if (sender.tag==0) s.vertical=value; else if (sender.tag==1) s.candidateCount=value; else s.fontSize=value;
}
- (void)present { if (!self.window) [self loadWindow]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [self showWindow:nil]; [NSApp activateIgnoringOtherApps:YES]; [self.window makeKeyAndOrderFront:nil]; }
@end

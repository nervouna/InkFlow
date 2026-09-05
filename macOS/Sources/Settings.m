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

static NSToolbarItemIdentifier const IFSettingsTitleItemIdentifier=@"SettingsTitle";

@interface IFSettingsWindowController () <NSTableViewDataSource,NSTableViewDelegate,NSToolbarDelegate>
@end
@implementation IFSettingsWindowController {
 NSViewController *_detail;
 NSTableView *_sidebar;
 NSTextField *_sectionTitle;
}
+ (instancetype)sharedController { static IFSettingsWindowController *controller; static dispatch_once_t once; dispatch_once(&once,^{ controller=[self new]; }); return controller; }
- (instancetype)init { return [super initWithWindow:nil]; }
- (void)loadWindow {
 NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,450)
  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView
  backing:NSBackingStoreBuffered defer:NO];
 window.title=@"墨流拼音设置";
 window.titleVisibility=NSWindowTitleHidden;
 window.toolbarStyle=NSWindowToolbarStyleUnified;
 window.contentMinSize=NSMakeSize(700,380);
 window.collectionBehavior=NSWindowCollectionBehaviorFullScreenNone|NSWindowCollectionBehaviorFullScreenDisallowsTiling;
 window.releasedWhenClosed=NO;

 NSSplitViewController *split=[NSSplitViewController new];
 NSViewController *side=[NSViewController new];
 NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,180,450)];
 // The sidebar split item supplies the system material, including glass on macOS 26.
 scroll.drawsBackground=NO;
 scroll.hasVerticalScroller=YES;
 scroll.autohidesScrollers=YES;
 _sidebar=[[NSTableView alloc] initWithFrame:scroll.bounds];
 [_sidebar addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"section"]];
 _sidebar.headerView=nil;
 _sidebar.dataSource=self;
 _sidebar.delegate=self;
 _sidebar.style=NSTableViewStyleSourceList;
 _sidebar.rowHeight=36;
 _sidebar.allowsEmptySelection=NO;
 _sidebar.allowsMultipleSelection=NO;
 _sidebar.accessibilityLabel=@"墨流拼音设置";
 scroll.documentView=_sidebar; side.view=scroll;
 NSSplitViewItem *item=[NSSplitViewItem sidebarWithViewController:side];
 item.minimumThickness=160;
 item.maximumThickness=210;
 item.holdingPriority=NSLayoutPriorityDefaultHigh;
 item.canCollapse=NO;
 item.allowsFullHeightLayout=YES;
 [split addSplitViewItem:item];
 _detail=[NSViewController new];
 _detail.view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,520,450)];
 [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:_detail]];
 window.contentViewController=split;
 [split.view.widthAnchor constraintEqualToConstant:700].active=YES;
 self.window=window;

 _sectionTitle=[NSTextField labelWithString:@"外观"];
 _sectionTitle.font=[NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
 NSToolbar *toolbar=[[NSToolbar alloc] initWithIdentifier:@"SettingsToolbar"];
 toolbar.delegate=self;
 toolbar.displayMode=NSToolbarDisplayModeIconOnly;
 toolbar.allowsUserCustomization=NO;
 window.toolbar=toolbar;
 [_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
 [self showSection:0]; [window center];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
 (void)toolbar;
 return @[NSToolbarSidebarTrackingSeparatorItemIdentifier,IFSettingsTitleItemIdentifier,NSToolbarFlexibleSpaceItemIdentifier];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
 return [self toolbarDefaultItemIdentifiers:toolbar];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag {
 (void)toolbar; (void)flag;
 if (![identifier isEqualToString:IFSettingsTitleItemIdentifier]) return nil;
 NSToolbarItem *item=[[NSToolbarItem alloc] initWithItemIdentifier:identifier];
 item.view=_sectionTitle;
 item.label=@"墨流拼音设置";
 item.bordered=NO;
 item.visibilityPriority=NSToolbarItemVisibilityPriorityHigh;
 return item;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return 2; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
 (void)column;
 NSTableCellView *cell=[tableView makeViewWithIdentifier:@"section" owner:self];
 if (!cell) {
  cell=[NSTableCellView new];
  cell.identifier=@"section";
  NSTextField *label=[NSTextField labelWithString:@""];
  NSImageView *image=[NSImageView new];
  label.translatesAutoresizingMaskIntoConstraints=NO;
  image.translatesAutoresizingMaskIntoConstraints=NO;
  [cell addSubview:image]; [cell addSubview:label];
  cell.imageView=image; cell.textField=label;
  [NSLayoutConstraint activateConstraints:@[
   [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
   [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
   [image.widthAnchor constraintEqualToConstant:18],
   [image.heightAnchor constraintEqualToConstant:18],
   [label.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:10],
   [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
   [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4]
  ]];
 }
 cell.textField.stringValue=row==0 ? @"外观" : @"关于";
 cell.imageView.image=[NSImage imageWithSystemSymbolName:row==0 ? @"paintbrush" : @"info.circle" accessibilityDescription:nil];
 return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification { (void)notification; [self showSection:_sidebar.selectedRow]; }
- (void)showSection:(NSInteger)section {
 if (section<0) return;
 _sectionTitle.stringValue=section==1 ? @"关于" : @"外观";
 for (NSView *view in _detail.view.subviews.copy) [view removeFromSuperview];
 NSStackView *stack=[NSStackView new];
 stack.orientation=NSUserInterfaceLayoutOrientationVertical;
 stack.alignment=NSLayoutAttributeLeading;
 stack.spacing=12;
 stack.translatesAutoresizingMaskIntoConstraints=NO;
 [_detail.view addSubview:stack];
 NSLayoutGuide *safeArea=_detail.view.safeAreaLayoutGuide;
 [NSLayoutConstraint activateConstraints:@[
  [stack.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
  [stack.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:20],
  [stack.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],
  [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safeArea.bottomAnchor constant:-20]
 ]];
 if (section==1) {
  stack.alignment=NSLayoutAttributeCenterX;
  NSBundle *bundle=NSBundle.mainBundle;
  NSImageView *icon=[NSImageView new]; icon.image=[bundle imageForResource:[bundle objectForInfoDictionaryKey:@"CFBundleIconFile"] ?: @"AppIcon"];
  [icon.widthAnchor constraintEqualToConstant:64].active=YES; [icon.heightAnchor constraintEqualToConstant:64].active=YES;
  [stack addArrangedSubview:icon];
  NSTextField *name=[NSTextField labelWithString:[bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"墨流拼音"];
  name.font=[NSFont systemFontOfSize:22 weight:NSFontWeightBold];
  [stack addArrangedSubview:name];
  NSString *version=[NSString stringWithFormat:@"版本 %@ (%@)",[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0",[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1"];
  NSTextField *versionLabel=[NSTextField labelWithString:version];
  versionLabel.textColor=NSColor.secondaryLabelColor;
  [stack addArrangedSubview:versionLabel];
  NSTextField *engineLabel=[NSTextField labelWithString:[NSString stringWithFormat:@"librime %s",rime_get_api()->get_version()]];
  engineLabel.font=[NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  engineLabel.textColor=NSColor.secondaryLabelColor;
  [stack addArrangedSubview:engineLabel];
  return;
 }
 IFSettings *s=IFSettings.sharedSettings;
 NSGridView *grid=[NSGridView gridViewWithNumberOfColumns:2 rows:0];
 grid.translatesAutoresizingMaskIntoConstraints=NO;
 grid.columnSpacing=20;
 grid.rowSpacing=16;
 grid.yPlacement=NSGridCellPlacementCenter;
 [self addPopup:@"候选词方向" titles:@[@"水平",@"竖直"] values:@[@0,@1] selected:@(s.vertical) tag:0 grid:grid];
 [self addPopup:@"候选词数量" titles:@[@"3",@"4",@"5",@"6",@"7",@"8",@"9"] values:@[@3,@4,@5,@6,@7,@8,@9] selected:@(s.candidateCount) tag:1 grid:grid];
 [self addPopup:@"候选词字号" titles:@[@"14",@"16",@"18",@"24",@"36"] values:@[@14,@16,@18,@24,@36] selected:@(s.fontSize) tag:2 grid:grid];
 [grid columnAtIndex:0].xPlacement=NSGridCellPlacementLeading;
 [grid columnAtIndex:1].xPlacement=NSGridCellPlacementTrailing;

 NSBox *group=[NSBox new];
 group.titlePosition=NSNoTitle;
 group.contentViewMargins=NSMakeSize(16,16);
 [group.contentView addSubview:grid];
 [NSLayoutConstraint activateConstraints:@[
  [grid.leadingAnchor constraintEqualToAnchor:group.contentView.leadingAnchor],
  [grid.topAnchor constraintEqualToAnchor:group.contentView.topAnchor],
  [grid.trailingAnchor constraintEqualToAnchor:group.contentView.trailingAnchor],
  [grid.bottomAnchor constraintEqualToAnchor:group.contentView.bottomAnchor]
 ]];
 [stack addArrangedSubview:group];
 [group.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active=YES;
}
- (void)addPopup:(NSString *)label titles:(NSArray *)titles values:(NSArray *)values selected:(NSNumber *)selected tag:(NSInteger)tag grid:(NSGridView *)grid {
 NSPopUpButton *popup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; [popup addItemsWithTitles:titles];
 for (NSUInteger i=0;i<values.count;i++) [popup itemAtIndex:i].representedObject=values[i];
 [popup selectItemAtIndex:[values indexOfObject:selected]]; popup.tag=tag; popup.target=self; popup.action=@selector(change:);
 popup.accessibilityLabel=label;
 [popup.widthAnchor constraintEqualToConstant:120].active=YES;
 [grid addRowWithViews:@[[NSTextField labelWithString:label],popup]];
}
- (void)change:(NSPopUpButton *)sender {
 IFSettings *s=IFSettings.sharedSettings; NSInteger value=[sender.selectedItem.representedObject integerValue];
 if (sender.tag==0) s.vertical=value; else if (sender.tag==1) s.candidateCount=value; else s.fontSize=value;
}
- (void)present { if (!self.window) [self loadWindow]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [self showWindow:nil]; [NSApp activateIgnoringOtherApps:YES]; [self.window makeKeyAndOrderFront:nil]; }
@end

#import <AppKit/AppKit.h>

// Design preview only; no input-source registration or installation.
static void text(NSString *value, NSRect rect, NSFont *font, NSColor *color) {
    [value drawInRect:rect withAttributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:color}];
}
static void glyph(NSPoint center, CGFloat size, NSFont *font, NSColor *color) {
    NSBezierPath *path=[NSBezierPath bezierPath];
    CTFontRef ct=(__bridge CTFontRef)font;
    UniChar character=0x58A8; CGGlyph g=0;
    if (!CTFontGetGlyphsForCharacters(ct,&character,&g,1)) abort();
    [path moveToPoint:NSZeroPoint]; [path appendBezierPathWithCGGlyph:g inFont:font];
    NSRect bounds=path.bounds;
    CGFloat scale=size/MAX(bounds.size.width,bounds.size.height);
    NSAffineTransform *transform=[NSAffineTransform transform];
    [transform translateXBy:center.x yBy:center.y];
    [transform scaleBy:scale];
    [transform translateXBy:-NSMidX(bounds) yBy:-NSMidY(bounds)];
    [path transformUsingAffineTransform:transform];
    [color setFill]; [path fill];
}
int main(int argc,const char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    NSArray *weights=@[@"Regular",@"Medium",@"Semibold"];
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1440 pixelsHigh:760 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    NSAffineTransform *scale=[NSAffineTransform transform]; [scale scaleBy:2]; [scale concat];
    [NSColor.whiteColor setFill]; NSRectFill(NSMakeRect(0,0,720,380));
    text(@"「墨」原生输入源样式",NSMakeRect(24,338,670,28),[NSFont systemFontOfSize:20 weight:NSFontWeightMedium],NSColor.blackColor);
    text(@"参考截图比例：22 × 16pt 圆角底，白色字形；下方为实际尺寸的模拟状态",NSMakeRect(24,310,680,22),[NSFont systemFontOfSize:12],NSColor.darkGrayColor);
    for (NSUInteger i=0;i<weights.count;i++) {
        CGFloat x=24+i*232;
        NSFont *font=[NSFont fontWithName:[@"PingFangSC-" stringByAppendingString:weights[i]] size:16];
        if (!font) { fprintf(stderr,"Required PingFang font unavailable\n"); return 1; }
        [[NSColor colorWithWhite:0.15 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x+60,218,88,64) xRadius:18 yRadius:18] fill];
        glyph(NSMakePoint(x+104,250),44,font,NSColor.whiteColor);
        text(weights[i],NSMakeRect(x+66,190,150,24),[NSFont systemFontOfSize:14],NSColor.blackColor);
        for (NSUInteger row=0;row<3;row++) {
            CGFloat y=144-row*42;
            NSColor *background=row==0 ? [NSColor colorWithWhite:0.94 alpha:1] : row==1 ? [NSColor colorWithWhite:0.16 alpha:1] : [NSColor colorWithSRGBRed:0.05 green:0.38 blue:0.86 alpha:1];
            [background setFill]; NSRectFill(NSMakeRect(x,y,208,32));
            NSColor *foreground=row==0 ? NSColor.blackColor : NSColor.whiteColor;
            text(@"简",NSMakeRect(x+18,y+7,24,20),[NSFont systemFontOfSize:12],foreground);
            [foreground setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x+77,y+8,22,16) xRadius:4.5 yRadius:4.5] fill];
            glyph(NSMakePoint(x+88,y+16),11,font,background);
            text(@"周六  21:10",NSMakeRect(x+113,y+7,90,20),[NSFont systemFontOfSize:12],foreground);
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:@(argv[1]) atomically:YES]) return 1;
    puts("PASS: rendered PingFang SC Regular, Medium, Semibold at 2x");
} return 0; }

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

static NSBitmapImageRep *render(NSUInteger scale, NSBezierPath *glyph) {
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:22*scale pixelsHigh:16*scale bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(rep.bitmapData,0,rep.bytesPerRow*rep.pixelsHigh);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    // Bitmap contexts use pixel coordinates; TIFF logical size is recorded separately.
    NSAffineTransform *transform=[NSAffineTransform transform];
    [transform scaleBy:scale]; [transform concat];
    [NSColor.blackColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0,0,22,16) xRadius:4.5 yRadius:4.5] fill];
    CGContextSetBlendMode(NSGraphicsContext.currentContext.CGContext,kCGBlendModeClear);
    [glyph fill];
    [NSGraphicsContext restoreGraphicsState];
    rep.size=NSMakeSize(22,16);
    return rep;
}

int main(int argc,const char **argv) { @autoreleasepool {
    if (argc!=2) { fprintf(stderr,"Usage: generate-menu-icon output-directory\n"); return 2; }
    NSFont *font=[NSFont fontWithName:@"PingFangSC-Medium" size:16];
    UniChar character=0x58A8; CGGlyph g=0;
    if (!font || !CTFontGetGlyphsForCharacters((__bridge CTFontRef)font,&character,&g,1)) {
        fprintf(stderr,"PingFang SC Medium with the 墨 glyph is required.\n"); return 1;
    }
    NSBezierPath *glyph=[NSBezierPath bezierPath];
    [glyph moveToPoint:NSZeroPoint]; [glyph appendBezierPathWithCGGlyph:g inFont:font];
    NSRect bounds=glyph.bounds;
    NSAffineTransform *transform=[NSAffineTransform transform];
    [transform translateXBy:11 yBy:8];
    [transform scaleBy:11/MAX(bounds.size.width,bounds.size.height)];
    [transform translateXBy:-NSMidX(bounds) yBy:-NSMidY(bounds)];
    [glyph transformUsingAffineTransform:transform];

    NSString *directory=@(argv[1]); NSError *error=nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
    }
    NSMutableArray *reps=[NSMutableArray array];
    for (NSUInteger scale=1;scale<=2;scale++) {
        NSBitmapImageRep *rep=render(scale,glyph); [reps addObject:rep];
        NSString *name=scale==1 ? @"MenuIconTemplate.png" : @"MenuIconTemplate@2x.png";
        NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
        }
    }
    NSData *tiff=[NSBitmapImageRep TIFFRepresentationOfImageRepsInArray:reps];
    if (![tiff writeToFile:[directory stringByAppendingPathComponent:@"MenuIconTemplate.tiff"] options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
    }
    puts("PASS menu icon: PingFang SC Medium, 22x16pt, transparent glyph, 1x/2x TIFF");
} return 0; }

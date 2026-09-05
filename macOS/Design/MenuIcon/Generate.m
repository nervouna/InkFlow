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
    NSFont *typeface=[NSFont fontWithName:@"Futura-Bold" size:24];
    if (!typeface) { fprintf(stderr,"Futura Bold is required to regenerate the menu icon.\n"); return 1; }
    NSAttributedString *word=[[NSAttributedString alloc] initWithString:@"Ink"
        attributes:@{NSFontAttributeName:typeface}];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)word);
    NSBezierPath *glyph=[NSBezierPath bezierPath];
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run=(__bridge CTRunRef)object;
        CFIndex count=CTRunGetGlyphCount(run);
        if (count==0) continue;
        CGGlyph glyphs[count]; CGPoint positions[count];
        CTRunGetGlyphs(run,CFRangeMake(0,0),glyphs);
        CTRunGetPositions(run,CFRangeMake(0,0),positions);
        NSFont *font=(__bridge NSFont *)CFDictionaryGetValue(CTRunGetAttributes(run),kCTFontAttributeName);
        for (CFIndex i=0;i<count;i++) {
            [glyph moveToPoint:positions[i]];
            [glyph appendBezierPathWithCGGlyph:glyphs[i] inFont:font];
        }
    }
    CFRelease(line);
    NSRect bounds=glyph.bounds;
    if (NSIsEmptyRect(bounds)) { fprintf(stderr,"Unable to render Ink.\n"); return 1; }
    NSAffineTransform *transform=[NSAffineTransform transform];
    [transform translateXBy:11 yBy:8];
    [transform scaleBy:MIN(17/bounds.size.width,10.5/bounds.size.height)];
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
    puts("PASS menu icon: Ink, Futura Bold, 22x16pt, transparent lettering, 1x/2x TIFF");
} return 0; }

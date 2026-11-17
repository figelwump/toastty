// Adds a temporary HiDPI (2x) display, for capture-demo-screenshots on a Mac
// whose own display is 1x, such as the remote validation Mac mini. macOS
// makes the new display the main display, so windows that open while it
// exists open on it at 2x. It goes away when this process exits.
//
// Usage: hidpi-display <width> <height> <seconds>
//   Size in points. Prints one JSON line with the display's ID and bounds
//   when it is ready, then keeps it until standard input closes or the
//   seconds pass, whichever comes first.
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//          hidpi-display.m -o hidpi-display
//
// It uses the private CGVirtualDisplay classes of CoreGraphics, as display
// tools such as DeskPad do. Use it only for screenshots.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: hidpi-display <width> <height> <seconds>\n");
            return 2;
        }
        unsigned int width = (unsigned int)atoi(argv[1]);
        unsigned int height = (unsigned int)atoi(argv[2]);
        int seconds = atoi(argv[3]);
        if (width < 800 || height < 600 || seconds < 1) {
            fprintf(stderr, "hidpi-display: the size must be at least 800x600 points\n");
            return 2;
        }

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Toastty screenshots";
        descriptor.maxPixelsWide = width * 2;
        descriptor.maxPixelsHigh = height * 2;
        // About 220 pixels per inch, as on a Retina display.
        descriptor.sizeInMillimeters = CGSizeMake(width * 2 * 25.4 / 220, height * 2 * 25.4 / 220);
        descriptor.productID = 0x7464;
        descriptor.vendorID = 0x7473;
        descriptor.serialNum = 1;
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (display == nil || display.displayID == 0) {
            fprintf(stderr, "hidpi-display: macOS did not create the display\n");
            return 1;
        }
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
        if (![display applySettings:settings]) {
            fprintf(stderr, "hidpi-display: macOS refused the display mode\n");
            return 1;
        }

        // Wait until the mode is active at 2x.
        CGDirectDisplayID displayID = display.displayID;
        size_t pixelsWide = 0;
        for (int attempt = 0; attempt < 50 && pixelsWide != width * 2; attempt++) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
            pixelsWide = mode ? CGDisplayModeGetPixelWidth(mode) : 0;
            CGDisplayModeRelease(mode);
        }
        if (pixelsWide != width * 2) {
            fprintf(stderr, "hidpi-display: the display is not at 2x (%zu pixels wide)\n", pixelsWide);
            return 1;
        }
        CGRect bounds = CGDisplayBounds(displayID);
        printf("{\"displayID\":%u,\"x\":%.0f,\"y\":%.0f,\"width\":%.0f,\"height\":%.0f,\"main\":%s}\n",
               displayID, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
               CGDisplayIsMain(displayID) ? "true" : "false");
        fflush(stdout);

        // Keep the display while the caller holds standard input open.
        dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_event_handler(input, ^{
            char buffer[256];
            if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) {
                exit(0);
            }
        });
        dispatch_resume(input);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "hidpi-display: time limit reached\n");
            exit(0);
        });
        dispatch_main();
    }
    return 0;
}

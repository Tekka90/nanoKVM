// Creates a virtual HiDPI display so window captures come out at 2x on a 1x host.
// Usage: virtual-display <points-width> <points-height>   (prints "<displayID> <x> <y>" then runs until killed)
// Uses the private CGVirtualDisplay API; only meant for generating marketing screenshots.
#import <Cocoa/Cocoa.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSUInteger w = argc > 1 ? atoi(argv[1]) : 1512, h = argc > 2 ? atoi(argv[2]) : 982;
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.name = @"MacBook Pro Display";
        d.vendorID = 0x4d44; d.productID = 0x0001; d.serialNum = 1;
        d.maxPixelsWide = (unsigned)(w * 2); d.maxPixelsHigh = (unsigned)(h * 2);
        d.sizeInMillimeters = CGSizeMake(302, 196);
        d.queue = dispatch_get_main_queue();
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 1;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w * 2 height:h * 2 refreshRate:60],
                    [[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (!display || ![display applySettings:s]) { fprintf(stderr, "failed to create display\n"); return 1; }
        sleep(1);
        CGRect b = CGDisplayBounds(display.displayID);
        printf("%u %d %d %d %d\n", display.displayID, (int)b.origin.x, (int)b.origin.y, (int)b.size.width, (int)b.size.height);
        fflush(stdout);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}

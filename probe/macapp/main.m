// Plain macOS app: AppKit window + CAMetalLayer + precompiled macOS metallib.
// Built against the macOS SDK only; the probe runs this exact binary on iPad.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

@interface ProbeView : NSView
@property (nonatomic) id<MTLDevice> device;
@property (nonatomic) id<MTLCommandQueue> queue;
@property (nonatomic) id<MTLRenderPipelineState> pipeline;
@property (nonatomic) float hue;
@end

@implementation ProbeView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.wantsLayer = YES;
    self.layer = layer;

    NSError *err = nil;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"probe" ofType:@"metallib"];
    id<MTLLibrary> lib = [_device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
    NSLog(@"PROBE metallib %@ -> %@ %@", path, lib ? @"loaded" : @"FAILED", err ?: @"");
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vmain"];
    d.fragmentFunction = [lib newFunctionWithName:@"fmain"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:d error:&err];
    NSLog(@"PROBE pipeline %@ %@", _pipeline ? @"OK" : @"FAILED", err ?: @"");
    return self;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    _hue = fmodf(_hue + 0.25f, 1.0f);
    NSLog(@"PROBE mouseDown at %.0f,%.0f hue %.2f", p.x, p.y, _hue);
}

- (void)draw {
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.backingScaleFactor;
    layer.drawableSize = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable || !_pipeline) return;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.15, 1);
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:_pipeline];
    [enc setFragmentBytes:&_hue length:sizeof(float) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) ProbeView *view;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSLog(@"PROBE applicationDidFinishLaunching");
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"macOS probe";
    _view = [[ProbeView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _window.contentView = _view;
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { [self.view draw]; }];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSLog(@"PROBE main");
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}

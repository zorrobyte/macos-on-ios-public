// Minimal AppKit implemented on UIKit. A converted macOS binary binds its AppKit
// symbols (classes, NSApp, NSApplicationMain) to this library instead of AppKit.
// Unknown selectors on shim classes are logged once and return 0, so we can see
// what a real app needs next.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <sys/mman.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <crt_externs.h>
#import <mach-o/dyld.h>

@class NSWindow, NSView, NSViewController;

__attribute__((visibility("default"))) id NSApp = nil;
__attribute__((visibility("default"))) NSString *const NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillFinishLaunchingNotification = @"NSApplicationWillFinishLaunchingNotification";

static NSMutableArray<NSWindow *> *gWindows;
static UIViewController *gRootVC;

static id ShimMissing(id self, SEL _cmd, ...) { return nil; }
static id ShimMissingInit(id self, SEL _cmd, ...) { return self; }  // a nil init would drop the object

static BOOL ShimResolve(Class cls, SEL sel, BOOL isClass) {
    NSLog(@"SHIM MISSING %c[%@ %@]", isClass ? '+' : '-', NSStringFromClass(cls), NSStringFromSelector(sel));
    BOOL init = !isClass && [NSStringFromSelector(sel) hasPrefix:@"init"];
    class_addMethod(isClass ? object_getClass(cls) : cls, sel, (IMP)(init ? ShimMissingInit : ShimMissing), "@@:");
    return YES;
}

#define SHIM_RESOLVE \
    + (BOOL)resolveInstanceMethod:(SEL)sel { return [super resolveInstanceMethod:sel] || ShimResolve(self, sel, NO); } \
    + (BOOL)resolveClassMethod:(SEL)sel { return [super resolveClassMethod:sel] || ShimResolve(self, sel, YES); }

// MARK: NSEvent

typedef NS_ENUM(NSUInteger, NSEventType) {
    NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2, NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6,
    NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11, NSEventTypeFlagsChanged = 12, NSEventTypeScrollWheel = 22,
};

@interface NSEvent : NSObject
@property NSEventType type;
@property CGPoint locationInWindow;
@property NSTimeInterval timestamp;
@property (weak) NSWindow *window;
@property NSInteger clickCount, buttonNumber;
@property NSUInteger modifierFlags;
@property unsigned short keyCode;
@property (copy) NSString *characters, *charactersIgnoringModifiers;
@property BOOL isARepeat, hasPreciseScrollingDeltas;
@property CGFloat scrollingDeltaX, scrollingDeltaY, deltaX, deltaY;
@property NSUInteger phase, momentumPhase;
@end

static NSMutableArray *gMonitors;  // {mask, handler}
static NSUInteger gModifiers;
static CGPoint gMouse;

@implementation NSEvent
SHIM_RESOLVE
+ (id)addLocalMonitorForEventsMatchingMask:(uint64_t)mask handler:(NSEvent *(^)(NSEvent *))handler {
    if (!gMonitors) gMonitors = [NSMutableArray new];
    id token = @[@(mask), [handler copy]];
    [gMonitors addObject:token];
    return token;
}
+ (id)addGlobalMonitorForEventsMatchingMask:(uint64_t)mask handler:(id)handler { return [NSObject new]; }
+ (void)removeMonitor:(id)token { [gMonitors removeObject:token]; }
+ (void)setMouseCoalescingEnabled:(BOOL)flag {}
+ (BOOL)isMouseCoalescingEnabled { return YES; }
+ (NSUInteger)modifierFlags { return gModifiers; }
+ (CGPoint)mouseLocation { return gMouse; }
+ (NSUInteger)pressedMouseButtons { return 0; }
- (CGFloat)deltaZ { return 0; }
- (id)subtype { return nil; }
- (NSUInteger)subtype_ { return 0; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
@end

// MARK: NSWorkspace / NSRunningApplication
// No Man's Sky listens on the workspace notification center for its own activation and
// ignores input until it hears it. Activation is posted from the scene lifecycle below.

__attribute__((visibility("default"))) NSString *const NSWorkspaceDidActivateApplicationNotification = @"NSWorkspaceDidActivateApplicationNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceDidDeactivateApplicationNotification = @"NSWorkspaceDidDeactivateApplicationNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceApplicationKey = @"NSWorkspaceApplicationKey";

@interface NSRunningApplication : NSObject
@end
@implementation NSRunningApplication
SHIM_RESOLVE
+ (instancetype)currentApplication { static id app; static dispatch_once_t once; dispatch_once(&once, ^{ app = [self new]; }); return app; }
- (pid_t)processIdentifier { return getpid(); }
- (NSString *)bundleIdentifier { return NSBundle.mainBundle.bundleIdentifier; }
- (NSString *)localizedName { return NSProcessInfo.processInfo.processName; }
- (BOOL)isActive { return UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }
- (BOOL)isHidden { return UIApplication.sharedApplication.applicationState == UIApplicationStateBackground; }
- (BOOL)activateWithOptions:(NSUInteger)options { return YES; }
@end

@interface NSWorkspace : NSObject
@end
@implementation NSWorkspace
SHIM_RESOLVE
+ (instancetype)sharedWorkspace { static id ws; static dispatch_once_t once; dispatch_once(&once, ^{ ws = [self new]; }); return ws; }
- (NSNotificationCenter *)notificationCenter { static NSNotificationCenter *c; static dispatch_once_t once; dispatch_once(&once, ^{ c = [NSNotificationCenter new]; }); return c; }
- (NSRunningApplication *)frontmostApplication { return NSRunningApplication.currentApplication; }
- (NSArray *)runningApplications { return @[NSRunningApplication.currentApplication]; }
@end

static void ShimWorkspaceActivation(BOOL active) {
    [NSWorkspace.sharedWorkspace.notificationCenter
        postNotificationName:active ? NSWorkspaceDidActivateApplicationNotification : NSWorkspaceDidDeactivateApplicationNotification
                      object:NSWorkspace.sharedWorkspace
                    userInfo:@{NSWorkspaceApplicationKey: NSRunningApplication.currentApplication}];
}

// MARK: late observers
// Mac games often register for window-key / app-active notifications in their own frame loop,
// after the window already became key (on macOS that happens later). Tell such late observers
// the current state once, as if it had just happened (No Man's Sky: focus flag from DidBecomeKey).
static IMP gAddObserver;
static void ShimAddObserver(NSNotificationCenter *self, SEL _cmd, id observer, SEL sel, NSString *name, id object) {
    ((void (*)(id, SEL, id, SEL, id, id))gAddObserver)(self, _cmd, observer, sel, name, object);
    if (self != NSNotificationCenter.defaultCenter || !name || !gWindows.count) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    NSWindow *w = gWindows.lastObject;
    id sender = nil;
    if ([name isEqualToString:@"NSWindowDidBecomeKeyNotification"] || [name isEqualToString:@"NSWindowDidBecomeMainNotification"]) sender = w;
    else if ([name isEqualToString:@"NSApplicationDidBecomeActiveNotification"]) sender = NSApp;
    if (!sender || (object && object != sender)) return;
    NSLog(@"SHIM late observer for %@: delivering current state", name);
    __weak id weakObserver = observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        id o = weakObserver;
        if (o) ((void (*)(id, SEL, id))objc_msgSend)(o, sel, [NSNotification notificationWithName:name object:sender]);
    });
}
__attribute__((constructor)) static void HookLateObservers(void) {
    gAddObserver = method_setImplementation(class_getInstanceMethod(NSNotificationCenter.class, @selector(addObserver:selector:name:object:)), (IMP)ShimAddObserver);
}

// MARK: NSResponder / NSView

@interface NSResponder : NSObject
@property (nonatomic, weak) NSResponder *nextResponder;
@end
@implementation NSResponder
SHIM_RESOLVE
// Unhandled events go up the responder chain (view -> superview -> window), as in AppKit.
#define SHIM_FORWARD(sel) - (void)sel(NSEvent *)e { [self.nextResponder sel e]; }
SHIM_FORWARD(mouseDown:) SHIM_FORWARD(mouseUp:) SHIM_FORWARD(mouseDragged:) SHIM_FORWARD(mouseMoved:)
SHIM_FORWARD(scrollWheel:) SHIM_FORWARD(keyDown:) SHIM_FORWARD(keyUp:) SHIM_FORWARD(flagsChanged:)
SHIM_FORWARD(rightMouseDown:) SHIM_FORWARD(rightMouseUp:)
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
@end

static void ShimDispatch(NSEvent *e);

@interface ShimHostView : UIView
@property (weak) NSView *nsView;
@property BOOL pointerInside;
@end

@interface NSView : NSResponder
@property (nonatomic) CGRect frame;
@property (nonatomic) BOOL wantsLayer;
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, readonly) ShimHostView *hostView;
@property (nonatomic, weak) NSView *superview;
@property (nonatomic, readonly) NSMutableArray<NSView *> *shimSubviews;
@end

@implementation NSView
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super init])) {
        _frame = frame;
        _hostView = [[ShimHostView alloc] initWithFrame:frame];
        _hostView.nsView = self;
    }
    return self;
}
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (CGRect)bounds { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (void)setLayer:(CALayer *)layer {
    [_layer removeFromSuperlayer];
    _layer = layer;
    layer.frame = _hostView.bounds;
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        layer.opaque = YES;  // lets iOS skip blending the game's frames
        // Metal HUD follows one layer; pin it to each layer that actually goes on screen.
        if ([NSBundle.mainBundle.infoDictionary[@"MetalHudEnabled"] boolValue])
            ((CAMetalLayer *)layer).developerHUDProperties = @{@"mode": @"default"};
    }
    [_hostView.layer addSublayer:layer];
}
- (void)setWantsLayer:(BOOL)flag {
    _wantsLayer = flag;
    if (flag && !_layer)  // AppKit asks the view for its backing layer (Unity returns a CAMetalLayer)
        self.layer = [self respondsToSelector:@selector(makeBackingLayer)]
            ? ((CALayer *(*)(id, SEL))objc_msgSend)(self, @selector(makeBackingLayer)) : [CALayer layer];
}
- (CGPoint)convertPoint:(CGPoint)p fromView:(NSView *)view { return p; }  // single full-window content view
- (CGPoint)convertPoint:(CGPoint)p toView:(NSView *)view { return p; }
// View hierarchy (No Man's Sky adds its Gainput input view on top of the Metal view).
- (NSArray<NSView *> *)subviews { return _shimSubviews ? [_shimSubviews copy] : @[]; }
- (void)addSubview:(NSView *)v {
    if (!_shimSubviews) _shimSubviews = [NSMutableArray new];
    [v removeFromSuperview];
    [_shimSubviews addObject:v];
    v.superview = self;
    v.hostView.userInteractionEnabled = NO;  // touches stay with the window's host view
    [_hostView addSubview:v.hostView];
}
- (void)removeFromSuperview {
    [_superview.shimSubviews removeObject:self];
    _superview = nil;
    [_hostView removeFromSuperview];
}
- (NSWindow *)window { return _window ?: _superview.window; }
- (NSResponder *)nextResponder { return [super nextResponder] ?: (_superview ?: (NSResponder *)self.window); }
- (void)setAutoresizesSubviews:(BOOL)flag {}
- (BOOL)isHidden { return _hostView.hidden; }
- (void)setHidden:(BOOL)h { _hostView.hidden = h; }
// Deepest visible subview containing p (in this view's coordinates), topmost first.
- (NSView *)hitTest:(CGPoint)p {
    if (!CGRectContainsPoint(self.bounds, p) || self.isHidden) return nil;
    for (NSView *v in _shimSubviews.reverseObjectEnumerator) {
        NSView *h = [v hitTest:CGPointMake(p.x - v.frame.origin.x, p.y - v.frame.origin.y)];
        if (h) return h;
    }
    return self;
}
- (void)setNeedsDisplay:(BOOL)flag {}
- (void)setLayerContentsRedrawPolicy:(NSInteger)policy {}
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)setAutoresizingMask:(NSUInteger)mask {}
- (void)addTrackingArea:(id)area {}
- (void)removeTrackingArea:(id)area {}
- (NSArray *)trackingAreas { return @[]; }
- (BOOL)isFlipped { return NO; }
@end

@interface NSViewController : NSResponder
@property (nonatomic, strong) NSView *view;
@end

@implementation NSViewController
SHIM_RESOLVE
- (NSView *)view {
    if (!_view) {
        [self loadView];
        if (!_view) _view = [NSView new];
        if ([self respondsToSelector:@selector(viewDidLoad)]) [self performSelector:@selector(viewDidLoad)];
    }
    return _view;
}
- (void)loadView {}
@end

@implementation ShimHostView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.nsView.frame = self.bounds;
    for (CALayer *l in self.layer.sublayers) {
        l.frame = self.bounds;
        l.contentsScale = self.traitCollection.displayScale;
    }
}
- (NSEvent *)eventOfType:(NSEventType)type at:(CGPoint)p {
    NSEvent *e = [NSEvent new];
    e.type = type;
    e.locationInWindow = CGPointMake(p.x, self.bounds.size.height - p.y);  // AppKit origin is bottom-left
    gMouse = e.locationInWindow;
    e.timestamp = NSProcessInfo.processInfo.systemUptime;
    e.window = self.nsView.window;
    e.modifierFlags = gModifiers;
    return e;
}
- (void)send:(SEL)sel type:(NSEventType)type touches:(NSSet<UITouch *> *)touches {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    if (type == NSEventTypeLeftMouseDown) {
        if (!self.pointerInside) {  // Mac views learn the pointer is over them from their tracking area
            self.pointerInside = YES;
            NSEvent *enter = [self eventOfType:8 /* NSEventTypeMouseEntered */ at:p];
            if ([self.nsView respondsToSelector:@selector(mouseEntered:)]) [self.nsView performSelector:@selector(mouseEntered:) withObject:enter];
        }
        ShimDispatch([self eventOfType:NSEventTypeMouseMoved at:p]);  // hover first
    }
    NSEvent *e = [self eventOfType:type at:p];
    e.clickCount = MAX(1, t.tapCount);
    ShimDispatch(e);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    static int n; if (n++ < 3) NSLog(@"SHIM touch began (%d)", n);
    [self send:@selector(mouseDown:) type:NSEventTypeLeftMouseDown touches:t];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:@selector(mouseDragged:) type:NSEventTypeLeftMouseDragged touches:t]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:@selector(mouseUp:) type:NSEventTypeLeftMouseUp touches:t]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:@selector(mouseUp:) type:NSEventTypeLeftMouseUp touches:t]; }

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.gestureRecognizers.count) return;
    // two-finger drag, trackpad and mouse wheel -> scroll wheel
    UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
    scroll.minimumNumberOfTouches = 2;
    scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
    scroll.cancelsTouchesInView = NO;
    [self addGestureRecognizer:scroll];
    // mouse/trackpad pointer hover -> mouseMoved
    [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)]];
}
- (void)scroll:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    NSEvent *e = [self eventOfType:NSEventTypeScrollWheel at:[g locationInView:self]];
    e.scrollingDeltaX = e.deltaX = d.x / 4;
    e.scrollingDeltaY = e.deltaY = d.y / 4;
    e.hasPreciseScrollingDeltas = YES;
    ShimDispatch(e);
}
- (void)hover:(UIHoverGestureRecognizer *)g {
    ShimDispatch([self eventOfType:NSEventTypeMouseMoved at:[g locationInView:self]]);
}
@end

// MARK: NSWindowController (declared after NSWindow below)
@class NSWindowController;

// MARK: NSWindow / NSScreen

typedef struct { CGFloat top, left, bottom, right; } NSEdgeInsets_;  // AppKit's NSEdgeInsets layout

@interface NSScreen : NSObject
+ (instancetype)mainScreen;
@end

@interface NSWindow : NSResponder
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSViewController *contentViewController;
@property (nonatomic, weak) id windowController;
@property (nonatomic, weak) id delegate;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) CGRect frame;
@property (nonatomic) BOOL acceptsMouseMovedEvents;
@property (nonatomic) NSUInteger collectionBehavior, styleMask;
@property (nonatomic, weak) id shimFirstResponder;
@end

static void ShimNotify(NSWindow *w, NSString *name) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"window%@:", name]);
    NSNotification *n = [NSNotification notificationWithName:[NSString stringWithFormat:@"NSWindow%@Notification", name] object:w];
    if ([w.delegate respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(w.delegate, sel, n);
    [NSNotificationCenter.defaultCenter postNotification:n];
}

static void ShimAttach(NSWindow *w) {
    if (!gRootVC || !w.contentView || ![gWindows containsObject:w]) return;
    UIView *v = w.contentView.hostView;
    if (v.superview == gRootVC.view) return;
    v.frame = gRootVC.view.bounds;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gRootVC.view addSubview:v];
    w.frame = gRootVC.view.bounds;  // a Mac window becomes the whole screen
    ShimNotify(w, @"DidResize");
    ShimNotify(w, @"DidBecomeMain");
    ShimNotify(w, @"DidBecomeKey");
}

@implementation NSWindow
SHIM_RESOLVE
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    if ((self = [super init])) {
        _frame = rect;
        self.contentView = [[NSView alloc] initWithFrame:rect];
    }
    return self;
}
- (void)setContentView:(NSView *)v { _contentView = v; v.window = self; ShimAttach(self); }
- (void)setContentViewController:(NSViewController *)vc { _contentViewController = vc; self.contentView = vc.view; }
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer screen:(id)screen {
    return [self initWithContentRect:rect styleMask:style backing:backing defer:defer];
}
- (CGRect)contentLayoutRect { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (void)setContentAspectRatio:(CGSize)ratio {}
- (void)setContentMinSize:(CGSize)size {}
- (void)setContentMaxSize:(CGSize)size {}
- (void)setMinSize:(CGSize)size {}
- (void)setFrameOrigin:(CGPoint)origin {}
- (void)center {}
// iPad windows are always full screen; games that request it wait for these notifications
// (Cyberpunk spins until its m_isFullscreenMode flips).
- (void)toggleFullScreen:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        ShimNotify(self, @"WillEnterFullScreen");
        ShimNotify(self, @"DidEnterFullScreen");
    });
}
- (void)setIsVisible:(BOOL)v { if (v) [self makeKeyAndOrderFront:nil]; else [self orderOut:nil]; }
- (void)makeMainWindow { [self makeKeyAndOrderFront:nil]; }
- (CGPoint)convertPointToScreen:(CGPoint)p { return p; }      // one full-screen window
- (CGPoint)convertPointFromScreen:(CGPoint)p { return p; }
- (CGRect)convertRectToScreen:(CGRect)r { return r; }
- (CGRect)convertRectFromScreen:(CGRect)r { return r; }
- (void)invalidateCursorRectsForView:(id)view {}
- (NSUInteger)styleMask { return _styleMask | (1 << 14); }  // report NSWindowStyleMaskFullScreen
- (CGFloat)titlebarHeight { return 0; }
- (void)setFrame:(CGRect)frame display:(BOOL)display { if (!gRootVC) _frame = frame; }
- (void)setFrame:(CGRect)frame display:(BOOL)display animate:(BOOL)animate { [self setFrame:frame display:display]; }
- (void)setContentSize:(CGSize)size { if (!gRootVC) _frame.size = size; }
- (CGRect)contentRectForFrameRect:(CGRect)r { return r; }
- (CGRect)frameRectForContentRect:(CGRect)r { return r; }
- (BOOL)isKeyWindow { return [gWindows containsObject:self]; }
- (void)setDelegate:(id)d {
    _delegate = d;
    if (d && gRootVC && self.contentView.hostView.superview) {  // already on screen: tell the new delegate
        ShimNotify(self, @"DidBecomeMain");
        ShimNotify(self, @"DidBecomeKey");
    }
}
- (BOOL)isVisible { return [gWindows containsObject:self]; }
- (NSScreen *)screen { return [NSScreen mainScreen]; }
- (void)makeKeyWindow { [self makeKeyAndOrderFront:nil]; }
- (BOOL)makeFirstResponder:(id)r { _shimFirstResponder = r; return YES; }
- (id)firstResponder { return _shimFirstResponder ?: self.contentView; }
- (void)sendEvent:(NSEvent *)e {
    id target = (e.type == NSEventTypeKeyDown || e.type == NSEventTypeKeyUp || e.type == NSEventTypeFlagsChanged)
        ? [self firstResponder] : ([self.contentView hitTest:e.locationInWindow] ?: self.contentView);
    SEL sel = NULL;
    switch (e.type) {
        case NSEventTypeLeftMouseDown: sel = @selector(mouseDown:); break;
        case NSEventTypeLeftMouseUp: sel = @selector(mouseUp:); break;
        case NSEventTypeLeftMouseDragged: sel = @selector(mouseDragged:); break;
        case NSEventTypeMouseMoved: sel = @selector(mouseMoved:); break;
        case NSEventTypeScrollWheel: sel = @selector(scrollWheel:); break;
        case NSEventTypeKeyDown: sel = @selector(keyDown:); break;
        case NSEventTypeKeyUp: sel = @selector(keyUp:); break;
        case NSEventTypeFlagsChanged: sel = @selector(flagsChanged:); break;
    }
    if (sel && [target respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(target, sel, e);
}
- (void)makeKeyAndOrderFront:(id)sender {
    if (![gWindows containsObject:self]) [gWindows addObject:self];
    ShimAttach(self);
}
- (void)orderFront:(id)sender { [self makeKeyAndOrderFront:sender]; }
- (CGFloat)backingScaleFactor { return gRootVC ? gRootVC.view.traitCollection.displayScale : 2.0; }
- (void)close { [self orderOut:nil]; }
- (void)orderOut:(id)sender { [self.contentView.hostView removeFromSuperview]; [gWindows removeObject:self]; }
@end

@implementation NSScreen
SHIM_RESOLVE
+ (instancetype)mainScreen { static NSScreen *s; if (!s) s = [NSScreen new]; return s; }
+ (NSArray *)screens { return @[[self mainScreen]]; }
- (CGRect)frame { return gRootVC ? gRootVC.view.bounds : CGRectMake(0, 0, 1376, 1032); }
- (CGRect)visibleFrame { return [self frame]; }
- (NSDictionary *)deviceDescription { return @{@"NSScreenNumber": @1, @"NSDeviceSize": [NSValue valueWithCGSize:[self frame].size]}; }
- (NSString *)localizedName { return @"iPad"; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1.0; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return 1.0; }
- (NSTimeInterval)minimumRefreshInterval { return 1.0 / UIScreen.mainScreen.maximumFramesPerSecond; }
- (NSTimeInterval)maximumRefreshInterval { return 1.0 / 24; }  // ProMotion lower bound
- (NSTimeInterval)displayUpdateGranularity { return 0; }
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 0; }
- (NSEdgeInsets_)safeAreaInsets { return (NSEdgeInsets_){0, 0, 0, 0}; }
- (CGFloat)backingScaleFactor { return gRootVC ? gRootVC.view.traitCollection.displayScale : 2.0; }
@end

// MARK: NSApplication

@interface NSWindowController : NSResponder
@property (nonatomic, strong) NSWindow *window;
@end

@implementation NSWindowController
SHIM_RESOLVE
- (instancetype)initWithWindow:(NSWindow *)w { if ((self = [super init])) { _window = w; w.windowController = self; } return self; }
- (instancetype)init { return [self initWithWindow:nil]; }
- (void)setWindow:(NSWindow *)w { _window = w; w.windowController = self; }
- (void)showWindow:(id)sender { [_window makeKeyAndOrderFront:sender]; }
- (void)close { [_window close]; }
- (BOOL)isWindowLoaded { return _window != nil; }
- (void)loadWindow {}
- (void)windowDidLoad {}
- (void)windowWillLoad {}
@end

@interface NSApplication : NSResponder
@property (nonatomic, weak) id delegate;
@end

// MARK: games with their own main loop (Cyberpunk): UIKit on its own stack
// UIApplicationMain never returns, but such games call nextEventMatchingMask: from deep inside
// their loop. On the first poll we start UIKit on a separate 8 MB stack; once its scene is up we
// switch back to the game's stack. UIKit's stack stays parked for good (as UIApplicationMain would);
// later polls pump the main run loop, which is per thread, so UIKit keeps working.

typedef struct { uint64_t x19_x30[12], sp, d8_d15[8]; } ShimContext;
void ShimContextSwitch(ShimContext *save, const ShimContext *load);
__asm__(".text\n.p2align 2\n.private_extern _ShimContextSwitch\n_ShimContextSwitch:\n"
        "stp x19, x20, [x0, #0]\n stp x21, x22, [x0, #16]\n stp x23, x24, [x0, #32]\n"
        "stp x25, x26, [x0, #48]\n stp x27, x28, [x0, #64]\n stp x29, x30, [x0, #80]\n"
        "mov x9, sp\n str x9, [x0, #96]\n"
        "stp d8, d9, [x0, #104]\n stp d10, d11, [x0, #120]\n stp d12, d13, [x0, #136]\n stp d14, d15, [x0, #152]\n"
        "ldp x19, x20, [x1, #0]\n ldp x21, x22, [x1, #16]\n ldp x23, x24, [x1, #32]\n"
        "ldp x25, x26, [x1, #48]\n ldp x27, x28, [x1, #64]\n ldp x29, x30, [x1, #80]\n"
        "ldr x9, [x1, #96]\n mov sp, x9\n"
        "ldp d8, d9, [x1, #104]\n ldp d10, d11, [x1, #120]\n ldp d12, d13, [x1, #136]\n ldp d14, d15, [x1, #152]\n"
        "ret\n");

static ShimContext gGameContext, gUIKitContext;
static BOOL gPolling;                           // a game polls: input is queued, not dispatched
static NSMutableArray<NSEvent *> *gEventQueue;
static BOOL gUIKitStarted, gUIKitOnFiber;
static NSEvent *gCurrentEvent;
static NSUInteger gPresentationOptions;

static void ShimUIKitFiberMain(void) {
    UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), @"UIApplication", @"ShimAppDelegate");
    abort();  // UIApplicationMain never returns
}

static void ShimStartUIKitOnFiber(void) {
    NSLog(@"SHIM game polls for events: starting UIKit on its own stack");
    gUIKitStarted = gUIKitOnFiber = gPolling = YES;
    if (!gEventQueue) gEventQueue = [NSMutableArray new];
    size_t size = 8 << 20, guard = 16 << 10;
    char *stack = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED) abort();
    mprotect(stack, guard, PROT_NONE);  // overflow guard at the bottom
    memset(&gUIKitContext, 0, sizeof gUIKitContext);
    gUIKitContext.x19_x30[11] = (uint64_t)ShimUIKitFiberMain;  // x30: "return" into the fiber
    gUIKitContext.sp = ((uint64_t)stack + size) & ~15ULL;
    ShimContextSwitch(&gGameContext, &gUIKitContext);  // back here once the scene is up
}

// Called on UIKit's stack once launch work is done: park it and resume the game.
static void ShimYieldToGame(void) {
    static BOOL yielded;
    if (!gUIKitOnFiber || yielded) return;
    yielded = YES;
    NSLog(@"SHIM UIKit up: resuming the game's loop");
    ShimContextSwitch(&gUIKitContext, &gGameContext);
}

static NSEvent *ShimTakeEvent(uint64_t mask, BOOL dequeue) {
    for (NSUInteger i = 0; i < gEventQueue.count; i++) {
        NSEvent *e = gEventQueue[i];
        if (!(mask & (1ULL << e.type))) continue;
        if (!dequeue) return e;
        [gEventQueue removeObjectAtIndex:i--];
        for (NSArray *m in [gMonitors copy]) {  // local monitors see events as they are dequeued
            if (!([m[0] unsignedLongLongValue] & (1ULL << e.type))) continue;
            e = ((NSEvent *(^)(NSEvent *))m[1])(e);
            if (!e) break;
        }
        if (e) return e;
    }
    return nil;
}

@implementation NSApplication
SHIM_RESOLVE
+ (instancetype)sharedApplication {
    if (!NSApp) { NSApp = [self new]; gWindows = [NSMutableArray new]; }
    return NSApp;
}
- (BOOL)setActivationPolicy:(NSInteger)policy { return YES; }
- (void)activateIgnoringOtherApps:(BOOL)flag {}
- (void)finishLaunching {}
- (NSArray *)windows { return gWindows; }
- (void)terminate:(id)sender { exit(0); }
- (void)sendEvent:(NSEvent *)e { [e.window sendEvent:e]; }
- (NSWindow *)keyWindow { return gWindows.lastObject; }
- (NSWindow *)mainWindow { return gWindows.lastObject; }
- (void)run {
    if (gUIKitStarted) { for (;;) CFRunLoopRun(); }  // UIKit already up (game polled first)
    NSLog(@"SHIM -[NSApplication run] -> UIApplicationMain");
    UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), @"UIApplication", @"ShimAppDelegate");  // Info.plist NSPrincipalClass is the Mac app class
}
- (BOOL)isRunning { return gUIKitStarted; }
- (NSUInteger)presentationOptions { return gPresentationOptions; }
- (void)setPresentationOptions:(NSUInteger)o { gPresentationOptions = o; }
- (BOOL)isActive { return YES; }
- (void)stop:(id)sender {}
- (void)updateWindows {}
- (NSEvent *)currentEvent { return gCurrentEvent; }
- (void)postEvent:(NSEvent *)e atStart:(BOOL)atStart {
    if (!gEventQueue) gEventQueue = [NSMutableArray new];
    if (atStart) [gEventQueue insertObject:e atIndex:0]; else [gEventQueue addObject:e];
}
- (void)discardEventsMatchingMask:(uint64_t)mask beforeEvent:(NSEvent *)last {
    NSIndexSet *drop = [gEventQueue indexesOfObjectsPassingTest:^BOOL(NSEvent *e, NSUInteger i, BOOL *stop) {
        if (e == last) { *stop = YES; return NO; }
        return (mask & (1ULL << e.type)) != 0;
    }];
    [gEventQueue removeObjectsAtIndexes:drop];
}
- (NSEvent *)nextEventMatchingMask:(uint64_t)mask untilDate:(NSDate *)date inMode:(NSString *)mode dequeue:(BOOL)dequeue {
    if (!gUIKitStarted) ShimStartUIKitOnFiber();
    NSEvent *e = ShimTakeEvent(mask, dequeue);
    NSTimeInterval wait = date ? date.timeIntervalSinceNow : 0;
    while (!e) {  // let iOS deliver input (our touch/key handlers queue it), until an event or the date
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, MAX(0, MIN(wait, 0.25)), true);
        e = ShimTakeEvent(mask, dequeue);
        wait = date ? date.timeIntervalSinceNow : 0;
        if (wait <= 0) break;
    }
    if (e && dequeue) gCurrentEvent = e;
    static unsigned polls, delivered; static CFAbsoluteTime last;
    polls++; if (e && dequeue) delivered++;
    if (CFAbsoluteTimeGetCurrent() - last > 5) {  // is input reaching a polling game?
        NSLog(@"SHIM polls=%u delivered=%u queued=%lu (last 5 s)", polls, delivered, (unsigned long)gEventQueue.count);
        polls = delivered = 0; last = CFAbsoluteTimeGetCurrent();
    }
    return e;
}
@end

// Delegate class from the main nib's source XML (designable.nib), e.g. Unity's PlayerAppDelegate.
// The class in the main executable that adopts NSApplicationDelegate (matched by protocol name).
static NSString *ExeDelegateClass(void) {
    unsigned n = 0;
    const char **names = objc_copyClassNamesForImage(_dyld_get_image_name(0), &n);
    NSString *found = nil;
    for (unsigned i = 0; i < n && !found; i++) {
        unsigned pc = 0;
        Protocol * __unsafe_unretained *ps = class_copyProtocolList(objc_getClass(names[i]), &pc);
        for (unsigned j = 0; j < pc; j++)
            if (!strcmp(protocol_getName(ps[j]), "NSApplicationDelegate")) found = @(names[i]);
        free(ps);
    }
    free(names);
    return found;
}

static NSString *NibDelegateClass(NSString *nibName) {
    // bundlePath is the Mac root (see RuntimeHooks.m), so this is the Mac app's own nib
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingFormat:@"/Contents/Resources/%@.nib/designable.nib", nibName];
    NSString *xml = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!xml) return ExeDelegateClass();  // compiled nib (a single NIBArchive file, e.g. No Man's Sky)
    NSRegularExpression *outlet = [NSRegularExpression regularExpressionWithPattern:@"<outlet property=\"delegate\" destination=\"([^\"]+)\"" options:0 error:nil];
    NSTextCheckingResult *m = xml ? [outlet firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)] : nil;
    if (!m) return nil;
    NSString *dest = [xml substringWithRange:[m rangeAtIndex:1]];
    NSString *pattern = [NSString stringWithFormat:@"id=\"%@\"[^>]*customClass=\"([^\"]+)\"", dest];
    NSRegularExpression *obj = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *c = [obj firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    return c ? [xml substringWithRange:[c rangeAtIndex:1]] : nil;
}

// AppKit's event path: local monitors (may swallow/replace), then -[NSApp sendEvent:].
// Once a game polls (see ShimStartUIKitOnFiber), input is queued for its loop instead.
static void ShimDispatch(NSEvent *e) {
    if (!e.window) e.window = gWindows.lastObject;
    if (gPolling) { [gEventQueue addObject:e]; return; }
    for (NSArray *m in [gMonitors copy]) {
        if (!([m[0] unsignedLongLongValue] & (1ULL << e.type))) continue;
        e = ((NSEvent *(^)(NSEvent *))m[1])(e);
        if (!e) return;
    }
    [(NSApplication *)NSApp sendEvent:e];
}

__attribute__((visibility("default"))) int NSApplicationMain(int argc, const char *argv[]) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    Class principal = NSClassFromString(info[@"NSPrincipalClass"]) ?: [NSApplication class];
    NSApplication *app = [principal sharedApplication];
    NSString *delegateName = info[@"SHIMAppDelegate"] ?: NibDelegateClass(info[@"NSMainNibFile"]);
    static id delegate;  // nib top-level objects are retained by the nib owner; keep it alive
    delegate = [NSClassFromString(delegateName) new];
    NSLog(@"SHIM NSApplicationMain principal=%@ delegate=%@ (%@)", principal, delegateName, delegate);
    app.delegate = delegate;
    [app run];
    return 0;
}

// MARK: UIKit side

@interface ShimViewController : UIViewController
@end
// USB HID keyboard usage -> macOS virtual key code (kVK_*).
static int ShimMacKeyCode(long hid) {
    static const short letters[26] = {0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6};
    static const short digits[10] = {18, 19, 20, 21, 23, 22, 26, 28, 25, 29};  // 1..9, 0
    static const short fkeys[12] = {122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111};
    if (hid >= 4 && hid <= 29) return letters[hid - 4];
    if (hid >= 30 && hid <= 39) return digits[hid - 30];
    if (hid >= 58 && hid <= 69) return fkeys[hid - 58];
    switch (hid) {
        case 40: return 36;  case 41: return 53;  case 42: return 51;  case 43: return 48;  case 44: return 49;
        case 45: return 27;  case 46: return 24;  case 47: return 33;  case 48: return 30;  case 49: return 42;
        case 51: return 41;  case 52: return 39;  case 53: return 50;  case 54: return 43;  case 55: return 47;
        case 56: return 44;  case 57: return 57;  case 74: return 115; case 75: return 116; case 76: return 117;
        case 77: return 119; case 78: return 121; case 79: return 124; case 80: return 123; case 81: return 125;
        case 82: return 126; case 224: return 59; case 225: return 56; case 226: return 58; case 227: return 55;
        case 228: return 62; case 229: return 60; case 230: return 61; case 231: return 54;
    }
    return -1;
}

static NSUInteger ShimMacModifiers(UIKeyModifierFlags f) {
    NSUInteger m = 0;
    if (f & UIKeyModifierAlphaShift) m |= 1 << 16;
    if (f & UIKeyModifierShift) m |= 1 << 17;
    if (f & UIKeyModifierControl) m |= 1 << 18;
    if (f & UIKeyModifierAlternate) m |= 1 << 19;
    if (f & UIKeyModifierCommand) m |= 1 << 20;
    return m;
}

@implementation ShimViewController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self becomeFirstResponder]; }
- (void)sendPresses:(NSSet<UIPress *> *)presses down:(BOOL)down {
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        int code = ShimMacKeyCode(key.keyCode);
        if (code < 0) continue;
        NSUInteger before = gModifiers;
        gModifiers = ShimMacModifiers(key.modifierFlags);
        BOOL modifierKey = key.keyCode >= 224 && key.keyCode <= 231;
        NSEvent *e = [NSEvent new];
        e.type = modifierKey ? NSEventTypeFlagsChanged : (down ? NSEventTypeKeyDown : NSEventTypeKeyUp);
        if (modifierKey && before == gModifiers) continue;
        e.keyCode = code;
        e.characters = key.characters;
        e.charactersIgnoringModifiers = key.charactersIgnoringModifiers;
        e.modifierFlags = gModifiers;
        e.timestamp = press.timestamp;
        e.locationInWindow = gMouse;
        ShimDispatch(e);
    }
}
- (void)pressesBegan:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self sendPresses:p down:YES]; }
- (void)pressesEnded:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self sendPresses:p down:NO]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self sendPresses:p down:NO]; }
@end

@interface ShimAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ShimAppDelegate
@end

@interface ShimSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ShimSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    gRootVC = [ShimViewController new];
    gRootVC.view.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = gRootVC;
    [self.window makeKeyAndVisible];
    for (NSWindow *w in gWindows) ShimAttach(w);

    static BOOL launched;
    if (launched) return;
    launched = YES;
    // Run the Mac app's launch code after the scene is up: iOS kills apps whose first scene
    // takes ~20 s to connect, and Mac games do heavy setup in applicationDidFinishLaunching.
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishMacLaunch]; });
}

// Foreground/background -> the Mac app-activation notifications games pause/resume on.
static void ShimPostApp(NSString *name, SEL delegateSel) {
    NSApplication *app = NSApp;
    NSNotification *n = [NSNotification notificationWithName:name object:app];
    if ([app.delegate respondsToSelector:delegateSel]) [app.delegate performSelector:delegateSel withObject:n];
    [NSNotificationCenter.defaultCenter postNotification:n];
}
- (void)sceneWillResignActive:(UIScene *)scene {
    NSLog(@"SHIM scene sceneWillResignActive (app state %ld)", (long)UIApplication.sharedApplication.applicationState);
    ShimPostApp(@"NSApplicationWillResignActiveNotification", @selector(applicationWillResignActive:));
    ShimPostApp(@"NSApplicationDidResignActiveNotification", @selector(applicationDidResignActive:));
    ShimWorkspaceActivation(NO);
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
    NSLog(@"SHIM scene sceneDidEnterBackground (app state %ld)", (long)UIApplication.sharedApplication.applicationState);
    ShimPostApp(@"NSApplicationWillHideNotification", @selector(applicationWillHide:));
    ShimPostApp(@"NSApplicationDidHideNotification", @selector(applicationDidHide:));
}
- (void)sceneWillEnterForeground:(UIScene *)scene {
    NSLog(@"SHIM scene sceneWillEnterForeground (app state %ld)", (long)UIApplication.sharedApplication.applicationState);
    ShimPostApp(@"NSApplicationWillUnhideNotification", @selector(applicationWillUnhide:));
    ShimPostApp(@"NSApplicationDidUnhideNotification", @selector(applicationDidUnhide:));
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    NSLog(@"SHIM scene sceneDidBecomeActive (app state %ld)", (long)UIApplication.sharedApplication.applicationState);
    ShimPostApp(@"NSApplicationWillBecomeActiveNotification", @selector(applicationWillBecomeActive:));
    ShimPostApp(@"NSApplicationDidBecomeActiveNotification", @selector(applicationDidBecomeActive:));
    ShimWorkspaceActivation(YES);
}

- (void)finishMacLaunch {
    NSApplication *app = NSApp;
    NSNotification *will = [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:app];
    NSNotification *did = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app];
    if ([app.delegate respondsToSelector:@selector(applicationWillFinishLaunching:)])
        [app.delegate performSelector:@selector(applicationWillFinishLaunching:) withObject:will];
    [NSNotificationCenter.defaultCenter postNotification:will];
    if ([app.delegate respondsToSelector:@selector(applicationDidFinishLaunching:)])
        [app.delegate performSelector:@selector(applicationDidFinishLaunching:) withObject:did];
    [NSNotificationCenter.defaultCenter postNotification:did];
    // macOS activates the app after launch; the scene became active before the game's launch code
    // registered for it (No Man's Sky ignores input until it hears this).
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        ShimPostApp(@"NSApplicationWillBecomeActiveNotification", @selector(applicationWillBecomeActive:));
        ShimPostApp(@"NSApplicationDidBecomeActiveNotification", @selector(applicationDidBecomeActive:));
        ShimWorkspaceActivation(YES);
        for (NSWindow *w in gWindows) {  // likewise window focus (No Man's Sky: NSWindowDidBecomeKeyNotification)
            ShimNotify(w, @"DidBecomeMain");
            ShimNotify(w, @"DidBecomeKey");
        }
    }
    // iOS announces already-paired controllers early in launch, before games that register in
    // applicationDidFinishLaunching (Cyberpunk) are listening. Replay them a few seconds later,
    // once the game's loop (and its input system) is running, as a Mac would deliver them.
    NSNumber *replay = NSBundle.mainBundle.infoDictionary[@"SHIMControllerReplay"];
    if (!replay || replay.boolValue) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        for (GCController *c in GCController.controllers) {
            NSLog(@"SHIM replaying controller connect for %@", c.vendorName);
            [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:c];
        }
        for (GCMouse *m in GCMouse.mice)
            [NSNotificationCenter.defaultCenter postNotificationName:GCMouseDidConnectNotification object:m];
    });
    // Games with their own loop: hand the thread back (no-op otherwise). Not from here: this runs
    // inside a main-queue block, and parking the stack mid-block would wedge the main queue for
    // good (GameController and other main-queue deliveries would never arrive). A run-loop timer
    // callout doesn't hold the queue.
    CFRunLoopTimerRef t = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent(), 0, 0, 0,
                                                          ^(CFRunLoopTimerRef timer) { ShimYieldToGame(); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    CFRelease(t);
}
@end

// MARK: NSAlert (logged; no UI yet)

@interface NSAlert : NSObject
@property (nonatomic, copy) NSString *messageText;
@property (nonatomic, copy) NSString *informativeText;
@end

@implementation NSAlert
SHIM_RESOLVE
- (id)addButtonWithTitle:(NSString *)title { NSLog(@"SHIM NSAlert button: %@", title); return nil; }
- (NSInteger)runModal {
    NSLog(@"SHIM NSAlert runModal: %@ | %@", self.messageText, self.informativeText);
    return 1000;  // NSAlertFirstButtonReturn
}
@end

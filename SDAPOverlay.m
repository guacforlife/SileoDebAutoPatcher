#import "SDAPOverlay.h"
#import "SDAPCommon.h"

static const CGFloat kPillWidth  = 260.0;
static const CGFloat kPillHeight = 62.0;
static const CGFloat kBottomGap  = 44.0;

@interface SDAPOverlayView : UIView
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UILabel *subtitle;
@property (nonatomic, copy)   void (^onCancel)(void);
@end

@implementation SDAPOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (!self) return nil;

	self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
	self.layer.cornerRadius = 16.0;
	self.layer.cornerCurve = kCACornerCurveContinuous;
	self.layer.borderWidth = 1.0;
	self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

	_title = [[UILabel alloc] init];
	_title.textColor = [UIColor whiteColor];
	_title.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
	_title.textAlignment = NSTextAlignmentCenter;
	_title.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:_title];

	_subtitle = [[UILabel alloc] init];
	_subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
	_subtitle.font = [UIFont systemFontOfSize:12.0];
	_subtitle.textAlignment = NSTextAlignmentCenter;
	_subtitle.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:_subtitle];

	[NSLayoutConstraint activateConstraints:@[
		[_title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
		[_title.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
		[_title.topAnchor constraintEqualToAnchor:self.topAnchor constant:11],
		[_subtitle.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
		[_subtitle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
		[_subtitle.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:3],
	]];

	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
	[self addGestureRecognizer:tap];
	return self;
}

- (void)tapped {
	void (^cb)(void) = self.onCancel;
	self.onCancel = nil;            // one shot
	if (cb) cb();
}

@end

#pragma mark -

@implementation SDAPOverlay

static UIWindow *sWindow = nil;
static SDAPOverlayView *sView = nil;
static NSTimer *sTimer = nil;
static NSDate *sDeadline = nil;

+ (UIWindowScene *)activeScene {
	UIWindowScene *fallback = nil;
	@try {
		for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
			if (![s isKindOfClass:[UIWindowScene class]]) continue;
			if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
			if (!fallback) fallback = (UIWindowScene *)s;
		}
	} @catch (__unused NSException *e) {}
	return fallback;
}

+ (void)ensureWindow {
	if (sWindow) return;
	UIWindowScene *scene = [self activeScene];
	if (!scene) return;

	CGRect bounds = scene.coordinateSpace.bounds;
	CGRect frame = CGRectMake((bounds.size.width - kPillWidth) / 2.0,
	                          bounds.size.height - kPillHeight - kBottomGap,
	                          kPillWidth, kPillHeight);

	// initWithWindowScene: — a plain -init window never displays on iOS 13+.
	sWindow = [[UIWindow alloc] initWithWindowScene:scene];
	sWindow.frame = frame;
	sWindow.windowLevel = UIWindowLevelAlert + 1;
	sWindow.backgroundColor = [UIColor clearColor];
	sWindow.rootViewController = [[UIViewController alloc] init];

	sView = [[SDAPOverlayView alloc] initWithFrame:sWindow.rootViewController.view.bounds];
	sView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[sWindow.rootViewController.view addSubview:sView];

	// NOT makeKeyAndVisible — we must never steal key status from the app.
	sWindow.hidden = NO;
	sWindow.alpha = 0.0;
	[UIView animateWithDuration:0.18 animations:^{ sWindow.alpha = 1.0; }];
}

+ (void)showCountdown:(double)seconds onCancel:(void (^)(void))onCancel {
	dispatch_async(dispatch_get_main_queue(), ^{
		[self teardownTimer];
		[self ensureWindow];
		if (!sView) {
			SDAPEvent(@"OVERLAY", @"FAIL", @"no window scene");
			return;
		}
		sView.subtitle.text = @"tap to cancel";
		sView.onCancel = ^{
			SDAPEvent(@"PATCHER_CANCEL", @"OK", @"user tapped the countdown");
			if (onCancel) onCancel();
			[SDAPOverlay dismiss];
		};
		sDeadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
		[self tick];
		sTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
			selector:@selector(tick) userInfo:nil repeats:YES];
	});
}

+ (void)tick {
	if (!sView || !sDeadline) return;
	double left = [sDeadline timeIntervalSinceNow];
	if (left < 0) left = 0;
	sView.title.text = [NSString stringWithFormat:@"Converting in %.0f…", ceil(left)];
	if (left <= 0) [self teardownTimer];
}

+ (void)teardownTimer {
	if (sTimer) { [sTimer invalidate]; sTimer = nil; }
	sDeadline = nil;
}

+ (void)flashMessage:(NSString *)message {
	dispatch_async(dispatch_get_main_queue(), ^{
		[self teardownTimer];
		[self ensureWindow];
		if (!sView) return;
		sView.onCancel = nil;
		sView.title.text = message ?: @"";
		sView.subtitle.text = @"";
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{ [SDAPOverlay dismiss]; });
	});
}

+ (void)dismiss {
	dispatch_async(dispatch_get_main_queue(), ^{
		[self teardownTimer];
		if (!sWindow) return;
		UIWindow *w = sWindow;
		sWindow = nil;
		sView = nil;
		[UIView animateWithDuration:0.18 animations:^{ w.alpha = 0.0; } completion:^(__unused BOOL done) {
			w.hidden = YES;
			w.rootViewController = nil;
		}];
	});
}

@end

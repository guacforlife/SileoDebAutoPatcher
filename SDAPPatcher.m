// SileoDebAutoPatcher — the RootHide Patcher half.
//
// Patcher 2.1.4 is pure SwiftUI: the binary defines four ObjC classes, none of
// them a view controller, and "Convert .deb" is an anonymous closure inside
// ContentView.body. There is nothing to %hook. Two things save us:
//
//   * DerootifierApp's .onOpenURL posts a plain NSNotification named
//     "patcherFileOpen" with the staged deb URL as its object — ordinary
//     Foundation, and the cleanest entry point in the app.
//   * SwiftUI publishes the button as an AccessibilityNode carrying the label
//     "Convert .deb", and -accessibilityActivate runs its action. Verified on
//     device before this file was written: activate returned YES and the real
//     conversion started.
//
// Activating the real button (rather than shelling out to patch.sh ourselves)
// means whatever the user has done to the three option toggles during the
// countdown is respected for free.

#import "SDAPCommon.h"
#import "SDAPOverlay.h"
#import <notify.h>
#import <objc/runtime.h>

void SDAPPatcherHandleAlert(UIAlertController *ac);

static BOOL sCancelled = NO;
static char kAlertHandledKey;

#pragma mark - Activation

static void SDAPPatcherTryActivate(int attempt) {
	if (sCancelled) return;

	id el = SDAPFindAXElement(@"convert .deb", @[@"convert", @".deb"]);
	if (!el) {
		// Cold launch: .onOpenURL fires before ContentView has rendered, so the
		// button may genuinely not exist yet. Poll, then give up — never act blind.
		if (attempt < 24) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{ SDAPPatcherTryActivate(attempt + 1); });
			return;
		}
		SDAPEvent(@"PATCHER_AXFIND", @"FAIL", @"no \"Convert .deb\" element after %d attempts", attempt);
		[SDAPOverlay flashMessage:@"Convert button not found"];
		return;
	}

	SDAPEvent(@"PATCHER_AXFIND", @"OK", @"%@", NSStringFromClass([el class]));
	[SDAPOverlay dismiss];

	BOOL ok = NO;
	@try {
		if ([el respondsToSelector:@selector(accessibilityActivate)]) ok = [el accessibilityActivate];
		else SDAPEvent(@"PATCHER_ACTIVATE", @"FAIL", @"element does not respond to accessibilityActivate");
	} @catch (NSException *e) {
		SDAPEvent(@"PATCHER_ACTIVATE", @"FAIL", @"threw %@: %@", e.name, e.reason);
		return;
	}
	SDAPEvent(@"PATCHER_ACTIVATE", ok ? @"OK" : @"FAIL", @"accessibilityActivate=%d", (int)ok);
}

#pragma mark - Inbound deb

static void SDAPPatcherFileOpen(NSNotification *note) {
	NSURL *url = [note.object isKindOfClass:[NSURL class]] ? (NSURL *)note.object : nil;
	SDAPEvent(@"PATCHER_INBOX", @"OK", @"%@", url.lastPathComponent ?: @"(no url)");

	// A fresh deb always resets the run state, so a previous run that stalled
	// can never wedge the next one.
	sCancelled = NO;

	if (!SDAPEnabled()) { SDAPEvent(@"PATCHER_COUNTDOWN", @"SKIP", @"master switch off"); return; }
	if (!SDAPPrefBool(@"autoConvert", YES)) { SDAPEvent(@"PATCHER_COUNTDOWN", @"SKIP", @"autoConvert off"); return; }

	double delay = SDAPPrefDouble(@"convertDelay", 1.5);
	if (delay < 0) delay = 0;
	if (delay > 30) delay = 30;

	SDAPEvent(@"PATCHER_COUNTDOWN", @"OK", @"%.1fs", delay);
	[SDAPOverlay showCountdown:delay onCancel:^{ sCancelled = YES; }];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{ SDAPPatcherTryActivate(0); });
}

#pragma mark - Alerts

// Patcher's "Converting..." alert has ZERO actions, so nothing on screen can
// dismiss it — if one is ever left behind the app is stuck until force-quit.
// The source dismisses it before presenting Done, so this should never fire;
// it is cheap insurance against that ordering changing.
static void SDAPPatcherDismissOrphanAlert(void) {
	@try {
		UIViewController *top = nil;
		for (UIWindow *w in [UIApplication sharedApplication].windows) {
			if (!w.rootViewController) continue;
			UIViewController *v = w.rootViewController;
			while (v.presentedViewController) v = v.presentedViewController;
			if (v) top = v;
		}
		if (![top isKindOfClass:[UIAlertController class]]) return;
		UIAlertController *ac = (UIAlertController *)top;
		if (ac.actions.count > 0) return;
		SDAPEvent(@"PATCHER_ORPHAN_ALERT", @"OK", @"dismissing action-less \"%@\"", ac.title ?: @"");
		[ac dismissViewControllerAnimated:NO completion:nil];
	} @catch (NSException *e) {
		SDAPEvent(@"PATCHER_ORPHAN_ALERT", @"FAIL", @"%@: %@", e.name, e.reason);
	}
}

// Called from the shared presentViewController: hook. Alert-style only —
// action sheets are refused upstream.
void SDAPPatcherHandleAlert(UIAlertController *ac) {
	NSString *title = ac.title ?: @"";

	// "Converting..." carries no actions, so SDAPAlertIsFireable already refuses
	// it upstream; this only records that the conversion started.
	if ([title isEqualToString:@"Converting..."]) {
		SDAPEvent(@"PATCHER_CONVERTING", @"OK", @"");
		return;
	}
	if ([title hasPrefix:@"Error("]) {
		SDAPEvent(@"PATCHER_DONE_ALERT", @"FAIL", @"%@ :: %@", title, ac.message ?: @"");
		return;
	}
	if (![title isEqualToString:@"Done"]) return;
	if (!SDAPAlertIsFireable(ac)) { SDAPEvent(@"PATCHER_DONE_ALERT", @"SKIP", @"not a fireable alert"); return; }

	if (objc_getAssociatedObject(ac, &kAlertHandledKey)) return;
	objc_setAssociatedObject(ac, &kAlertHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	// The message is the entire stdout of patch.sh, including any
	// *****fixed-paths-warnning***** block. Capture it before we dismiss —
	// otherwise auto-advancing would throw away the one report of what changed.
	SDAPEvent(@"PATCHER_DONE_ALERT", @"OK", @"%@", ac.message ?: @"");

	if (!SDAPEnabled() || !SDAPPrefBool(@"autoShareToSileo", YES)) {
		SDAPEvent(@"PATCHER_SHARE_FIRE", @"SKIP", @"pref off");
		return;
	}

	UIAlertAction *share = nil;
	for (UIAlertAction *a in ac.actions) {
		NSString *t = a.title ?: @"";
		// The literal label is "->Sileo"; match loosely but never on "->Share".
		if ([t rangeOfString:@"Sileo" options:NSCaseInsensitiveSearch].location != NSNotFound) { share = a; break; }
	}
	if (!share) {
		SDAPEvent(@"PATCHER_SHARE_FIRE", @"FAIL", @"no ->Sileo action on the Done alert");
		return;
	}

	double d = SDAPPrefDouble(@"shareDelay", 1.5);
	if (d < 0) d = 0;
	if (d > 30) d = 30;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			// If the user picked ->Share (or dismissed) during the delay the
			// alert is already gone — never fire on top of their choice.
			if (!ac.viewIfLoaded.window || !ac.presentingViewController) {
				SDAPEvent(@"PATCHER_SHARE_FIRE", @"SKIP", @"alert already dismissed by the user");
				return;
			}
			// Dismiss BEFORE invoking: unlike Sileo's Convert action, this
			// handler only calls ShareFileToApp and never dismisses itself, so
			// firing it first would leave a live modal behind in Patcher.
			[ac dismissViewControllerAnimated:NO completion:^{
				BOOL ok = SDAPFireAlertAction(share);
				SDAPEvent(@"PATCHER_SHARE_FIRE", ok ? @"OK" : @"FAIL", @"%@", share.title ?: @"");
				SDAPPatcherDismissOrphanAlert();
			}];
		});
}

#pragma mark - Init

__attribute__((constructor))
static void SDAPPatcherInit(void) {
	@autoreleasepool {
		if (![SDAPBundleID() isEqualToString:SDAP_BID_PATCHER]) return;
		if (SDAPKillSwitchPresent()) { SDAPEvent(@"PATCHER_LAUNCH", @"SKIP", @"kill switch present"); return; }

		// Never leave the pill on screen if the app goes away mid-countdown.
		[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
			object:nil
			queue:[NSOperationQueue mainQueue]
			usingBlock:^(__unused NSNotification *n) { sCancelled = YES; [SDAPOverlay dismiss]; }];

		[[NSNotificationCenter defaultCenter] addObserverForName:@"patcherFileOpen"
			object:nil
			queue:[NSOperationQueue mainQueue]
			usingBlock:^(NSNotification *note) {
				@try { SDAPPatcherFileOpen(note); }
				@catch (NSException *e) { SDAPEvent(@"PATCHER_INBOX", @"FAIL", @"%@: %@", e.name, e.reason); }
			}];

		static int dumpToken;
		notify_register_dispatch(SDAP_NOTIF_DUMP, &dumpToken, dispatch_get_main_queue(),
			^(__unused int t) { SDAPDumpAXTree(); });

		SDAPEvent(@"PATCHER_LAUNCH", @"OK", @"SileoDebAutoPatcher injected");
	}
}

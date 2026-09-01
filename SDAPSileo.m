// SileoDebAutoPatcher — the Sileo half.
//
// Sileo 2.5.1-12 is Swift, but every UI class is a real ObjC class and the two
// things we need are ordinary ObjC surfaces:
//
//   * the "Not Updated" prompt is a genuine UIAlertController whose title and
//     "Convert" action title are hardcoded English (no .lproj entry), so
//     matching them is locale-safe
//   * PackageViewController.downloadButton is a UIButton subclass
//
// Nothing here depends on a Swift mangled class name or a private-context hash:
// the delegate's openURL: method is swizzled on whatever class the live
// delegate actually is, and view controllers are recognised by class-name
// substring. A Sileo update can't silently break that into a wrong action —
// worst case a match fails and the flow stops, which is the safe direction.

#import "SDAPCommon.h"
#import <notify.h>
#import <objc/runtime.h>

void SDAPSileoHandleAlert(UIAlertController *ac);
void SDAPSileoViewControllerShown(UIViewController *vc);
void SDAPSileoDelegateSet(id delegate);

static char kAlertHandledKey;
static char kVCTappedKey;

// The auto-Get is armed only by a deb actually arriving, never by browsing.
static NSDate *sArmedUntil = nil;

static BOOL SDAPSileoArmed(void) {
	return sArmedUntil != nil && [sArmedUntil timeIntervalSinceNow] > 0;
}

#pragma mark - openURL swizzle

static BOOL (*sOrigOpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *) = NULL;

static BOOL SDAPSileoOpenURL(id self, SEL _cmd, UIApplication *app, NSURL *url, NSDictionary *options) {
	@try {
		if (url.isFileURL && [url.pathExtension caseInsensitiveCompare:@"deb"] == NSOrderedSame) {
			sArmedUntil = [NSDate dateWithTimeIntervalSinceNow:20.0];
			SDAPEvent(@"SILEO_OPENURL", @"OK", @"%@", url.lastPathComponent ?: @"");
		}
	} @catch (NSException *e) {
		SDAPEvent(@"SILEO_OPENURL", @"FAIL", @"%@: %@", e.name, e.reason);
	}
	if (sOrigOpenURL) return sOrigOpenURL(self, _cmd, app, url, options);
	return NO;
}

// Swizzle on the delegate's ACTUAL class rather than hooking the mangled Swift
// name _TtC5Sileo16SileoAppDelegate — one less thing to break on an update.
void SDAPSileoDelegateSet(id delegate) {
	static BOOL done = NO;
	if (done || !delegate) return;
	if (![SDAPBundleID() isEqualToString:SDAP_BID_SILEO]) return;

	Class cls = object_getClass(delegate);
	SEL sel = @selector(application:openURL:options:);
	Method m = class_getInstanceMethod(cls, sel);
	if (!m) {
		SDAPEvent(@"SILEO_SWIZZLE", @"FAIL", @"%@ has no application:openURL:options:", NSStringFromClass(cls));
		return;
	}
	sOrigOpenURL = (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))method_getImplementation(m);
	method_setImplementation(m, (IMP)SDAPSileoOpenURL);
	done = YES;
	SDAPEvent(@"SILEO_SWIZZLE", @"OK", @"%@", NSStringFromClass(cls));
}

#pragma mark - The Get button

// Whitelist, not blacklist. Titles come from Sileo's own Localizable.strings so
// this stays correct in any language. Anything unrecognised is refused and
// logged rather than guessed at — "Modify" opens an action sheet containing
// Uninstall, and that must never be reachable from an automatic tap.
static BOOL SDAPTitleIsInstallAction(NSString *title) {
	if (title.length == 0) return NO;
	NSBundle *mb = [NSBundle mainBundle];
	NSArray *keys = @[@"Package_Get_Action", @"Package_Queue_Action", @"Package_Upgrade_Action"];
	NSArray *fallbacks = @[@"Get", @"Queue", @"Upgrade"];
	for (NSUInteger i = 0; i < keys.count; i++) {
		NSString *localized = [mb localizedStringForKey:keys[i] value:fallbacks[i] table:@"Localizable"];
		if ([title caseInsensitiveCompare:localized] == NSOrderedSame) return YES;
		if ([title caseInsensitiveCompare:fallbacks[i]] == NSOrderedSame) return YES;
	}
	return NO;
}

// Ask the runtime, never KVC.
//
// PackageViewController is a Swift class. `downloadButton` happens to be an
// @IBOutlet, so it IS exposed to the ObjC runtime today — but if a Sileo update
// renames or un-outlets it, valueForKey: lands in valueForUndefinedKey: and
// raises, and an ObjC exception raised beneath a Swift frame cannot be unwound:
// the @try/@catch below would NOT catch it and Sileo would die with
// EXC_BAD_ACCESS inside _Unwind_RaiseException. respondsToSelector: answers the
// same question with no exception in the picture, so a miss quietly falls
// through to the view-tree walk instead of taking the app down.
static UIButton *SDAPFindDownloadButton(UIViewController *vc) {
	id b = nil;
	SEL sel = @selector(downloadButton);
	if ([vc respondsToSelector:sel]) {
		#pragma clang diagnostic push
		#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
		b = [vc performSelector:sel];
		#pragma clang diagnostic pop
	}
	if ([b isKindOfClass:[UIButton class]]) return (UIButton *)b;

	// Fallback: bounded walk for the PackageQueueButton in the view tree.
	NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view ?: (id)[NSNull null]];
	int budget = 3000;
	while (stack.count > 0 && budget-- > 0) {
		id node = stack.lastObject;
		[stack removeLastObject];
		if (![node isKindOfClass:[UIView class]]) continue;
		UIView *v = (UIView *)node;
		if ([NSStringFromClass([v class]) rangeOfString:@"PackageQueueButton"].location != NSNotFound
		    && [v isKindOfClass:[UIButton class]]) {
			return (UIButton *)v;
		}
		for (UIView *sub in v.subviews) [stack addObject:sub];
	}
	return nil;
}

// Tapping Get only queues the package and raises Sileo's collapsed popup BAR;
// the Confirm button lives in the expanded popup. Sileo's own code opens it
// with TabBarController.presentPopupController(), which is Swift-only — but
// that in turn calls LNPopupController's -openPopupAnimated:completion:, and
// LNPopupController is Objective-C, so that selector is reachable.
//
// This is the last thing SileoDebAutoPatcher does. Confirm is never touched.
static UITabBarController *SDAPFindTabBarController(void) {
	@try {
		for (UIWindow *w in [UIApplication sharedApplication].windows) {
			UIViewController *r = w.rootViewController;
			if ([r isKindOfClass:[UITabBarController class]]) return (UITabBarController *)r;
		}
	} @catch (__unused NSException *e) {}
	return nil;
}

// The deb handoff presents the package page MODALLY — AppDelegate wraps a
// PackageViewController with isPresentedModally = true in a UINavigationController
// and presents it (Sileo/AppDelegate.swift, the url.pathExtension == "deb" branch).
// LNPopupController's popup belongs to the tab bar controller UNDERNEATH that
// modal, so expanding it while the modal is still up leaves the queue behind a
// sheet: on screen by every programmatic measure, but Confirm is not reachable.
//
// Sileo normally takes the modal down itself — PackageViewController observes
// PackageQueueButton.actionPerformedNotification and calls dismissImmediately —
// but that is asynchronous and animated, so wait for it rather than race it.
static UIViewController *SDAPTopModalPackageVC(void) {
	@try {
		UITabBarController *tbc = SDAPFindTabBarController();
		UIViewController *presented = tbc.presentedViewController;
		if (!presented) return nil;
		// Never touch anything that has something else on top of it (an alert,
		// a share sheet) — that is someone else's business.
		if (presented.presentedViewController) return nil;
		UIViewController *inner = presented;
		if ([inner isKindOfClass:[UINavigationController class]]) {
			UIViewController *top = [(UINavigationController *)inner topViewController];
			if (top) inner = top;
		}
		if ([NSStringFromClass([inner class]) rangeOfString:@"PackageViewController"].location == NSNotFound) return nil;
		return presented;   // dismiss the presented controller, not the inner one
	} @catch (__unused NSException *e) { return nil; }
}

// Bumped on every Get tap. The retry chain below runs on the main queue, which
// stalls while Sileo is backgrounded during the Patcher leg — without this, a
// chain started by the first tap wakes up minutes later and reports on a run
// that has already moved on.
static int sQueueOpenGen = 0;

// Unwrap the popup content down to the controller the user is actually looking
// at, and report whether it is the queue and whether it is on screen.
static UIViewController *SDAPQueueContentVC(id content) {
	UIViewController *c = (UIViewController *)content;
	if ([c isKindOfClass:[UINavigationController class]]) {
		UIViewController *top = [(UINavigationController *)c topViewController];
		if (top) c = top;
	}
	return c;
}

// LNPopupController's presentation state, for the log. Measured on the live app
// (harness/popup-state.js): 1 = popup BAR up, content collapsed; 3 = open. The
// numbering has changed between LNPopupController releases, so it is recorded
// but never used to decide anything.
static NSInteger SDAPPopupState(UITabBarController *tbc) {
	SEL sel = @selector(popupPresentationState);
	if (!tbc || ![tbc respondsToSelector:sel]) return -1;
	@try {
		NSInteger (*fn)(id, SEL) = (NSInteger (*)(id, SEL))[tbc methodForSelector:sel];
		return fn(tbc, sel);
	} @catch (__unused NSException *e) { return -1; }
}

// THE trap this tweak fell into: when the popup is COLLAPSED — the "Queued 1
// package" bar — its content view controller is still installed and its view is
// still in the window, just squashed to ZERO height and parked below the fold.
// So "the view is in a window" reports a collapsed bar as open, the tweak
// concludes there is nothing to do, and the queue never appears.
//
// Measured on device with harness/popup-state.js:
//   collapsed  content.view frame (0 0; 430 0)     popupBar y=785 (visible)
//   open       content.view frame (0 0; 430 932)   popupBar y=-64 (off screen)
//
// Height against the window is therefore the honest test, and unlike the state
// enum it cannot be renumbered out from under us.
static BOOL SDAPQueueIsOnScreen(id content) {
	@try {
		UIViewController *c = SDAPQueueContentVC(content);
		NSString *cls = NSStringFromClass([c class]);
		if ([cls rangeOfString:@"DownloadsTableViewController"].location == NSNotFound) return NO;
		UIView *v = c.viewIfLoaded;
		if (!v || !v.window) return NO;
		CGFloat winH = v.window.bounds.size.height;
		if (winH <= 0) return NO;
		return v.bounds.size.height >= winH * 0.5;
	} @catch (__unused NSException *e) { return NO; }
}

static void SDAPSileoReportQueueShown(id content) {
	UIViewController *c = SDAPQueueContentVC(content);
	NSString *cls = NSStringFromClass([c class]);
	CGFloat h = c.viewIfLoaded ? c.viewIfLoaded.bounds.size.height : -1;
	BOOL expanded = SDAPQueueIsOnScreen(content);
	// Being in a window is not the same as being the thing aj is looking at: if
	// the modal package page is still up, the queue is behind it and Confirm
	// cannot be tapped. That is a failure, not a pass.
	BOOL covered = (SDAPTopModalPackageVC() != nil);
	SDAPEvent(@"SILEO_QUEUE_SHOWN", (expanded && !covered) ? @"OK" : @"FAIL",
		@"%@ expanded=%d h=%.0f state=%ld covered=%d",
		cls, (int)expanded, h, (long)SDAPPopupState(SDAPFindTabBarController()), (int)covered);
}

static void SDAPSileoOpenQueue(int attempt, int generation) {
	if (generation != sQueueOpenGen) return;
	UITabBarController *tbc = SDAPFindTabBarController();
	SEL contentSel = @selector(popupContentViewController);
	SEL openSel = @selector(openPopupAnimated:completion:);

	id content = nil;
	@try {
		if (tbc && [tbc respondsToSelector:contentSel]) {
			#pragma clang diagnostic push
			#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
			content = [tbc performSelector:contentSel];
			#pragma clang diagnostic pop
		}
	} @catch (__unused NSException *e) { content = nil; }

	if (!content) {
		// The popup bar takes a moment to rise after the queue accepts.
		if (attempt < 16) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{ SDAPSileoOpenQueue(attempt + 1, generation); });
			return;
		}
		SDAPEvent(@"SILEO_QUEUE_OPEN", @"SKIP", @"no popup bar appeared after %d attempts", attempt);
		return;
	}

	if (![tbc respondsToSelector:openSel]) {
		SDAPEvent(@"SILEO_QUEUE_OPEN", @"FAIL", @"no openPopupAnimated:completion:");
		return;
	}

	// Sileo sometimes opens the queue itself when a package is added. Asking
	// LNPopupController to open an already-open popup is a no-op whose
	// completion never fires, so check the state before asking — otherwise we
	// retry eight times and then report failure at a screen that is already up.
	if (SDAPQueueIsOnScreen(content)) {
		SDAPEvent(@"SILEO_QUEUE_OPEN", @"OK", @"already open (%@)", NSStringFromClass([content class]));
		SDAPSileoReportQueueShown(content);
		return;
	}

	// Otherwise "the call did not throw" proves nothing — LNPopupController
	// ignores an open issued mid-transition and returns normally. Only the
	// completion firing, or the queue being on screen, counts.
	NSString *contentClass = NSStringFromClass([content class]);
	__block BOOL opened = NO;
	@try {
		typedef void (*SDAPOpenPopup)(id, SEL, BOOL, void (^)(void));
		SDAPOpenPopup fn = (SDAPOpenPopup)[tbc methodForSelector:openSel];
		fn(tbc, openSel, YES, ^{
			if (opened) return;
			opened = YES;
			SDAPEvent(@"SILEO_QUEUE_OPEN", @"OK", @"%@", contentClass);
			// Report arrival from the state, not from viewDidAppear: — UIKit
			// skips that callback when the content controller never went
			// through an appearance transition.
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{ SDAPSileoReportQueueShown(content); });
		});
	} @catch (NSException *e) {
		SDAPEvent(@"SILEO_QUEUE_OPEN", @"FAIL", @"threw %@: %@", e.name, e.reason);
		return;
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			if (opened || generation != sQueueOpenGen) return;
			// The completion may simply never fire if something else opened the
			// popup in the meantime — believe the screen, not the callback.
			if (SDAPQueueIsOnScreen(content)) {
				opened = YES;
				SDAPEvent(@"SILEO_QUEUE_OPEN", @"OK", @"opened without a completion callback");
				SDAPSileoReportQueueShown(content);
				return;
			}
			if (attempt < 8) { SDAPSileoOpenQueue(attempt + 1, generation); return; }
			SDAPEvent(@"SILEO_QUEUE_OPEN", @"FAIL", @"popup never finished opening after %d attempts", attempt);
		});
}

// Step between the Get tap and the queue: make sure the modal package page has
// gone, so the popup expands onto the screen rather than behind a sheet.
static void SDAPSileoClearModalThenOpenQueue(int attempt, int generation) {
	if (generation != sQueueOpenGen) return;

	UIViewController *modal = SDAPTopModalPackageVC();
	if (!modal) {
		if (attempt > 0) SDAPEvent(@"SILEO_MODAL_CLEAR", @"OK", @"Sileo dismissed it after %d polls", attempt);
		SDAPSileoOpenQueue(0, generation);
		return;
	}

	// 2s is far longer than the dismiss animation; anything past that means the
	// notification never reached the page (it only self-dismisses when it was
	// opened modally in the first place).
	if (attempt < 8) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{ SDAPSileoClearModalThenOpenQueue(attempt + 1, generation); });
		return;
	}

	// Safe to take down ourselves: we are inside an armed run, on the very page
	// we just tapped Get on, and it has nothing presented on top of it.
	SDAPEvent(@"SILEO_MODAL_CLEAR", @"OK", @"dismissing %@ ourselves", NSStringFromClass([modal class]));
	@try {
		[modal dismissViewControllerAnimated:YES completion:^{
			SDAPSileoOpenQueue(0, generation);
		}];
	} @catch (NSException *e) {
		SDAPEvent(@"SILEO_MODAL_CLEAR", @"FAIL", @"threw %@: %@", e.name, e.reason);
		SDAPSileoOpenQueue(0, generation);
	}
}

static void SDAPSileoTapGet(UIViewController *vc) {
	UIButton *btn = SDAPFindDownloadButton(vc);
	if (!btn) { SDAPEvent(@"SILEO_GET_TAP", @"FAIL", @"downloadButton not found"); return; }

	// Settle: tapping mid-transition makes UIKit throw
	// UIViewControllerHierarchyInconsistency.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			NSString *title = [btn titleForState:UIControlStateNormal] ?: btn.titleLabel.text ?: btn.accessibilityLabel;
			if (!SDAPTitleIsInstallAction(title)) {
				SDAPEvent(@"SILEO_GET_TAP", @"SKIP", @"button reads \"%@\" — not an install action", title ?: @"");
				return;
			}
			if (!btn.window || btn.isHidden || btn.alpha < 0.1 || !btn.isEnabled) {
				SDAPEvent(@"SILEO_GET_TAP", @"SKIP", @"button not tappable when the tap fired");
				return;
			}
			@try {
				if (btn.allTargets.count > 0) {
					[btn sendActionsForControlEvents:UIControlEventTouchUpInside];
				} else if ([btn respondsToSelector:@selector(buttonTapped:)]) {
					// PackageQueueButton's @objc -buttonTapped: takes Any? and tolerates nil.
					#pragma clang diagnostic push
					#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
					[btn performSelector:@selector(buttonTapped:) withObject:nil];
					#pragma clang diagnostic pop
				} else {
					SDAPEvent(@"SILEO_GET_TAP", @"FAIL", @"no targets and no buttonTapped:");
					return;
				}
			} @catch (NSException *e) {
				SDAPEvent(@"SILEO_GET_TAP", @"FAIL", @"threw %@: %@", e.name, e.reason);
				return;
			}
			SDAPEvent(@"SILEO_GET_TAP", @"OK", @"%@", title);
			// Let the queue accept the package, then wait for the modal package
			// page to go before asking the popup to expand. The wait is a poll
			// rather than a fixed delay, so this is both shorter and safer than
			// guessing at the dismiss animation.
			int gen = ++sQueueOpenGen;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{ SDAPSileoClearModalThenOpenQueue(0, gen); });
		});
}

// Called from BOTH the viewDidAppear: hook and the presentViewController: hook.
// Two entry points because viewDidAppear: only reaches us if Sileo's Swift
// override calls super, whereas the presentation hook always fires — the deb
// handoff presents the package page inside a UINavigationController modally.
// The per-instance gate makes the overlap harmless.
void SDAPSileoViewControllerShown(UIViewController *vc) {
	if ([vc isKindOfClass:[UINavigationController class]]) {
		UIViewController *top = [(UINavigationController *)vc topViewController];
		if (top) vc = top; else return;
	}
	NSString *cls = NSStringFromClass([vc class]);

	// The queue's view appears as soon as LNPopupController installs it as popup
	// content — which happens while the popup is still the COLLAPSED bar. So this
	// is informational only and must NOT claim the finish line: SILEO_QUEUE_SHOWN
	// is emitted solely by SDAPSileoReportQueueShown, which measures the expansion.
	// (A weak OK here is precisely what let a collapsed-bar bug pass the harness.)
	if ([cls rangeOfString:@"DownloadsTableViewController"].location != NSNotFound) {
		SDAPEvent(@"SILEO_QUEUE_VC", @"OK", @"%@", cls);
		return;
	}
	if ([cls rangeOfString:@"PackageViewController"].location == NSNotFound) return;

	SDAPEvent(@"SILEO_PKGVC", @"OK", @"%@", cls);

	if (!SDAPEnabled() || !SDAPPrefBool(@"autoGet", YES)) { SDAPEvent(@"SILEO_GET_TAP", @"SKIP", @"pref off"); return; }
	if (!SDAPSileoArmed()) { SDAPEvent(@"SILEO_GET_TAP", @"SKIP", @"not armed (ordinary browsing)"); return; }
	if (objc_getAssociatedObject(vc, &kVCTappedKey)) return;
	objc_setAssociatedObject(vc, &kVCTappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	sArmedUntil = nil;   // one deb, one tap

	SDAPSileoTapGet(vc);
}

#pragma mark - Alerts

void SDAPSileoHandleAlert(UIAlertController *ac) {
	NSString *title = ac.title ?: @"";
	if (![title isEqualToString:@"Not Updated"]) return;
	if (!SDAPAlertIsFireable(ac)) { SDAPEvent(@"SILEO_ALERT", @"SKIP", @"not a fireable alert"); return; }

	if (objc_getAssociatedObject(ac, &kAlertHandledKey)) return;
	objc_setAssociatedObject(ac, &kAlertHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	SDAPEvent(@"SILEO_ALERT", @"OK", @"Not Updated :: %@", ac.message ?: @"");

	if (!SDAPEnabled() || !SDAPPrefBool(@"autoConvertPrompt", YES)) {
		SDAPEvent(@"SILEO_CONVERT_FIRE", @"SKIP", @"pref off");
		return;
	}

	UIAlertAction *convert = nil;
	for (UIAlertAction *a in ac.actions) {
		if (a.style == UIAlertActionStyleCancel) continue;      // never fire a Cancel
		// Exactly "Convert". "Get Patcher" (Patcher not installed) is ignored —
		// it only navigates to the Patcher's own package page.
		if ([(a.title ?: @"") isEqualToString:@"Convert"]) { convert = a; break; }
	}
	if (!convert) {
		SDAPEvent(@"SILEO_CONVERT_FIRE", @"SKIP", @"no Convert action (is the Patcher installed?)");
		return;
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			// The alert must actually be on screen: this action's whole payload
			// lives inside alert.dismiss(animated:completion:), and a dismissal
			// on a never-presented controller does not reliably run it.
			if (!ac.viewIfLoaded.window) {
				SDAPEvent(@"SILEO_CONVERT_FIRE", @"SKIP", @"alert gone before the fire");
				return;
			}
			BOOL ok = SDAPFireAlertAction(convert);
			SDAPEvent(@"SILEO_CONVERT_FIRE", ok ? @"OK" : @"FAIL", @"Convert");
		});
}

#pragma mark - Init

__attribute__((constructor))
static void SDAPSileoInit(void) {
	@autoreleasepool {
		if (![SDAPBundleID() isEqualToString:SDAP_BID_SILEO]) return;
		if (SDAPKillSwitchPresent()) { SDAPEvent(@"SILEO_LAUNCH", @"SKIP", @"kill switch present"); return; }

		// Harness: arm the auto-Get for one package page without a deb handoff,
		// so a full run can be triggered from the Mac with no taps.
		static int armToken;
		notify_register_dispatch(SDAP_NOTIF_ARM, &armToken, dispatch_get_main_queue(), ^(__unused int t) {
			sArmedUntil = [NSDate dateWithTimeIntervalSinceNow:60.0];
			SDAPEvent(@"HARNESS_ARM", @"OK", @"auto-Get armed for 60s");
		});

		static int dumpToken;
		notify_register_dispatch(SDAP_NOTIF_DUMP, &dumpToken, dispatch_get_main_queue(),
			^(__unused int t) { SDAPDumpAXTree(); });

		SDAPEvent(@"SILEO_LAUNCH", @"OK", @"SileoDebAutoPatcher injected");
	}
}

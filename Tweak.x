// SileoDebAutoPatcher — the only Logos file.
//
// Every hook lives here so that the two halves of the flow never collide on the
// same selector (Logos groups are file-scoped, and both sides need
// -[UIViewController presentViewController:animated:completion:]). The
// per-app logic lives in SDAPSileo.m / SDAPPatcher.m as plain ObjC.
//
// Note what is deliberately NOT hooked: nothing on
// _TtC5Sileo28DownloadsTableViewController, -confirmQueued: or confirmButton.
// The flow always stops at the queue confirm screen, and the absence of those
// hooks is what guarantees it.

#import "SDAPCommon.h"

extern void SDAPSileoHandleAlert(UIAlertController *ac);
extern void SDAPSileoViewControllerShown(UIViewController *vc);
extern void SDAPSileoDelegateSet(id delegate);
extern void SDAPPatcherHandleAlert(UIAlertController *ac);

static BOOL sIsSileo = NO;
static BOOL sIsPatcher = NO;

%group SDAPHooks

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
	// Always present first. Sileo's Convert action does its work inside
	// alert.dismiss(animated:completion:), which is not reliably invoked on a
	// controller that was never presented — suppressing the alert would turn
	// the whole flow into a silent dead end.
	%orig;

	@try {
		if ([vc isKindOfClass:[UIAlertController class]]) {
			if (sIsSileo) SDAPSileoHandleAlert((UIAlertController *)vc);
			else if (sIsPatcher) SDAPPatcherHandleAlert((UIAlertController *)vc);
		} else if (sIsSileo && vc) {
			SDAPSileoViewControllerShown(vc);
		}
	} @catch (NSException *e) {
		SDAPEvent(@"PRESENT_HOOK", @"FAIL", @"%@: %@", e.name, e.reason);
	}
}

- (void)viewDidAppear:(BOOL)animated {
	%orig;
	if (!sIsSileo) return;
	@try {
		SDAPSileoViewControllerShown(self);
	} @catch (NSException *e) {
		SDAPEvent(@"APPEAR_HOOK", @"FAIL", @"%@: %@", e.name, e.reason);
	}
}

%end

%hook UIApplication

- (void)setDelegate:(id)delegate {
	%orig;
	if (!sIsSileo) return;
	@try {
		SDAPSileoDelegateSet(delegate);
	} @catch (NSException *e) {
		SDAPEvent(@"DELEGATE_HOOK", @"FAIL", @"%@: %@", e.name, e.reason);
	}
}

%end

%end // group SDAPHooks

%ctor {
	@autoreleasepool {
		NSString *bid = SDAPBundleID();
		sIsSileo = [bid isEqualToString:SDAP_BID_SILEO];
		sIsPatcher = [bid isEqualToString:SDAP_BID_PATCHER];
		if (!sIsSileo && !sIsPatcher) return;   // belt to the filter plist's braces
		if (SDAPKillSwitchPresent()) return;
		%init(SDAPHooks);
	}
}

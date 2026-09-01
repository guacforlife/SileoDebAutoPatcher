// SileoDebAutoPatcher — shared prefs access and the structured event log.
//
// The event log is the substrate the harness reads. One line per event:
//
//     <unix_ms>|<APP>|<EVENT>|<STATUS>|<detail>
//
// Both Sileo and the Patcher are non-sandboxed jbroot apps running as mobile,
// so a literal /var/tmp path from either lands in the REAL /var/tmp — read it
// from SSH at /rootfs/private/var/tmp/.debautopatcher.log.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define SDAP_SUITE        @"com.guacforlife.debautopatcher"
#define SDAP_LOG_PATH     @"/var/tmp/.debautopatcher.log"

#define SDAP_BID_SILEO    @"org.coolstar.SileoStore"
#define SDAP_BID_PATCHER  @"com.roothide.patcher"

// Darwin notifications (payload-free; they cross every sandbox)
#define SDAP_NOTIF_ARM    "com.guacforlife.debautopatcher.harness.arm"
#define SDAP_NOTIF_DUMP   "com.guacforlife.debautopatcher.probe.dump"

#ifdef __cplusplus
extern "C" {
#endif

NSString *SDAPBundleID(void);
NSString *SDAPAppTag(void);              // SILEO / PATCHER / OTHER

BOOL   SDAPPrefBool(NSString *key, BOOL def);
double SDAPPrefDouble(NSString *key, double def);
BOOL   SDAPEnabled(void);                // master switch

// Append one event line. `fmt` may be nil.
void SDAPEvent(NSString *event, NSString *status, NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

// Fire a UIAlertAction's handler block (the private `handler` KVC key).
// Returns NO if the action has no handler or the call threw.
BOOL SDAPFireAlertAction(UIAlertAction *action);

// Nothing is ever auto-fired unless this holds: alert style (never an action
// sheet — Sileo's Modify sheet contains Uninstall) and at least one action
// (Patcher's "Converting..." alert has none and must never be touched).
BOOL SDAPAlertIsFireable(UIViewController *vc);

// Emergency stop that needs no cfprefsd and no working Settings pane:
//     ssh <device> "touch /var/tmp/.debautopatcher.off"
// Checked once per process at load.
BOOL SDAPKillSwitchPresent(void);

// Depth-first walk of the accessibility tree from every window, following BOTH
// UIView.subviews and the UIAccessibilityContainer child protocol. SwiftUI
// publishes its buttons as AccessibilityNode children of the hosting view, not
// as UIViews, so a plain subviews walk finds nothing.
//
// `exact` is matched case-insensitively against the whole label first; if
// nothing matches, the first label containing every string in `allOf` wins.
id SDAPFindAXElement(NSString *exact, NSArray<NSString *> *allOf);

// Dump the whole accessibility tree to the event log (probe.dump).
void SDAPDumpAXTree(void);

#ifdef __cplusplus
}
#endif

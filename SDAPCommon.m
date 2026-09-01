#import "SDAPCommon.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

#pragma mark - Identity

NSString *SDAPBundleID(void) {
	static NSString *bid = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ bid = [[NSBundle mainBundle] bundleIdentifier] ?: @""; });
	return bid;
}

NSString *SDAPAppTag(void) {
	NSString *bid = SDAPBundleID();
	if ([bid isEqualToString:SDAP_BID_SILEO]) return @"SILEO";
	if ([bid isEqualToString:SDAP_BID_PATCHER]) return @"PATCHER";
	return @"OTHER";
}

#pragma mark - Preferences

// Read fresh every time. NSUserDefaults with a suite name works on Roothide —
// roothidehooks.dylib in cfprefsd redirects CFPrefsGetPathForTriplet into the
// jbroot, so Settings.app and these jbroot apps see the same plist. Never do
// direct plist file I/O here.
static id SDAPPrefObject(NSString *key) {
	@try {
		NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SDAP_SUITE];
		return [d objectForKey:key];
	} @catch (__unused NSException *e) {
		return nil;
	}
}

BOOL SDAPPrefBool(NSString *key, BOOL def) {
	id v = SDAPPrefObject(key);
	return v ? [v boolValue] : def;
}

double SDAPPrefDouble(NSString *key, double def) {
	id v = SDAPPrefObject(key);
	return v ? [v doubleValue] : def;
}

BOOL SDAPEnabled(void) { return SDAPPrefBool(@"enabled", YES); }

#pragma mark - Event log

static dispatch_queue_t SDAPLogQueue(void) {
	static dispatch_queue_t q;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ q = dispatch_queue_create("com.guacforlife.debautopatcher.log", DISPATCH_QUEUE_SERIAL); });
	return q;
}

void SDAPEvent(NSString *event, NSString *status, NSString *fmt, ...) {
	NSString *detail = @"";
	if (fmt) {
		va_list ap;
		va_start(ap, fmt);
		detail = [[NSString alloc] initWithFormat:fmt arguments:ap];
		va_end(ap);
	}
	// One event per line, so the harness can parse with plain awk.
	detail = [detail stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
	detail = [detail stringByReplacingOccurrencesOfString:@"\r" withString:@""];
	detail = [detail stringByReplacingOccurrencesOfString:@"|" withString:@"/"];
	if (detail.length > 4000) detail = [[detail substringToIndex:4000] stringByAppendingString:@"<truncated>"];

	unsigned long long ms = (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
	NSString *line = [NSString stringWithFormat:@"%llu|%@|%@|%@|%@\n",
		ms, SDAPAppTag(), event, status ?: @"OK", detail];

	dispatch_async(SDAPLogQueue(), ^{
		const char *path = [SDAP_LOG_PATH fileSystemRepresentation];
		int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
		if (fd < 0) return;
		NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
		write(fd, d.bytes, d.length);
		close(fd);
		// Sileo and the Patcher are both mobile, but be explicit so a stray
		// root-created file can still be appended to by either.
		chmod(path, 0644);
	});
}

#pragma mark - Alert actions

BOOL SDAPFireAlertAction(UIAlertAction *action) {
	if (!action) return NO;
	void (^handler)(UIAlertAction *) = nil;
	@try {
		// KVC is safe HERE, unlike on Sileo's Swift classes: UIAlertAction is an
		// ObjC class, so an undefined key raises through ObjC frames and this
		// @try/@catch really does catch it. See SDAPFindDownloadButton for the
		// case where it does not.
		handler = [action valueForKey:@"handler"];
	} @catch (NSException *e) {
		SDAPEvent(@"ALERT_HANDLER", @"FAIL", @"KVC threw %@: %@", e.name, e.reason);
		return NO;
	}
	if (!handler) return NO;
	@try {
		handler(action);
	} @catch (NSException *e) {
		SDAPEvent(@"ALERT_HANDLER", @"FAIL", @"handler threw %@: %@", e.name, e.reason);
		return NO;
	}
	return YES;
}

BOOL SDAPAlertIsFireable(UIViewController *vc) {
	if (![vc isKindOfClass:[UIAlertController class]]) return NO;
	UIAlertController *ac = (UIAlertController *)vc;
	if (ac.preferredStyle != UIAlertControllerStyleAlert) return NO;
	if (ac.actions.count == 0) return NO;
	return YES;
}

BOOL SDAPKillSwitchPresent(void) {
	return access("/var/tmp/.debautopatcher.off", F_OK) == 0;
}

#pragma mark - Accessibility tree

// Collect every node that carries an accessibility label. Proven against
// Patcher 2.1.4 with Frida: SwiftUI publishes "Convert .deb" as a
// SwiftUI.AccessibilityNode with the button trait, reachable only through
// accessibilityElementCount/accessibilityElementAtIndex:.
static void SDAPCollectAX(NSMutableArray *out, NSMutableArray *labels) {
	NSMutableArray *stack = [NSMutableArray array];
	@try {
		for (UIWindow *w in [UIApplication sharedApplication].windows) {
			if (w) [stack addObject:w];
		}
	} @catch (__unused NSException *e) { return; }

	int budget = 8000;
	while (stack.count > 0 && budget-- > 0) {
		id node = stack.lastObject;
		[stack removeLastObject];
		if (!node) continue;

		NSString *label = nil;
		@try {
			if ([node respondsToSelector:@selector(accessibilityLabel)]) label = [node accessibilityLabel];
		} @catch (__unused NSException *e) {}
		if (label.length > 0) {
			[out addObject:node];
			[labels addObject:label];
		}

		@try {
			if ([node respondsToSelector:@selector(accessibilityElementCount)]) {
				NSInteger n = [node accessibilityElementCount];
				if (n > 0 && n < 500) {
					for (NSInteger i = 0; i < n; i++) {
						id child = [node accessibilityElementAtIndex:i];
						if (child) [stack addObject:child];
					}
				}
			}
		} @catch (__unused NSException *e) {}

		@try {
			if ([node isKindOfClass:[UIView class]]) {
				for (UIView *sub in [(UIView *)node subviews]) {
					if (sub && !sub.isHidden && sub.alpha > 0.01) [stack addObject:sub];
				}
			}
		} @catch (__unused NSException *e) {}
	}
}

id SDAPFindAXElement(NSString *exact, NSArray<NSString *> *allOf) {
	NSMutableArray *nodes = [NSMutableArray array];
	NSMutableArray *labels = [NSMutableArray array];
	SDAPCollectAX(nodes, labels);

	NSString *wanted = exact.lowercaseString;
	for (NSUInteger i = 0; i < labels.count; i++) {
		NSString *lc = [[labels[i] lowercaseString]
			stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (wanted && [lc isEqualToString:wanted]) return nodes[i];
	}
	// Substring fallback: every fragment must be present. Requiring both
	// "convert" and ".deb" is what keeps this off the "Directly Convert Simple
	// Tweaks" toggle, which also contains "convert".
	for (NSUInteger i = 0; i < labels.count; i++) {
		NSString *lc = [labels[i] lowercaseString];
		BOOL all = YES;
		for (NSString *frag in allOf) {
			if ([lc rangeOfString:frag.lowercaseString].location == NSNotFound) { all = NO; break; }
		}
		if (all) return nodes[i];
	}
	return nil;
}

void SDAPDumpAXTree(void) {
	NSMutableArray *nodes = [NSMutableArray array];
	NSMutableArray *labels = [NSMutableArray array];
	SDAPCollectAX(nodes, labels);
	SDAPEvent(@"AX_DUMP", @"OK", @"%lu labelled nodes", (unsigned long)labels.count);
	for (NSUInteger i = 0; i < labels.count; i++) {
		unsigned long long traits = 0;
		@try {
			if ([nodes[i] respondsToSelector:@selector(accessibilityTraits)])
				traits = (unsigned long long)[nodes[i] accessibilityTraits];
		} @catch (__unused NSException *e) {}
		SDAPEvent(@"AX_NODE", @"OK", @"%@ label=\"%@\" traits=%llu",
			NSStringFromClass([nodes[i] class]), labels[i], traits);
	}
}

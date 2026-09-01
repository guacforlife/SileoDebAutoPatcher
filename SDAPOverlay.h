// A small countdown pill shown in the Patcher before the conversion fires.
//
// It lives in its OWN UIWindow sized to the pill, so touches outside it pass
// straight through to the three conversion toggles underneath — the whole point
// of the pause is that those stay usable.

#import <UIKit/UIKit.h>

@interface SDAPOverlay : NSObject

// Counts `seconds` down. Tapping the pill calls `onCancel` once and dismisses.
// Calling this again replaces any pill already on screen.
+ (void)showCountdown:(double)seconds onCancel:(void (^)(void))onCancel;

// Replace the pill's text with a transient status message, then fade out.
+ (void)flashMessage:(NSString *)message;

+ (void)dismiss;

@end

// Is the countdown pill actually ON SCREEN, or merely allocated?
// Prints a verdict, then taps it the way a finger would.
//
// Geometry is read by parsing -[UIView description] rather than calling
// -frame: CGRect returns do not marshal reliably through the Frida 17 ObjC
// bridge here, and the description string carries the same numbers.
'use strict';

function rectFromDescription(obj) {
	try {
		var d = obj.description().toString();
		// "<UIWindow: 0x...; frame = (57.5 730; 260 62); ...>"
		var m = /frame = \(([-\d.]+) ([-\d.]+); ([-\d.]+) ([-\d.]+)\)/.exec(d);
		if (!m) return null;
		return { x: +m[1], y: +m[2], w: +m[3], h: +m[4], raw: d };
	} catch (e) { return null; }
}

ObjC.schedule(ObjC.mainQueue, function () {
	var views = ObjC.chooseSync(ObjC.classes.SDAPOverlayView);
	console.log('OVERLAY_VIEWS: ' + views.length);
	if (!views.length) { console.log('VERDICT: FAIL (no SDAPOverlayView allocated)'); return; }

	var v = views[0];
	var win = v.window();
	if (!win || win.isNull()) { console.log('VERDICT: FAIL (view has no window)'); return; }

	var app = ObjC.classes.UIApplication.sharedApplication();
	var wins = app.windows(), inList = false;
	for (var i = 0; i < wins.count(); i++) {
		if (wins.objectAtIndex_(i).handle.equals(win.handle)) inList = true;
	}

	var r = rectFromDescription(win);
	var title = v.title().text();
	title = title ? title.toString() : '';
	var subtitle = v.subtitle().text();
	subtitle = subtitle ? subtitle.toString() : '';

	console.log('WINDOW_IN_APP_LIST: ' + inList);
	console.log('HIDDEN: ' + win.isHidden() + '  ALPHA: ' + win.alpha().toFixed(2) +
	            '  LEVEL: ' + win.windowLevel());
	console.log('FRAME: ' + (r ? r.x + ',' + r.y + ' ' + r.w + 'x' + r.h : 'unreadable'));
	console.log('TITLE: "' + title + '"   SUBTITLE: "' + subtitle + '"');
	console.log('GESTURES: ' + v.gestureRecognizers().count());

	var sized   = !!r && r.w > 100 && r.h > 30;      // laid out, not a zero rect
	var placed  = !!r && r.x >= 0 && r.y > 0;        // positioned on screen
	var titleOK = /Converting in \d/.test(title);
	var ok = inList && !win.isHidden() && win.alpha() > 0.5 &&
	         sized && placed && titleOK && v.gestureRecognizers().count() > 0;

	console.log('VERDICT: ' + (ok ? 'PASS' : 'FAIL') +
	            (ok ? '' : ' (inList=' + inList + ' sized=' + sized +
	                       ' placed=' + placed + ' titleOK=' + titleOK + ')'));

	// Then cancel it, by firing the gesture recogniser's own action.
	v.tapped();
	console.log('TAPPED_PILL: yes');
});

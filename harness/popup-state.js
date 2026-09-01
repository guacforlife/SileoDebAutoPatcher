// Probe: what does LNPopupController's state look like when the popup bar is
// COLLAPSED ("Queued 1 package") versus OPEN (the queue with Confirm)?
//
// SileoDebAutoPatcher's first attempt used "the popup content view controller's view is
// in a window" as the open test. That is TRUE for a collapsed bar too, so the
// tweak concluded "already open" and never expanded it. This prints the facts
// for both states so the real predicate can be chosen, not guessed.
//
// Run with Sileo showing a collapsed "Queued N packages" bar:
//   ( sleep 25; echo exit ) | ~/.frida17/bin/frida -H 127.0.0.1:27042 -p <PID> -l harness/popup-state.js

function frameOf(view) {
	// CGRect does not marshal through the Frida 17 ObjC bridge — parse the
	// description string instead (same trick as overlay-check.js).
	var d = view.description().toString();
	var m = d.match(/frame = \(([-0-9.]+) ([-0-9.]+); ([-0-9.]+) ([-0-9.]+)\)/);
	if (!m) return null;
	return { x: +m[1], y: +m[2], w: +m[3], h: +m[4] };
}

function report(tag) {
	var app = ObjC.classes.UIApplication.sharedApplication();
	var wins = app.windows();
	var tbc = null, win = null;
	for (var i = 0; i < wins.count(); i++) {
		var w = wins.objectAtIndex_(i);
		var r = w.rootViewController();
		if (r && r.isKindOfClass_(ObjC.classes.UITabBarController)) { tbc = r; win = w; break; }
	}
	if (!tbc) { console.log(tag + ' NO_TABBARCONTROLLER'); return null; }

	console.log('--- ' + tag + ' ---');
	console.log('  tbc: ' + tbc.$className);

	// The presentation-state enum: read it, don't assume the numbering (it has
	// changed between LNPopupController releases).
	if (tbc.respondsToSelector_(ObjC.selector('popupPresentationState'))) {
		console.log('  popupPresentationState: ' + tbc.popupPresentationState());
	} else {
		console.log('  popupPresentationState: SELECTOR ABSENT');
	}

	var content = tbc.respondsToSelector_(ObjC.selector('popupContentViewController'))
		? tbc.popupContentViewController() : null;
	console.log('  popupContentViewController: ' + (content ? content.$className : 'nil'));

	var winFrame = frameOf(win);
	console.log('  window frame: ' + JSON.stringify(winFrame));

	if (content) {
		var v = content.viewIfLoaded();
		console.log('  content.view inWindow: ' + (v && !v.window().isNull() ? 'YES' : 'NO'));
		if (v && !v.window().isNull()) {
			console.log('  content.view frame:  ' + JSON.stringify(frameOf(v)));
			// Position in window coordinates is what actually decides whether
			// the queue is on screen or parked below the fold.
			var sv = v.superview();
			if (sv && !sv.isNull()) console.log('  content.view.superview: ' + sv.$className + ' ' + JSON.stringify(frameOf(sv)));
		}
	}

	// The popup content view is the container LNPopupController animates.
	if (tbc.respondsToSelector_(ObjC.selector('popupContentView'))) {
		var pcv = tbc.popupContentView();
		if (pcv && !pcv.isNull()) console.log('  popupContentView frame: ' + JSON.stringify(frameOf(pcv)));
	}
	if (tbc.respondsToSelector_(ObjC.selector('popupBar'))) {
		var pb = tbc.popupBar();
		if (pb && !pb.isNull()) console.log('  popupBar frame: ' + JSON.stringify(frameOf(pb)) + ' hidden=' + pb.isHidden());
	}
	return tbc;
}

ObjC.schedule(ObjC.mainQueue, function () {
	var tbc = report('COLLAPSED (as found)');
	if (!tbc) return;

	// Now open it for real and print the same fields, so the two states can be
	// compared side by side.
	tbc.openPopupAnimated_completion_(true, new ObjC.Block({
		retType: 'void', argTypes: [],
		implementation: function () {
			setTimeout(function () {
				ObjC.schedule(ObjC.mainQueue, function () { report('AFTER openPopup'); });
			}, 900);
		}
	}));

	// If the completion never fires (the failure mode already seen), still print.
	setTimeout(function () {
		ObjC.schedule(ObjC.mainQueue, function () { report('AFTER openPopup (timed fallback)'); });
	}, 2500);
});

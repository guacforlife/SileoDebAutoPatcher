// P0 probe: can an injected process activate RootHide Patcher's SwiftUI
// "Convert .deb" button through the accessibility tree?
//
// Sequence:
//   1. positive control  -- proves the Frida session is alive (a dead session
//      looks exactly like "element not found", which is the trap that has cost
//      hours before)
//   2. post `patcherFileOpen` with a URL so ContentView renders the button
//   3. dump the accessibility tree
//   4. accessibilityActivate the match
//   5. watch for the "Converting..." / "Error(n)" alert -- the only real proof
//      the button's action ran
//
// Run with:  ( sleep 45; echo exit ) | frida -H 127.0.0.1:27042 -p <PID> -l ax-probe.js
// NO -q -- it detaches hooks even with stdin held open.

'use strict';

var DEB = null;      // set from the command line via rpc, or defaults below
var TARGET = 'convert';

function log(s) { console.log(s); }

// ---------------------------------------------------------------- positive control

log('PROBE_LOADED: ok');
setTimeout(function () { log('POSITIVE_CONTROL: session alive at t+3s'); }, 3000);

// ---------------------------------------------------------------- ax tree walk

function describe(o) {
  var cls = 'nil', label = '', traits = '0', frame = '';
  try { cls = o.$className; } catch (e) {}
  try { var l = o.accessibilityLabel(); label = l ? l.toString() : ''; } catch (e) {}
  try { traits = o.accessibilityTraits().toString(); } catch (e) {}
  try {
    if (o.isKindOfClass_(ObjC.classes.UIView)) {
      var f = o.frame();
      frame = f.origin.x.toFixed(0) + ',' + f.origin.y.toFixed(0) + ' ' +
              f.size.width.toFixed(0) + 'x' + f.size.height.toFixed(0);
    }
  } catch (e) {}
  return { cls: cls, label: label, traits: traits, frame: frame };
}

// Walk views AND accessibility containers. SwiftUI exposes its buttons as
// UIAccessibilityElement children of the hosting view, not as UIViews, so a
// plain subviews walk finds nothing.
function walk(node, depth, out, budget) {
  if (depth > 40 || out.length > 4000 || budget.n-- < 0) return;

  var d = describe(node);
  var isEl = false;
  try { isEl = node.isAccessibilityElement(); } catch (e) {}
  if (isEl || d.label) out.push({ depth: depth, obj: node, d: d, isEl: isEl });

  // accessibility children
  try {
    if (node.respondsToSelector_(ObjC.selector('accessibilityElementCount'))) {
      var n = node.accessibilityElementCount();
      if (n > 0 && n < 500) {
        for (var i = 0; i < n; i++) {
          var child = node.accessibilityElementAtIndex_(i);
          if (child) walk(child, depth + 1, out, budget);
        }
      }
    }
  } catch (e) {}

  // regular view children
  try {
    if (node.isKindOfClass_(ObjC.classes.UIView)) {
      var subs = node.subviews();
      for (var j = 0; j < subs.count(); j++) walk(subs.objectAtIndex_(j), depth + 1, out, budget);
    }
  } catch (e) {}
}

function collect() {
  var out = [], budget = { n: 8000 };
  var app = ObjC.classes.UIApplication.sharedApplication();
  var wins = app.windows();
  for (var i = 0; i < wins.count(); i++) walk(wins.objectAtIndex_(i), 0, out, budget);
  return out;
}

// ---------------------------------------------------------------- steps

function postFileOpen(path) {
  var url = ObjC.classes.NSURL.fileURLWithPath_(path);
  ObjC.classes.NSNotificationCenter.defaultCenter()
    .postNotificationName_object_('patcherFileOpen', url);
  log('POSTED_patcherFileOpen: ' + path);
}

function dumpAndActivate() {
  var els = collect();
  log('AX_TREE: ' + els.length + ' labelled/element nodes');
  var match = null;
  for (var i = 0; i < els.length; i++) {
    var e = els[i];
    var pad = new Array(e.depth + 1).join('  ');
    log('  ' + pad + '[' + (e.isEl ? 'E' : ' ') + '] ' + e.d.cls +
        ' label="' + e.d.label + '" traits=' + e.d.traits +
        (e.d.frame ? ' frame=' + e.d.frame : ''));
    if (!match && e.d.label && e.d.label.toLowerCase().indexOf(TARGET) >= 0) match = e;
  }

  if (!match) { log('AX_FIND: FAIL (no label containing "' + TARGET + '")'); return; }
  log('AX_FIND: OK -> ' + match.d.cls + ' label="' + match.d.label + '"');

  var r = null;
  try { r = match.obj.accessibilityActivate(); } catch (e) {
    log('AX_ACTIVATE: THREW ' + e); return;
  }
  log('AX_ACTIVATE: returned ' + r);
}

// The real verdict: did an alert appear as a result?
function watchAlerts() {
  try {
    var m = ObjC.classes.UIViewController['- presentViewController:animated:completion:'];
    Interceptor.attach(m.implementation, {
      onEnter: function (args) {
        try {
          var vc = new ObjC.Object(args[2]);
          if (vc.isKindOfClass_(ObjC.classes.UIAlertController)) {
            var t = vc.title(); t = t ? t.toString() : '(nil)';
            log('ALERT_PRESENTED: "' + t + '"');
          }
        } catch (e) {}
      }
    });
    log('ALERT_WATCH: installed');
  } catch (e) { log('ALERT_WATCH: FAIL ' + e); }
}

// ---------------------------------------------------------------- drive

rpc.exports = {
  setdeb: function (p) { DEB = p; }
};

ObjC.schedule(ObjC.mainQueue, function () {
  watchAlerts();
  var path = DEB || '/var/mobile/RootHidePatcher/.Inbox/__debautopatcher_probe__.deb';
  postFileOpen(path);
});

// give SwiftUI time to re-render with selectedFile set
setTimeout(function () {
  ObjC.schedule(ObjC.mainQueue, function () { dumpAndActivate(); });
}, 2500);

setTimeout(function () { log('PROBE_DONE'); }, 20000);

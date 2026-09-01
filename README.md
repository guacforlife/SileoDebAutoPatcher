# SileoDebAutoPatcher

Automates the Sileo → RootHide Patcher → Sileo round trip for tweaks that need
roothide conversion.

Installing such a tweak normally costs four taps across two apps:

1. Sileo raises a **`Not Updated`** alert → tap **`Convert`**
2. Patcher opens → tap **`Convert .deb`** → wait
3. The completion alert appears → tap **`->Sileo`**
4. Sileo reopens on the package page → tap **`Get`**

With SileoDebAutoPatcher all four happen on their own. The only pause is a **1.5 second
countdown before step 2**, which exists so the three conversion options can
still be changed — tap the pill to cancel that run. Set it to anything from 0
to 10 seconds in Settings.

The flow ends on Sileo's queue with Confirm on screen: SileoDebAutoPatcher taps Get,
waits for the modal package page to close, then expands the download queue.
**Confirm is never tapped** — that step is always yours.

## Install

```sh
./dev.sh              # build, patch, drop into /var/mobile/RootHidePatcher/,
                      # install from Sileo (local repo on :8140)
./dev.sh --fast       # build, patch, dpkg -i, relaunch both apps (iteration)
```

Settings ▸ SileoDebAutoPatcher has a master switch, per-step switches, and the countdown
length. No respring is ever needed — neither target is SpringBoard.

**Emergency stop**, needing neither Settings nor a working cfprefsd:

```sh
ssh <device> "touch /var/tmp/.debautopatcher.off"   # then relaunch the app
```

## How it works

One dylib, injected into both `org.coolstar.SileoStore` and
`com.roothide.patcher`.

| Step | Mechanism |
|---|---|
| Accept `Not Updated` | It is a genuine `UIAlertController` with hardcoded English strings (no `.lproj` entry), so matching `Not Updated` / `Convert` is locale-safe. The action's handler is invoked via the private `handler` KVC key. |
| Detect the handoff back | The delegate's `application:openURL:options:` is swizzled on whatever class the *live* delegate actually is — no dependency on the mangled Swift name. |
| Tap `Convert .deb` | Patcher is pure SwiftUI: four ObjC classes, no view controller, no target/action. The button is reachable only as a `SwiftUI.AccessibilityNode`, activated with `-accessibilityActivate`. |
| Tap `Get` | `PackageViewController.downloadButton` is a real `UIButton` subclass, so `sendActionsForControlEvents:` works. |
| Open the confirm screen | `Get` only queues the package and raises the collapsed popup *bar*. Sileo expands it via Swift-only code, which calls LNPopupController's ObjC `-openPopupAnimated:completion:` — that selector is reachable. |

**Why accessibility rather than running `patch.sh` ourselves:** activating the
real button means whatever the user did to the option toggles during the
countdown is respected for free, with no duplication of Patcher's mode logic.

Two things that look like they should work and don't:

- **Suppressing Sileo's alert and calling the handler directly.** The handler's
  whole payload lives inside `alert.dismiss(animated:completion:)`, and that
  completion is not reliably invoked on a controller that was never presented.
  The alert is always presented first, then fired.
- **Waiting for `viewDidAppear:` to know the confirm screen arrived.** UIKit
  skips it when the content controller never went through an appearance
  transition, which happens whenever Sileo opened the popup itself. SileoDebAutoPatcher
  asserts the state instead.

## Guards

Everything below is exercised by `harness/negatives.sh`.

- Master switch, read fresh on every decision — no caching.
- **Action sheets are refused outright.** Tapping Get on an installed package
  opens a Modify sheet containing Uninstall; it can never be auto-fired.
- Alerts with zero actions are refused (Patcher's `Converting...` has none, and
  nothing on screen can dismiss it — if one is ever orphaned, SileoDebAutoPatcher
  dismisses it).
- The Get title is a **whitelist** (`Get`/`Queue`/`Upgrade`, read from Sileo's
  own `Localizable.strings`), not a blacklist. Anything else is logged and
  refused.
- Auto-Get only inside a 20s window opened by a `file://*.deb` arriving. Plain
  browsing never self-installs.
- One-shot associated-object gates per alert and per view controller; a
  generation counter cancels retry chains from a superseded run.
- Every tap re-checks `window`/`isHidden`/`alpha`/`isEnabled` immediately before
  firing, inside `@try/@catch`.
- No `object_getIvar` reflection anywhere.
- **Nothing hooks `confirmQueued:` or `confirmButton`.** That absence is what
  guarantees the flow stops at the confirm screen.

## Harness

The tweak writes `<unix_ms>|<APP>|<EVENT>|<STATUS>|<detail>` to
`/var/tmp/.debautopatcher.log`. Both apps are jbroot apps, so that lands in the real
namespace — read it from SSH at `/rootfs/private/var/tmp/.debautopatcher.log`.

```sh
./iterate.sh              # build + deploy + full run, one PASS/FAIL verdict
./harness/run.sh [pkgid]  # just the run
./harness/negatives.sh    # the four safety tests
```

`run.sh` arms a one-shot auto-Get and deep-links to a package page. The tweak
taps Get, which starts a **real** download, which trips Sileo's **real**
not-roothide detection — so the harness exercises the production path rather
than a test-only shortcut. It then diffs the observed events against the
expected sequence and prints one verdict. Runs are non-destructive: the flow
stops at the confirm screen, so nothing is ever installed.

**Candidates are single-use.** A run leaves its converted deb in
`/var/mobile/RootHidePatcher/`, which rhdarchived serves as a local Sileo repo
on `:8140` — after which Sileo finds a roothide build and never raises
`Not Updated` for that package again. `harness/lib.sh` burns candidates on three
independent signals; when a run finds a package no longer needs converting it
reports `INCONCLUSIVE` rather than a misleading pass. Top up
`harness/candidates.txt` when it runs dry.

Per-run logs are kept in `harness/logs/`.

## Notes for future work

- frida-server on the test device is **17.16.2**; the matching client is
  `~/.frida17/bin/frida` (the 16.x client cannot attach). Invoke without `-q`
  and hold stdin: `( sleep 40; echo exit ) | frida -H 127.0.0.1:27042 -p <PID> -l x.js`.
- `defaults` on iOS has **no `delete` mode** — restore a preference by writing
  the default back explicitly.
- `CGRect`-returning methods do not marshal reliably through the Frida 17 ObjC
  bridge here; parse `-[UIView description]` instead.
- The package id must avoid `patch.sh`'s `INCOMPATIBLE_PACKAGES` substrings
  (`sileo`, `zebra`, `filza`, `preferenceloader`, `altlist`, …). That list is
  matched against the `Package:` field only, so `Depends: preferenceloader` is
  fine.
- No `.roothidepatch` symlink is created; none of the working tweaks on this
  device have one. If injection ever fails, that is the first thing to try.

## Tested on

Sileo 2.5.1-13 and RootHide Patcher 2.1.4, on iOS 16.3.1 (Dopamine / roothide),
iPhone 14 Pro Max. Nothing is pinned to that combination: the alerts are matched
on the hardcoded English strings both apps use, the Convert button is found
through the accessibility tree rather than a private view, and a miss degrades
to "nothing happens" rather than to a wrong tap.

#!/bin/bash
# SileoDebAutoPatcher end-to-end harness.
#
#   ./harness/run.sh [package-id]
#
# Triggers a real conversion round trip with no taps on the phone, then diffs
# the observed event sequence against the expected one and prints ONE verdict.
# Exits non-zero on failure so it can be looped on.
#
# The run is non-destructive by construction: the flow stops at Sileo's queue
# confirm screen, so nothing is ever installed. Cleanup kills Sileo (the queue
# is in-memory) and removes whatever deb this run produced.

set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-ip14}"
TIMEOUT="${TIMEOUT:-150}"
LOG_REAL=/rootfs/private/var/tmp/.debautopatcher.log

PASS=$(security find-generic-password -s trollstore -a "$DEVICE" -w)
sshx() { ssh "$DEVICE" "echo '$PASS' | sudo -S -p '' $1"; }

. harness/lib.sh

PKG="${1:-}"
if [ -z "$PKG" ]; then
	PKG=$(pf_pick_candidate || true)
fi
if [ -z "$PKG" ]; then
	echo "no usable candidate: every entry in harness/candidates.txt is already"
	echo "converted and served by the local repo. Add more, or clear the stale"
	echo "debs from /var/mobile/RootHidePatcher/ and let Sileo refresh."
	exit 2
fi

echo "==> candidate: $PKG"

# --- pre-state -------------------------------------------------------------
BEFORE=$(ssh "$DEVICE" "ls /var/mobile/RootHidePatcher/*.deb 2>/dev/null | sort")

sshx "rm -f $LOG_REAL" >/dev/null 2>&1
ssh "$DEVICE" "/var/jb/usr/bin/open org.coolstar.SileoStore" >/dev/null 2>&1
sleep 3

# --- trigger ---------------------------------------------------------------
# Arm the one-shot auto-Get, then deep-link to the package page. The tweak taps
# Get, which starts a REAL download, which trips Sileo's real not-roothide
# detection. Nothing here is a test-only shortcut.
echo "==> trigger"
ssh "$DEVICE" "/usr/bin/notifyutil -p com.guacforlife.debautopatcher.harness.arm" >/dev/null 2>&1
sleep 1
ssh "$DEVICE" "/usr/bin/uiopen --url 'sileo://package/$PKG'" >/dev/null 2>&1

# --- wait on-device (one ssh round trip, not $TIMEOUT of them) --------------
echo "==> waiting up to ${TIMEOUT}s"
# The trailing settle matters: SILEO_QUEUE_SHOWN and SILEO_QUEUE_OPEN can land
# in either order (Sileo sometimes opens the queue itself), so snapshotting the
# log the instant the terminal event appears can miss one that is 0.5s behind.
sshx "sh -c 'n=0; while [ \$n -lt $TIMEOUT ]; do
        if grep -q \"|SILEO_QUEUE_SHOWN|OK|\" $LOG_REAL 2>/dev/null; then break; fi
        if grep -q \"|FAIL|\" $LOG_REAL 2>/dev/null; then break; fi
        n=\$((n+2)); sleep 2;
      done; sleep 3'" >/dev/null 2>&1

LOG=$(sshx "cat $LOG_REAL 2>/dev/null" 2>/dev/null)

# Keep every run's log — a failure two runs ago is otherwise unrecoverable.
mkdir -p harness/logs
printf '%s\n' "$LOG" > "harness/logs/$(date +%Y%m%d-%H%M%S)-${PKG}.log"

# A run that actually converted burns the candidate for this session.
printf '%s\n' "$LOG" | grep -q '|PATCHER_DONE_ALERT|OK|' && pf_burn "$PKG"

# --- verdict ---------------------------------------------------------------
EXPECTED=(
	SILEO_ALERT
	SILEO_CONVERT_FIRE
	PATCHER_INBOX
	PATCHER_COUNTDOWN
	PATCHER_AXFIND
	PATCHER_ACTIVATE
	PATCHER_CONVERTING
	PATCHER_DONE_ALERT
	PATCHER_SHARE_FIRE
	SILEO_OPENURL
	SILEO_PKGVC
	SILEO_GET_TAP
	SILEO_QUEUE_OPEN
	SILEO_QUEUE_SHOWN
)

echo
printf '%-22s %s\n' "STEP" "RESULT"
printf '%-22s %s\n' "----------------------" "------"
FAILED=""
for step in "${EXPECTED[@]}"; do
	# First SUCCESS, not first occurrence: the priming Get tap legitimately logs
	# a SKIP for QUEUE_OPEN before the conversion has even happened.
	line=$(printf '%s\n' "$LOG" | grep "|${step}|OK|" | head -1 || true)
	[ -z "$line" ] && line=$(printf '%s\n' "$LOG" | grep "|${step}|" | tail -1 || true)
	if [ -z "$line" ]; then
		printf '%-22s %s\n' "$step" "MISSING"
		[ -z "$FAILED" ] && FAILED="$step"
	else
		status=$(printf '%s' "$line" | cut -d'|' -f4)
		detail=$(printf '%s' "$line" | cut -d'|' -f5- | cut -c1-60)
		printf '%-22s %-7s %s\n' "$step" "$status" "$detail"
		if [ "$status" != "OK" ] && [ -z "$FAILED" ]; then FAILED="$step"; fi
	fi
done

# --- cleanup ---------------------------------------------------------------
AFTER=$(ssh "$DEVICE" "ls /var/mobile/RootHidePatcher/*.deb 2>/dev/null | sort")
NEW=$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -v '^$' || true)
if [ -n "$NEW" ]; then
	echo
	echo "==> removing debs this run produced:"
	printf '%s\n' "$NEW" | sed 's/^/    /'
	printf '%s\n' "$NEW" | while read -r f; do [ -n "$f" ] && sshx "rm -f '$f'" >/dev/null 2>&1; done
fi
ssh "$DEVICE" "/var/jb/usr/local/bin/pkill -f Sileo || true" >/dev/null 2>&1

echo
# Distinguish "SileoDebAutoPatcher broke" from "this candidate no longer needs converting",
# which otherwise looks like a mysterious early finish.
if ! printf '%s\n' "$LOG" | grep -q '|SILEO_ALERT|OK|' && printf '%s\n' "$LOG" | grep -q '|SILEO_QUEUE_SHOWN|'; then
	echo "VERDICT: INCONCLUSIVE — Sileo never raised \"Not Updated\" for $PKG."
	echo "It already has a roothide build available (most likely from the local"
	echo "repo on :8140). Pick a different candidate."
	exit 3
fi

# The finish line is "the queue is expanded and unobstructed", not "a queue view
# controller exists somewhere". A collapsed LNPopupController bar keeps its
# content view controller installed and in the window, so an event that only
# proves existence once passed here while the phone showed "Queued 1 package".
# Assert the measurement explicitly so that can never silently pass again.
SHOWN=$(printf '%s\n' "$LOG" | grep '|SILEO_QUEUE_SHOWN|OK|' | tail -1 || true)
if [ -z "$FAILED" ] && ! printf '%s' "$SHOWN" | grep -q 'expanded=1'; then
	echo "VERDICT: FAIL — the queue never expanded (collapsed popup bar)."
	echo "  $SHOWN"
	exit 1
fi
if [ -z "$FAILED" ] && ! printf '%s' "$SHOWN" | grep -q 'covered=0'; then
	echo "VERDICT: FAIL — the queue opened behind the modal package page."
	echo "  $SHOWN"
	exit 1
fi

if [ -z "$FAILED" ]; then
	echo "VERDICT: PASS"
	echo "  $SHOWN"
	exit 0
fi
echo "VERDICT: FAIL (first bad step: $FAILED)"
echo
echo "--- full log ---"
printf '%s\n' "$LOG"
exit 1

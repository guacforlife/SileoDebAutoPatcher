#!/bin/bash
# SileoDebAutoPatcher negative tests — the ones that matter, because a misfire here could
# uninstall something rather than merely fail to install it.
#
#   ./harness/negatives.sh
#
# Each test prints its own verdict; the script exits non-zero if any fail.

set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-ip14}"
LOG_REAL=/rootfs/private/var/tmp/.debautopatcher.log
CONVERTIBLE="${CONVERTIBLE:-com.cydiageek.noigshareoptionscontroller}"
INSTALLED="${INSTALLED:-com.opa334.ccsupport}"

. harness/lib.sh

PASS=$(security find-generic-password -s trollstore -a "$DEVICE" -w)
sshx() { ssh "$DEVICE" "echo '$PASS' | sudo -S -p '' $1"; }
FAILURES=0

reset_sileo() {
	ssh "$DEVICE" "/var/jb/usr/local/bin/pkill -f Sileo || true" >/dev/null 2>&1
	ssh "$DEVICE" "/var/jb/usr/local/bin/pkill -f Patcher || true" >/dev/null 2>&1
	sshx "rm -f $LOG_REAL" >/dev/null 2>&1
	sleep 1
	ssh "$DEVICE" "/var/jb/usr/bin/open org.coolstar.SileoStore" >/dev/null 2>&1
	sleep 4
}

getlog() { sshx "cat $LOG_REAL 2>/dev/null" 2>/dev/null; }

# The Procursus `defaults` on iOS has no `delete` mode — restore by writing the
# shipped default back explicitly.
reset_prefs() {
	ssh "$DEVICE" "/usr/bin/defaults write com.guacforlife.debautopatcher enabled -bool true" >/dev/null 2>&1
	ssh "$DEVICE" "/usr/bin/defaults write com.guacforlife.debautopatcher convertDelay -float 1.5" >/dev/null 2>&1
}

# check <name> <must-not-appear-regex|-> <must-appear-regex|-> <log>
check() {
	local name="$1" forbidden="$2" required="$3" log="$4" ok=1 why=""
	if [ "$forbidden" != "-" ] && printf '%s\n' "$log" | grep -qE "$forbidden"; then
		ok=0; why="forbidden event present: $(printf '%s\n' "$log" | grep -oE "$forbidden" | head -1)"
	fi
	if [ "$required" != "-" ] && ! printf '%s\n' "$log" | grep -qE "$required"; then
		ok=0; why="${why:+$why; }required event missing: $required"
	fi
	if [ $ok -eq 1 ]; then
		printf '  %-38s PASS\n' "$name"
	else
		printf '  %-38s FAIL  (%s)\n' "$name" "$why"
		FAILURES=$((FAILURES+1))
	fi
}

reset_prefs   # never inherit state from an aborted previous run

echo "=== N1: master switch off — nothing should happen at all ==="
ssh "$DEVICE" "/usr/bin/defaults write com.guacforlife.debautopatcher enabled -bool false" >/dev/null 2>&1
reset_sileo
ssh "$DEVICE" "/usr/bin/notifyutil -p com.guacforlife.debautopatcher.harness.arm" >/dev/null 2>&1
sleep 1
ssh "$DEVICE" "/usr/bin/uiopen --url 'sileo://package/$CONVERTIBLE'" >/dev/null 2>&1
sleep 20
L1=$(getlog)
check "no Get tapped" '\|SILEO_GET_TAP\|OK\|' - "$L1"
check "no Convert fired" '\|SILEO_CONVERT_FIRE\|OK\|' - "$L1"
check "no conversion started" '\|PATCHER_ACTIVATE\|OK\|' - "$L1"
# Positive assertion so this test cannot pass merely because nothing ran.
check "refusal was logged" - '\|SILEO_GET_TAP\|SKIP\|pref off' "$L1"
reset_prefs

echo
echo "=== N2: ordinary browsing — a package page must not self-install ==="
reset_sileo
# deliberately NO arm notification
ssh "$DEVICE" "/usr/bin/uiopen --url 'sileo://package/$CONVERTIBLE'" >/dev/null 2>&1
sleep 15
L2=$(getlog)
check "no Get tapped" '\|SILEO_GET_TAP\|OK\|' - "$L2"
check "page was seen (hooks alive)" - '\|SILEO_PKGVC\|OK\|' "$L2"
check "refusal was logged" - '\|SILEO_GET_TAP\|SKIP\|not armed' "$L2"

echo
echo "=== N3: already-installed package — must never open the Modify sheet ==="
reset_sileo
ssh "$DEVICE" "/usr/bin/notifyutil -p com.guacforlife.debautopatcher.harness.arm" >/dev/null 2>&1
sleep 1
ssh "$DEVICE" "/usr/bin/uiopen --url 'sileo://package/$INSTALLED'" >/dev/null 2>&1
sleep 15
L3=$(getlog)
check "no Get tapped" '\|SILEO_GET_TAP\|OK\|' - "$L3"
check "page was seen (hooks alive)" - '\|SILEO_PKGVC\|OK\|' "$L3"
check "button title refused" - '\|SILEO_GET_TAP\|SKIP\|button reads' "$L3"

echo
echo "=== N4: countdown pill visible, and cancelling it stops the conversion ==="
# This one needs a REAL conversion, so it needs a candidate Sileo still thinks
# needs converting. A package that is already roothide-native never raises
# "Not Updated", so the Patcher never launches — that is inconclusive, not a
# safety failure. Burn such a candidate and move to the next one.
N4_RAN=0
for _n4try in 1 2 3; do
# No fallback to a fixed package here: the fallback ignores the burn list, so
# it just re-offers the same spent candidate on every retry.
FRESH=$(pf_pick_candidate || true)
[ -z "$FRESH" ] && break
echo "  candidate: $FRESH"

ssh "$DEVICE" "/usr/bin/defaults write com.guacforlife.debautopatcher convertDelay -float 14" >/dev/null 2>&1
reset_sileo
ssh "$DEVICE" "/usr/bin/notifyutil -p com.guacforlife.debautopatcher.harness.arm" >/dev/null 2>&1
sleep 1
ssh "$DEVICE" "/usr/bin/uiopen --url 'sileo://package/$FRESH'" >/dev/null 2>&1

# Wait for the countdown, then tap the pill the way a finger would: by firing
# the gesture recogniser's own action on the real overlay view.
echo "  waiting for the countdown..."
sshx "sh -c 'n=0; while [ \$n -lt 40 ]; do grep -q \"|PATCHER_COUNTDOWN|OK|\" $LOG_REAL 2>/dev/null && break; n=\$((n+1)); sleep 1; done'" >/dev/null 2>&1
PID=$(ssh "$DEVICE" "/usr/bin/launchctl list | grep com.roothide.patcher" | awk '{print $1}')
if [ -z "$PID" ] || [ "$PID" = "-" ]; then
	if ! getlog | grep -q '|SILEO_ALERT|OK|'; then
		printf '  %-38s SKIP  (already roothide, nothing to convert)\n' "$FRESH"
		pf_burn "$FRESH"
		continue
	fi
	printf '  %-38s FAIL  (Patcher not running)\n' "cancel the countdown"
	FAILURES=$((FAILURES+1))
	N4_RAN=1
else
	pgrep -f "ssh.*-L 27042:127.0.0.1:27042" >/dev/null || ssh -f -N -L 27042:127.0.0.1:27042 "$DEVICE"
	# Asserts the pill is genuinely on screen (not merely allocated), then taps it.
	OV=$(( sleep 7; echo exit ) | ~/.frida17/bin/frida -H 127.0.0.1:27042 -p "$PID" \
	        -l harness/overlay-check.js 2>&1 | sed -n '/Attaching/,$p')
	printf '%s\n' "$OV" | grep -E '^(FRAME|TITLE|HIDDEN|WINDOW_IN)' | sed 's/^/    /'
	if printf '%s\n' "$OV" | grep -q '^VERDICT: PASS'; then
		printf '  %-38s PASS\n' "pill is visible on screen"
	else
		printf '  %-38s FAIL  (%s)\n' "pill is visible on screen" \
			"$(printf '%s\n' "$OV" | grep '^VERDICT' | head -1)"
		FAILURES=$((FAILURES+1))
	fi
	sleep 14
	L4=$(getlog)
	check "cancel recorded" - '\|PATCHER_CANCEL\|OK\|' "$L4"
	check "conversion did NOT run" '\|PATCHER_ACTIVATE\|OK\|' - "$L4"
	check "no deb was produced" '\|PATCHER_DONE_ALERT\|OK\|' - "$L4"
	N4_RAN=1
fi
break
done
if [ "$N4_RAN" = "0" ]; then
	printf '  %-38s INCONCLUSIVE (no un-converted candidate left)\n' "countdown test"
	echo "  Top up harness/candidates.txt — BigBoss alone has ~219 more."
fi
reset_prefs

ssh "$DEVICE" "/var/jb/usr/local/bin/pkill -f Sileo || true" >/dev/null 2>&1
ssh "$DEVICE" "/var/jb/usr/local/bin/pkill -f Patcher || true" >/dev/null 2>&1

echo
if [ "$FAILURES" -eq 0 ]; then
	echo "VERDICT: PASS (all negative tests)"
	exit 0
fi
echo "VERDICT: FAIL ($FAILURES negative checks failed)"
exit 1

#!/bin/bash
# SileoDebAutoPatcher deploy.
#
#   ./dev.sh            build, patch, drop into /var/mobile/RootHidePatcher/
#                       so it shows up in the local Sileo repo (:8140) and you
#                       install it at your leisure. This is the default.
#   ./dev.sh --fast     build, patch, dpkg -i, relaunch Sileo and Patcher.
#                       For iteration. No respring — neither target is
#                       SpringBoard, so there is nothing to respring for.
#
# Note: none of the working tweaks on this device carry a .roothidepatch
# symlink, so dev.sh does not create one. If injection ever fails, that is the
# first thing to try:
#   ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib \
#     /var/jb/Library/MobileSubstrate/DynamicLibraries/SileoDebAutoPatcher.dylib.roothidepatch

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:---repo}"
DEVICE="${DEVICE:-ip14}"
export THEOS="${THEOS:-$HOME/theos}"

PASS=$(security find-generic-password -s trollstore -a "$DEVICE" -w)
sshx() { ssh "$DEVICE" "echo '$PASS' | sudo -S -p '' $1"; }

echo "==> build"
make package FINALPACKAGE=1 2>&1 | tail -2

DEB=$(ls -t packages/*.deb | head -1)
BASE=$(basename "$DEB")
echo "==> $DEB"

# Sanity: the two silent-failure traps, checked every single deploy.
if ! lipo -info .theos/obj/SileoDebAutoPatcher.dylib 2>/dev/null | grep -q 'arm64 arm64e'; then
	echo "FATAL: dylib is not universal arm64+arm64e — ElleKit would silently skip it on A16"
	exit 1
fi

scp -q "$DEB" "$DEVICE:/var/tmp/$BASE"

case "$MODE" in
--repo)
	PATCHED="${BASE/.deb/-patched.deb}"
	sshx "/var/jb/Applications/Patcher.app/patch.sh /var/tmp/$BASE /var/mobile/RootHidePatcher/$PATCHED" | tail -3
	echo "==> /var/mobile/RootHidePatcher/$PATCHED — install it from Sileo"
	;;
--fast)
	sshx "/var/jb/Applications/Patcher.app/patch.sh /var/tmp/$BASE /var/tmp/pf-patched.deb" | tail -3
	sshx "dpkg -i /var/tmp/pf-patched.deb" | tail -2
	# ElleKit silently skips 600 filter plists; the Patcher CLI + dpkg leave
	# them as they are, so enforce it here as well as at stage time.
	sshx "chmod 644 /var/jb/Library/MobileSubstrate/DynamicLibraries/SileoDebAutoPatcher.plist"
	sshx "rm -f /var/tmp/pf-patched.deb /var/tmp/$BASE"
	echo "==> relaunching Sileo + Patcher (no respring)"
	ssh "$DEVICE" "/var/jb/usr/local/bin/pkill -f Sileo || true; /var/jb/usr/local/bin/pkill -f Patcher || true"
	sleep 2
	ssh "$DEVICE" "/var/jb/usr/bin/open org.coolstar.SileoStore"
	sleep 3
	;;
*)
	echo "usage: $0 [--repo|--fast]"
	exit 2
	;;
esac

echo "==> done"

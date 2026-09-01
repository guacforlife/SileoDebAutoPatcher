# Shared harness helpers. Source from the project root.
#
# The subtle part is candidate selection. A run converts its package and leaves
# the result in /var/mobile/RootHidePatcher/, which rhdarchived serves as a
# local Sileo repo on :8140. From then on Sileo finds a roothide build and never
# raises "Not Updated" for it again — so every candidate is single-use, and a
# test that reuses one silently measures nothing.
#
# Three independent burn signals, because no one of them is sufficient:
#   1. harness/.burned   — this session converted it (fastest, but local only)
#   2. the local repo index on device (survives across sessions)
#   3. a converted deb still sitting in /var/mobile/RootHidePatcher/

DEVICE="${DEVICE:-ip14}"
LOCAL_INDEX='/var/lib/apt/lists/127.0.0.1:8140_._Packages'
BURNED=harness/.burned

pf_pick_candidate() {
	touch "$BURNED"
	local served c
	served=$(ssh "$DEVICE" "grep '^Package: ' '$LOCAL_INDEX' 2>/dev/null | sed 's/^Package: //'" | tr -d '\r')
	while read -r c; do
		[ -z "$c" ] && continue
		case "$c" in \#*) continue ;; esac
		grep -qx "$c" "$BURNED" 2>/dev/null && continue
		printf '%s\n' "$served" | grep -qx "$c" && continue
		ssh "$DEVICE" "ls /var/mobile/RootHidePatcher/${c}_*.deb" >/dev/null 2>&1 && continue
		printf '%s' "$c"
		return 0
	done < harness/candidates.txt
	return 1
}

pf_burn() {
	touch "$BURNED"
	grep -qx "$1" "$BURNED" 2>/dev/null || echo "$1" >> "$BURNED"
}

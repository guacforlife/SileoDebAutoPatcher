# SileoDebAutoPatcher — automates Sileo -> RootHide Patcher -> Sileo for debs needing
# roothide conversion.
#
# ARCHS MUST include arm64e — ElleKit silently skips arm64-only dylibs on A12+
# (no crash, no error, no log). THEOS_PACKAGE_SCHEME = rootless produces the
# iphoneos-arm64 deb the Patcher accepts.
#
# NOTE: the deb's Package: id must NOT contain any of patch.sh's
# INCOMPATIBLE_PACKAGES substrings (sileo, zebra, choicy, filza,
# preferenceloader, altlist, ccsupport, ...) or the Patcher refuses it.
# Hence "debautopatcher" rather than anything with "sileo" in it.

TARGET = iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

# Deliberately NO INSTALL_TARGET_PROCESSES — dev.sh does its own targeted
# kill/relaunch, and we never want a stray `make install` killing Sileo
# halfway through an install.

TWEAK_NAME = SileoDebAutoPatcher
SileoDebAutoPatcher_FILES = SDAPCommon.m SDAPOverlay.m SDAPPatcher.m SDAPSileo.m Tweak.x
SileoDebAutoPatcher_CFLAGS = -fobjc-arc
SileoDebAutoPatcher_FRAMEWORKS = UIKit

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += SileoDebAutoPatcherPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# Theos writes filter plists 600 and ElleKit silently skips those. Fix it at
# stage time so it is right in the deb itself, not only after dev.sh runs.
after-stage::
	@find "$(THEOS_STAGING_DIR)" -name "*.plist" -path "*DynamicLibraries*" -exec chmod 644 {} \; 2>/dev/null || true


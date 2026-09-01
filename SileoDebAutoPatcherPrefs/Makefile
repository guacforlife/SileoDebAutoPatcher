TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SileoDebAutoPatcherPrefs

SileoDebAutoPatcherPrefs_FILES = SDAPRootVC.m
SileoDebAutoPatcherPrefs_FRAMEWORKS = UIKit
SileoDebAutoPatcherPrefs_PRIVATE_FRAMEWORKS = Preferences
SileoDebAutoPatcherPrefs_INSTALL_PATH = /Library/PreferenceBundles
SileoDebAutoPatcherPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

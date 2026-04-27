INSTALL_TARGET_PROCESSES = SpringBoard

# Rootless jailbreak support (iOS 15+/16+ with Dopamine, palera1n rootless, etc.)
THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaoBoiAgent

BaoBoiAgent_FILES = Tweak.x
BaoBoiAgent_CFLAGS = -fobjc-arc
BaoBoiAgent_FRAMEWORKS = UIKit Foundation UserNotifications
BaoBoiAgent_PRIVATE_FRAMEWORKS = AppSupport
BaoBoiAgent_ENTITLEMENTS = entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk

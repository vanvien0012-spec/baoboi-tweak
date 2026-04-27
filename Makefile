INSTALL_TARGET_PROCESSES = SpringBoard

# THEOS_PACKAGE_SCHEME, TARGET, ARCHS được truyền từ command line khi build
# Ví dụ: make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS="arm64 arm64e"

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaoBoiAgent

BaoBoiAgent_FILES = Tweak.x
BaoBoiAgent_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BaoBoiAgent_FRAMEWORKS = UIKit Foundation UserNotifications
BaoBoiAgent_PRIVATE_FRAMEWORKS = AppSupport
BaoBoiAgent_ENTITLEMENTS = entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk

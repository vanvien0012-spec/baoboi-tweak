INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaoBoiAgent

BaoBoiAgent_FILES = Tweak.x
BaoBoiAgent_CFLAGS = -fobjc-arc
BaoBoiAgent_FRAMEWORKS = UIKit Foundation UserNotifications
BaoBoiAgent_PRIVATE_FRAMEWORKS = AppSupport
BaoBoiAgent_ENTITLEMENTS = entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk

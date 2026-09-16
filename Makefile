TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = YukiPower
YukiPower_BUNDLE_EXTENSION = bundle
YukiPower_FILES = src/YukiPower.m
YukiPower_CFLAGS = -fobjc-arc
YukiPower_FRAMEWORKS = UIKit Foundation CoreFoundation
YukiPower_PRIVATE_FRAMEWORKS = ControlCenterUIKit
YukiPower_INSTALL_PATH = /Library/ControlCenter/Bundles/

include $(THEOS_MAKE_PATH)/bundle.mk

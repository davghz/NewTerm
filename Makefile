export TARGET = iphone:15.6:15.1.1
export ARCHS = arm64
export TARGET_CODESIGN = ldid
export TARGET_CODESIGN_FLAGS = -S
export TARGET_CODESIGN_ALLOCATE = $(shell xcrun -f codesign_allocate)

ifeq ($(ROOTLESS),1)
	export DEB_ARCH = iphoneos-arm64
	export INSTALL_PREFIX = /var/jb
else
	export DEB_ARCH = iphoneos-arm
endif

INSTALL_TARGET_PROCESSES = NewTerm

include $(THEOS)/makefiles/common.mk

XCODEPROJ_NAME = NewTerm

NewTerm_XCODE_SCHEME = NewTerm (iOS)
NewTerm_XCODEFLAGS = INSTALL_PREFIX=$(INSTALL_PREFIX) IPHONEOS_DEPLOYMENT_TARGET=15.1.1
NewTerm_CODESIGN_FLAGS = -SApp/entitlements.plist
NewTerm_INSTALL_PATH = $(INSTALL_PREFIX)/Applications

include $(THEOS_MAKE_PATH)/xcodeproj.mk

override THEOS_PACKAGE_ARCH := $(DEB_ARCH)

after-stage::
	@$(TARGET_CODESIGN) $(NewTerm_CODESIGN_FLAGS) "$(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/Applications/NewTerm.app/NewTermLoginHelper"

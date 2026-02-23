export TARGET = iphone:13.7:13.0
export ARCHS = arm64
export TARGET_CODESIGN = ldid
export TARGET_CODESIGN_FLAGS = -S
export TARGET_CODESIGN_ALLOCATE = /tmp/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate
export PREBUILT_APP_PATH ?= /Applications/t3rm.app

ifeq ($(ROOTLESS),1)
	export DEB_ARCH = iphoneos-arm64
	export INSTALL_PREFIX = /var/jb
else
	export DEB_ARCH = iphoneos-arm
endif

INSTALL_TARGET_PROCESSES = t3rm NewTerm

include $(THEOS)/makefiles/common.mk

ifeq ($(wildcard $(PREBUILT_APP_PATH)),)
	USE_PREBUILT_APP ?= 0
else
	USE_PREBUILT_APP ?= 1
endif

ifeq ($(USE_PREBUILT_APP),1)
NULL_NAME = t3rm
include $(THEOS_MAKE_PATH)/null.mk

_APP_STAGING_DIR = $(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/Applications

before-package:: stage-prebuilt-app

stage-prebuilt-app::
	@if [ ! -d "$(PREBUILT_APP_PATH)" ]; then \
		echo "error: PREBUILT_APP_PATH does not exist: $(PREBUILT_APP_PATH)" >&2; \
		exit 1; \
	fi
	@src="$(PREBUILT_APP_PATH)"; \
	app_name="$${src##*/}"; \
	mkdir -p "$(_APP_STAGING_DIR)"; \
	rsync -a --delete "$$src/" "$(_APP_STAGING_DIR)/$$app_name/"; \
	echo "[theos] staged prebuilt app $$src"

else

XCODEPROJ_NAME = NewTerm

NewTerm_XCODE_SCHEME = NewTerm (iOS)
NewTerm_XCODEFLAGS = INSTALL_PREFIX=$(INSTALL_PREFIX)
NewTerm_CODESIGN_FLAGS = -SApp/entitlements.plist
NewTerm_INSTALL_PATH = $(INSTALL_PREFIX)/Applications

include $(THEOS_MAKE_PATH)/xcodeproj.mk

endif

before-package::
	perl -i -pe s/iphoneos-arm/$(DEB_ARCH)/ $(THEOS_STAGING_DIR)/DEBIAN/control

after-stage::
	@for app in $(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/Applications/*.app; do \
		if [ -f "$$app/NewTermLoginHelper" ]; then \
			$(TARGET_CODESIGN) -SApp/entitlements.plist "$$app/NewTermLoginHelper" || true; \
		fi; \
	done

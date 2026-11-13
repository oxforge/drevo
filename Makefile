# Drevo — builds without Xcode (the Command Line Tools are enough).

APP_NAME    := Drevo
BUNDLE_ID   := tech.oxforge.drevo
# Release builds pass the tag's version: make dmg VERSION=0.3.0
VERSION     := 0.3.0
BUILD_NUM   := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG      ?= release
# Signing identity. A stable one keeps macOS privacy permissions across rebuilds:
#   make signing-identity      once: creates the local identity below, used from then on
#   make app SIGN_ID="Apple Development: Your Name (TEAMID)"
# Without either, "-" = ad-hoc signature.
LOCAL_SIGN_ID := Drevo Local Signing
SIGN_ID     ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"$(LOCAL_SIGN_ID)"' && echo "$(LOCAL_SIGN_ID)" || echo -)

# The default swift-build backend fails on a Command-Line-Tools-only install.
SWIFT_FLAGS := --build-system native
# swift-testing ships with the CLT, but SwiftPM does not add its framework path. Xcode
# (as on the CI runners) finds it by itself, so the flags go in only where it's there.
CLT_FW      := $(shell xcode-select -p)/Library/Developer/Frameworks
TEST_FLAGS  := $(if $(wildcard $(CLT_FW)/Testing.framework),-Xswiftc -F$(CLT_FW) -Xlinker -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW))

DMG         := build/$(APP_NAME)-$(VERSION).dmg

BIN_DIR      = $(shell swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path 2>/dev/null)

SHELL := /bin/bash

.PHONY: build test app dmg run snapshot icon clean signing-identity ci-signing-secret

# SwiftPM prints a deprecation note for --build-system native on every run; the flag is
# still required without Xcode, so the note is filtered (exit status is kept).
build:
	set -o pipefail; swift build $(SWIFT_FLAGS) -c $(CONFIG) 2>&1 | grep -v "has been deprecated"

test:
	set -o pipefail; swift test $(SWIFT_FLAGS) $(TEST_FLAGS) $(TEST_ARGS) 2>&1 | grep -v "has been deprecated"

icon: build/AppIcon.icns

build/AppIcon.icns: scripts/make-icon.swift
	@mkdir -p build
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

app: build icon
	rm -rf "build/Drevo.app"
	mkdir -p "build/Drevo.app/Contents/MacOS" "build/Drevo.app/Contents/Resources"
	cp "$(BIN_DIR)/drevo" "build/Drevo.app/Contents/MacOS/$(APP_NAME)"
	sed -e 's/__APP_NAME__/$(APP_NAME)/g' -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' \
	    -e 's/__VERSION__/$(VERSION)/g' -e 's/__BUILD__/$(BUILD_NUM)/g' \
	    Resources/Info.plist > "build/Drevo.app/Contents/Info.plist"
	cp build/AppIcon.icns "build/Drevo.app/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) "build/Drevo.app"
	@echo "Built build/Drevo.app"

# The app in a disk image with an Applications shortcut, for a GitHub release.
# hdiutil now and then fails with "Resource busy" on CI runners, so it gets three tries.
dmg: app
	rm -rf build/dmg "$(DMG)"
	mkdir -p build/dmg
	ditto "build/Drevo.app" "build/dmg/Drevo.app"
	ln -s /Applications build/dmg/Applications
	for try in 1 2 3; do \
	    hdiutil create -volname "$(APP_NAME)" -srcfolder build/dmg -format UDZO -ov "$(DMG)" && break; \
	    [ $$try = 3 ] && exit 1; echo "hdiutil failed, trying again…"; sleep 5; \
	done
	rm -rf build/dmg
	@echo "Built $(DMG)"

# One-time: a self-signed identity so rebuilds keep their privacy permissions.
signing-identity:
	SIGN_NAME="$(LOCAL_SIGN_ID)" scripts/make-signing-identity.sh

# One-time: the same identity as GitHub secrets, so release builds are signed with it too.
ci-signing-secret:
	SIGN_NAME="$(LOCAL_SIGN_ID)" scripts/ci-signing-secret.sh

run: app
	open "build/Drevo.app"

# Render the main window to PNGs (light + dark) for visual review.
SNAP_DIR ?= build/snapshots
snapshot: app
	@mkdir -p $(SNAP_DIR)
	"build/Drevo.app/Contents/MacOS/$(APP_NAME)" --snapshot $(SNAP_DIR)/light.png --light $(SNAP_ARGS)
	"build/Drevo.app/Contents/MacOS/$(APP_NAME)" --snapshot $(SNAP_DIR)/dark.png --dark $(SNAP_ARGS)

clean:
	rm -rf .build build

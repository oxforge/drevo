# fman — builds without Xcode (the Command Line Tools are enough).

APP_NAME    := fman
BUNDLE_ID   := tech.oxforge.fman
VERSION     := 0.1.0
BUILD_NUM   := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG      ?= release
# "-" = ad-hoc signature. Pass a real identity for stable privacy permissions:
#   make app SIGN_ID="Apple Development: Your Name (TEAMID)"
SIGN_ID     ?= -

# The default swift-build backend fails on a Command-Line-Tools-only install.
SWIFT_FLAGS := --build-system native
# swift-testing ships with the CLT, but SwiftPM does not add its framework path.
CLT_FW      := $(shell xcode-select -p)/Library/Developer/Frameworks
TEST_FLAGS  := -Xswiftc -F$(CLT_FW) -Xlinker -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW)

BIN_DIR      = $(shell swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path 2>/dev/null)

SHELL := /bin/bash

.PHONY: build test app run snapshot icon clean

build:
	swift build $(SWIFT_FLAGS) -c $(CONFIG)

test:
	set -o pipefail; swift test $(SWIFT_FLAGS) $(TEST_FLAGS) $(TEST_ARGS) 2>&1 | grep -v "has been deprecated"

icon: build/AppIcon.icns

build/AppIcon.icns: scripts/make-icon.swift
	@mkdir -p build
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

app: build icon
	rm -rf "build/fman.app"
	mkdir -p "build/fman.app/Contents/MacOS" "build/fman.app/Contents/Resources"
	cp "$(BIN_DIR)/fman" "build/fman.app/Contents/MacOS/$(APP_NAME)"
	sed -e 's/__APP_NAME__/$(APP_NAME)/g' -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' \
	    -e 's/__VERSION__/$(VERSION)/g' -e 's/__BUILD__/$(BUILD_NUM)/g' \
	    Resources/Info.plist > "build/fman.app/Contents/Info.plist"
	cp build/AppIcon.icns "build/fman.app/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) "build/fman.app"
	@echo "Built build/fman.app"

run: app
	open "build/fman.app"

# Render the main window to PNGs (light + dark) for visual review.
SNAP_DIR ?= build/snapshots
snapshot: app
	@mkdir -p $(SNAP_DIR)
	"build/fman.app/Contents/MacOS/$(APP_NAME)" --snapshot $(SNAP_DIR)/light.png --light $(SNAP_ARGS)
	"build/fman.app/Contents/MacOS/$(APP_NAME)" --snapshot $(SNAP_DIR)/dark.png --dark $(SNAP_ARGS)

clean:
	rm -rf .build build

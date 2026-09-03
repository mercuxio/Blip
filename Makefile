# SwiftPM cannot emit a .app bundle, so the bundle is assembled by hand.
#
# DEVELOPER_DIR is the whole reason this works without Xcode project files:
# pointing it at a full Xcode makes `swift build` use the default build system.
# Without it, the Command Line Tools toolchain is picked up instead and the
# build needs the deprecated `--build-system native` flag to find SwiftUI.
export DEVELOPER_DIR := /Applications/Xcode-beta.app/Contents/Developer

CONFIG   ?= release
BUILD    := .build/$(CONFIG)
APP      := .build/InOut.app
ZIP      := .build/InOut.app.zip
INSTALL  := /Applications/InOut.app

ICON     := Resources/AppIcon.icns
ICONSET  := .build/AppIcon.iconset

.PHONY: all build test app zip run install uninstall icon clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

# Regenerating the icon is deliberately not a dependency of `app`: the .icns is
# a checked-in artifact, and rebuilding it on every build would churn a binary
# file for no reason. Run `make icon` when the artwork actually changes.
icon:
	swift Tools/GenerateIcon.swift "$(ICONSET)"
	iconutil -c icns "$(ICONSET)" -o "$(ICON)"
	@echo "Built $(ICON)"

$(ICON):
	$(MAKE) icon

app: build $(ICON)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILD)/InOut" "$(APP)/Contents/MacOS/InOut"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp "$(ICON)" "$(APP)/Contents/Resources/AppIcon.icns"
	# Ad-hoc signature. Unsigned SwiftUI apps are killed on launch by the
	# hardened runtime on Apple silicon; `-s -` satisfies it without a
	# developer identity, at the cost of not being distributable.
	codesign --force --sign - --timestamp=none "$(APP)"
	@echo "Built $(APP)"

# The release artifact.
#
# `ditto`, not `zip`: a bundle's code signature lives partly in extended
# attributes, and `zip` drops those. The unzipped copy would then fail
# signature validation and be killed on launch — on the downloader's machine
# only, which is the worst place to find out.
zip: app
	rm -f "$(ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@echo "Built $(ZIP)"

run: app
	@pkill -x InOut || true
	open "$(APP)"

install: app
	rm -rf "$(INSTALL)"
	cp -R "$(APP)" "$(INSTALL)"
	@echo "Installed $(INSTALL)"

uninstall:
	@pkill -x InOut || true
	rm -rf "$(INSTALL)"

clean:
	rm -rf .build

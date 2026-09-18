# SwiftPM cannot emit a .app bundle, so the bundle is assembled by hand.
#
# DEVELOPER_DIR is the whole reason this works without Xcode project files:
# pointing it at a full Xcode makes `swift build` use the default build system.
# Without it, the Command Line Tools toolchain is picked up instead and the
# build needs the deprecated `--build-system native` flag to find SwiftUI.
# `?=`, so CI and anyone whose Xcode lives elsewhere can point this at their
# own toolchain from the environment; `:=` would override them.
DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR

CONFIG   ?= release
BUILD    := .build/$(CONFIG)
APP      := .build/Blip.app
ZIP      := .build/Blip.app.zip
INSTALL  := /Applications/Blip.app

ICON     := Resources/AppIcon.icns
ICONCAR  := Resources/Assets.car
ICONSRC  := Resources/AppIcon.icon

.PHONY: all build test app zip run install uninstall icon clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

# Regenerating the icon is deliberately not a dependency of `app`: the compiled
# icon is a checked-in artifact, and rebuilding it on every build would churn a
# binary file for no reason. Run `make icon` when the artwork actually changes.
#
# GenerateIcon writes an Icon Composer bundle; actool compiles it into
# Assets.car, which macOS 26 and later draw, plus the .icns fallback.
icon:
	swift Tools/GenerateIcon.swift "$(ICONSRC)"
	rm -rf .build/icon && mkdir -p .build/icon
	xcrun actool "$(CURDIR)/$(ICONSRC)" --compile "$(CURDIR)/.build/icon" --platform macosx \
		--minimum-deployment-target 14.0 --app-icon AppIcon \
		--output-partial-info-plist "$(CURDIR)/.build/icon/partial.plist" > /dev/null
	cp .build/icon/Assets.car "$(ICONCAR)"
	cp .build/icon/AppIcon.icns "$(ICON)"
	@echo "Built $(ICONCAR) and $(ICON)"

$(ICON) $(ICONCAR):
	$(MAKE) icon

app: build $(ICON) $(ICONCAR)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILD)/Blip" "$(APP)/Contents/MacOS/Blip"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp "$(ICON)" "$(ICONCAR)" "$(APP)/Contents/Resources/"
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
	@pkill -x Blip || true
	open "$(APP)"

install: app
	rm -rf "$(INSTALL)"
	cp -R "$(APP)" "$(INSTALL)"
	@echo "Installed $(INSTALL)"

uninstall:
	@pkill -x Blip || true
	rm -rf "$(INSTALL)"

clean:
	rm -rf .build

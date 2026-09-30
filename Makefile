APP_NAME   := CmdTab
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
ZIP        := $(BUILD_DIR)/$(APP_NAME)-aarch64-apple-darwin.zip
VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
# CI passes its run number; local builds are "1".
BUILD_NUMBER ?= 1
# RELEASE=1 marks the bundle as a release build, which enables self-updating.
RELEASE    ?= 0
RUST_LIB   := core/target/release/libcmdtab_core.a
SWIFT_BIN  := .build/release/$(APP_NAME)
ICON       := $(BUILD_DIR)/AppIcon.icns

# macOS ties Accessibility/Screen Recording grants to the code signature.
# Signing with a stable identity keeps those grants across rebuilds; ad-hoc
# ("-") works too, but you will have to re-grant after every build.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $$2; exit}')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

RUST_SOURCES  := $(shell find core/src -name '*.rs') core/Cargo.toml
SWIFT_SOURCES := $(shell find Sources -name '*.swift' -o -name '*.modulemap') Package.swift core/include/cmdtab_core.h

.PHONY: all app zip core run install test clean version screenshots

all: app

core: $(RUST_LIB)

$(RUST_LIB): $(RUST_SOURCES)
	cargo build --release --manifest-path core/Cargo.toml

$(SWIFT_BIN): $(RUST_LIB) $(SWIFT_SOURCES)
	swift build -c release

$(ICON): scripts/make-icon.swift
	@mkdir -p $(BUILD_DIR)
	swift scripts/make-icon.swift $(BUILD_DIR)/AppIcon.iconset
	iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o $(ICON)

app: $(SWIFT_BIN) $(ICON) Resources/Info.plist
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(SWIFT_BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(BUILD_NUMBER)" $(APP)/Contents/Info.plist
ifeq ($(RELEASE),1)
	/usr/libexec/PlistBuddy -c "Add CmdTabReleaseBuild bool true" $(APP)/Contents/Info.plist
endif
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier app.cmdtab.CmdTab $(APP)
	@echo "Built $(APP) (signed with: $(SIGN_IDENTITY))"

# The release artifact: what CI uploads and Homebrew/the updater download.
zip: app
	@rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@shasum -a 256 $(ZIP)

version:
	@echo $(VERSION)

# README screenshots: the real panel rendered with sample windows (no personal
# data, no permissions needed), placed on a desktop-style background.
screenshots: $(SWIFT_BIN)
	@mkdir -p docs $(BUILD_DIR)/shots
	$(SWIFT_BIN) --demo-snapshot $(BUILD_DIR)/shots/previews.png --dark
	$(SWIFT_BIN) --demo-snapshot $(BUILD_DIR)/shots/search.png --dark --query sl
	$(SWIFT_BIN) --demo-snapshot $(BUILD_DIR)/shots/list.png --dark --list
	for shot in previews search list; do \
		swift scripts/compose-screenshot.swift $(BUILD_DIR)/shots/$$shot.png docs/$$shot.png; \
	done

run: app
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	open $(APP)

install: app
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	open /Applications/$(APP_NAME).app

test:
	cargo test --manifest-path core/Cargo.toml

clean:
	rm -rf $(BUILD_DIR) .build core/target

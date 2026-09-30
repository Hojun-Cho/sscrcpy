APP_NAME  := sscrcpy
VERSION   := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)
# .noindex keeps Spotlight from listing the built app next to the installed one.
BUILD     := build.noindex
APP       := $(BUILD)/$(APP_NAME).app
STAGE     := $(BUILD)/stage/$(APP_NAME).app
ZIP       := dist/$(APP_NAME)-$(VERSION).zip
LOCAL_TAP := local/$(APP_NAME)
SOURCES   := $(shell find Sources/$(APP_NAME) -name '*.swift')

# The app is compiled with swiftc instead of `swift build`: under Command Line
# Tools, SwiftPM's default build system stamps the binary with SDK 14.0, which
# opts the app out of the current macOS look.
# -x drops local symbols, about half the binary; crash logs then show offsets, not names.
SWIFTFLAGS := -Osize -wmo -swift-version 6 -default-isolation MainActor -module-name $(APP_NAME) \
	-Xlinker -dead_strip -Xlinker -x
# Apple silicon only.
TARGET     := arm64-apple-macos14.0

# Command Line Tools ship Swift Testing's macro plugin outside the default search path.
TESTING_PLUGINS := $(shell dirname $$(xcrun --find swift))/../lib/swift/host/plugins/testing

# The mirroring client and the scrcpy Android server it drives.
MIRROR     := mirror
MIRROR_OUT := $(MIRROR)/build/sscrcpy-mirror $(MIRROR)/build/scrcpy-server

.PHONY: app run test dist install clean FORCE

app: $(APP)

# Assembled in $(STAGE) and moved into place last, so a failed build never leaves a
# bundle that make would consider up to date.
# An ad-hoc signature's default requirement is the build's hash; naming the bundle ID
# instead keeps the app's identity across upgrades (Homebrew's signer check, macOS
# privacy permissions such as Local Network).
$(APP): $(SOURCES) Resources/Info.plist Resources/AppIcon.icns $(MIRROR_OUT) $(MIRROR)/scrcpy-server.LICENSE
	rm -rf $(STAGE)
	mkdir -p $(STAGE)/Contents/MacOS $(STAGE)/Contents/Resources
	swiftc $(SWIFTFLAGS) -target $(TARGET) $(SOURCES) -o $(STAGE)/Contents/MacOS/$(APP_NAME)
	cp $(MIRROR)/build/sscrcpy-mirror $(STAGE)/Contents/MacOS/sscrcpy-mirror
	cp Resources/Info.plist $(STAGE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(STAGE)/Contents/Resources/AppIcon.icns
	# scrcpy-server is Apache 2.0, which requires its license alongside.
	cp $(MIRROR)/build/scrcpy-server $(MIRROR)/scrcpy-server.LICENSE $(STAGE)/Contents/Resources/
	codesign --force --sign - -r='designated => identifier "$(BUNDLE_ID)"' $(STAGE)
	rm -rf $@
	mv $(STAGE) $@

# The client's own make runs every time; the app is rebuilt only when that changes its output.
$(MIRROR_OUT): FORCE
	$(MAKE) -C $(MIRROR)

run: app
	open $(APP)

test:
	rm -rf .build/test-fixtures
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

dist: $(ZIP)

# Zips the app for a GitHub release and writes its version and checksum into the cask.
# A file target: zipping the same app again would store new access times and change the
# checksum of an asset that may already be published.
$(ZIP): $(APP)
	mkdir -p dist
	rm -f $@
	ditto -c -k --keepParent $(APP) $@
	sed -i '' -e 's/^  version ".*"/  version "$(VERSION)"/' \
		-e "s/^  sha256 \".*\"/  sha256 \"$$(shasum -a 256 $@ | cut -d ' ' -f 1)\"/" Casks/$(APP_NAME).rb
	@grep -E '^  (version|sha256) ' Casks/$(APP_NAME).rb

# Installs dist/ with Homebrew through a tap that exists only on this Mac, so the cask, its
# dependencies and the quarantine step run as they would for a published release.
install: $(ZIP)
	tap="$$(brew --repository $(LOCAL_TAP))"; \
	test -d "$$tap" || brew tap-new --no-git $(LOCAL_TAP) || exit 1; \
	mkdir -p "$$tap/Casks" && \
	sed 's|^  url ".*"|  url "file://$(CURDIR)/$(ZIP)"|' Casks/$(APP_NAME).rb > "$$tap/Casks/$(APP_NAME).rb" || exit 1; \
	if brew list --cask $(APP_NAME) >/dev/null 2>&1; then \
		brew reinstall --cask $(LOCAL_TAP)/$(APP_NAME); \
	else \
		brew install --cask $(LOCAL_TAP)/$(APP_NAME); \
	fi

clean:
	rm -rf $(BUILD) dist .build

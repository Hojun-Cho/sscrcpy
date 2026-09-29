BUILD   := build
BIN     := $(BUILD)/sscrcpy-mirror
SOURCES := $(wildcard Sources/sscrcpy-mirror/*.swift)

# The client speaks exactly this server's protocol (scrcpy 4.1), so the file is pinned by
# its checksum.
SERVER        := /opt/homebrew/Cellar/scrcpy/4.1_1/share/scrcpy/scrcpy-server
SERVER_SHA256 := deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae

# swiftc instead of `swift build`: under Command Line Tools, SwiftPM stamps binaries with
# SDK 14.0, which opts them out of the current macOS look.
SWIFTFLAGS := -O -swift-version 6 -default-isolation MainActor -module-name sscrcpy_mirror
# Apple silicon only.
TARGET     := arm64-apple-macos14.0

# Command Line Tools ship Swift Testing's macro plugin outside the default search path.
TESTING_PLUGINS := $(shell dirname $$(xcrun --find swift))/../lib/swift/host/plugins/testing

.PHONY: all test clean

all: $(BIN) $(BUILD)/scrcpy-server

$(BIN): $(SOURCES)
	mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -target $(TARGET) $(SOURCES) -o $@

$(BUILD)/scrcpy-server: $(SERVER)
	mkdir -p $(BUILD)
	echo "$(SERVER_SHA256)  $<" | shasum -a 256 -c --quiet
	cp $< $@

test:
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

clean:
	rm -rf $(BUILD) .build

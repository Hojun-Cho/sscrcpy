# sscrcpy

A macOS menu bar app for mirroring Android phones. It runs [scrcpy](https://github.com/Genymobile/scrcpy)'s Android server with its own native Mac client, `sscrcpy-mirror`, which decodes in hardware (VideoToolbox) and used a third of scrcpy's client CPU in a same-input test.

- Pick a USB or Wi-Fi phone from the menu bar and press **Mirror**; **+** pairs Android 11+ phones over Wi-Fi.
- Settings: resolution, bit rate, frame rate, audio, keep awake, screen off, show touches, always on top, and the physical keyboard (on by default; needed for typing, including Korean).
- Mouse buttons reach the phone as themselves: right-click is a right-click.
- Quitting (at the bottom of Settings) stops the adb server if sscrcpy started it, because macOS ties Local Network access to the app that started the server. If Wi-Fi fails with "No route to host", check that no VPN blocks the local network, then press **Restart adb** under the error.

## Install

```sh
brew tap Hojun-Cho/sscrcpy https://github.com/Hojun-Cho/sscrcpy
brew trust --cask hojun-cho/sscrcpy/sscrcpy   # Homebrew 7 loads other taps' casks only once trusted
brew install --cask sscrcpy
```

Apple silicon, macOS 14 or later. It also installs `android-platform-tools`; the app finds `adb` on `PATH` or in `/opt/homebrew/bin`. The app is ad-hoc signed, not notarized, so the cask clears its quarantine flag.

## Build

Needs the Xcode Command Line Tools 26 or later (Swift 6.2); Xcode is not required. The client is in `mirror/`, with its own Makefile and tests.

```sh
make app       # build.noindex/sscrcpy.app, with sscrcpy-mirror and scrcpy-server inside
make run       # build and open it
make test      # unit tests
make install   # install through a Homebrew tap that exists only on this Mac, as a release would
```

`scrcpy-server` is under the Apache License 2.0; its license ships inside the app.

## Release

This repository is its own Homebrew tap: the cask is `Casks/sscrcpy.rb`.

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. `make dist` builds `dist/sscrcpy-<version>.zip` and writes its version and sha256 into `Casks/sscrcpy.rb`.
3. Commit and push.
4. Create the GitHub release `v<version>` with that zip attached.

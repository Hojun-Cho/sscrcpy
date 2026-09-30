cask "sscrcpy" do
  version "0.1.0"
  sha256 "e2f7e174c7cf4e11420e99d3c3240da1fe9f1b35f41331a4316c9ece03847721"

  url "https://github.com/Hojun-Cho/sscrcpy/releases/download/v#{version}/sscrcpy-#{version}.zip"
  name "sscrcpy"
  desc "Menu bar app for mirroring Android phones"
  homepage "https://github.com/Hojun-Cho/sscrcpy"

  depends_on arch: :arm64
  depends_on cask: "android-platform-tools"
  depends_on macos: :sonoma

  app "sscrcpy.app"

  # The app is ad-hoc signed, not notarized, so Gatekeeper would block its first launch
  # after every install and upgrade. This clears the quarantine flag for this app only.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/sscrcpy.app"]
  end

  uninstall quit: "app.sscrcpy"

  zap trash: "~/Library/Preferences/app.sscrcpy.plist"
end

cask "sscrcpy" do
  version "0.1.0"
  sha256 "09c214cefbf43d1692b326c954a0ed24d1474c2beb29af0bcc57a22db70b8f96"

  url "https://github.com/OWNER/sscrcpy/releases/download/v#{version}/sscrcpy-#{version}.zip"
  name "sscrcpy"
  desc "Menu bar frontend for scrcpy"
  homepage "https://github.com/OWNER/sscrcpy"

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

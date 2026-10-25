# Homebrew Cask for bbMusic.
#
# This file lives in the tap repository `dcb9/homebrew-bbmusic`, so once the tap is added:
#
#     brew tap dcb9/bbmusic
#     brew install --cask bbmusic
#
# The one-line form `brew install --cask dcb9/bbmusic/bbmusic` also works (Homebrew taps it for you),
# but it repeats the name because the tap and the cask are both called `bbmusic`.
#
# Why a cask rather than just the zip: the app is ad-hoc signed and not notarized, which needs a
# $99/year Apple Developer account. A browser download carries `com.apple.quarantine`, Gatekeeper then
# reports the app as damaged with no override, and since macOS 15 the old right-click → Open trick is
# gone. The postflight step below strips that attribute, which is Homebrew's documented approach for
# un-notarized binaries and the only install path a user can walk without a security detour.
#
# This cask cannot live in the official `homebrew/cask` repository: that one requires artefacts to
# pass Gatekeeper without a bypass, so an ad-hoc signed app is rejected outright.
cask "bbmusic" do
  version "0.1.0"
  sha256 "cd01194712ccc90b327728314d7659f6113cdd672219f238a7fd7b841b496eba"

  url "https://github.com/dcb9/bbMusic/releases/download/v#{version}/bbMusic-#{version}-arm64.zip"
  name "bbMusic"
  desc "Native macOS QQ Music player with Last.fm scrobbling"
  homepage "https://github.com/dcb9/bbMusic"

  # The bundle is arm64 only: the release workflow builds on Apple Silicon runners.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "bbMusic.app"

  # Without this the app stays quarantined and Gatekeeper refuses the first launch. See the header.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/bbMusic.app"]
  end

  zap trash: [
    "~/Library/Application Support/bbMusic",
    "~/Library/Caches/local.bbmusic.app",
    "~/Library/Preferences/local.bbmusic.app.plist",
    "~/Library/Saved Application State/local.bbmusic.app.savedState",
  ]
end

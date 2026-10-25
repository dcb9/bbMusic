# Homebrew Cask for bbMusic.
#
# This file lives in a separate tap repository named `homebrew-bbmusic`, so the install line is
# `brew install --cask dcb9/bbmusic/bbmusic`.
#
# Why a cask and not just a zip download: the app is ad-hoc signed and not notarized (notarization
# needs a $99/year Apple Developer account). A browser download sets `com.apple.quarantine`, and
# Gatekeeper then reports the app as damaged with no override — and since macOS 15 the old
# right-click → Open trick is gone too. The `postflight` below strips that attribute, which is the
# documented approach for un-notarized binaries and makes `brew install` the one frictionless path.
cask "bbmusic" do
  version "0.1.0"
  sha256 "cd01194712ccc90b327728314d7659f6113cdd672219f238a7fd7b841b496eba"

  url "https://github.com/dcb9/bbMusic/releases/download/v#{version}/bbMusic-#{version}-arm64.zip"
  name "bbMusic"
  desc "Native macOS QQ Music player with Last.fm scrobbling"
  homepage "https://github.com/dcb9/bbMusic"

  # The bundle is arm64 only: the release workflow builds on Apple Silicon runners.
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "bbMusic.app"

  # Without this the app is quarantined and Gatekeeper refuses the first launch. See the header.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/bbMusic.app"]
  end

  zap trash: [
    "~/Library/Application Support/bbMusic",
    "~/Library/Caches/local.bbmusic.app",
    "~/Library/Preferences/local.bbmusic.app.plist",
    "~/Library/Saved Application State/local.bbmusic.app.savedState",
  ]
end

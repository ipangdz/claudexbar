# Homebrew cask for ClaudexBar.
#
# This is the source of truth for the cask. To publish it, copy it into your
# Homebrew tap repository (github.com/ipangdz/homebrew-tap) at
# Casks/claudexbar.rb, then users can install with:
#
#   brew install --cask ipangdz/tap/claudexbar
#
# Update `version` and `sha256` for each release. The release CI publishes
# ClaudexBar.zip and ClaudexBar.zip.sha256 as assets, so the sha256 is the
# value in ClaudexBar.zip.sha256.

cask "claudexbar" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/ipangdz/claudexbar/releases/download/v#{version}/ClaudexBar.zip"
  name "ClaudexBar"
  desc "Menu-bar app showing Codex and Claude Code usage limits"
  homepage "https://github.com/ipangdz/claudexbar"

  depends_on macos: ">= :ventura"

  app "ClaudexBar.app"

  zap trash: [
    "~/Library/Logs/ClaudexBar",
    "~/Library/LaunchAgents/com.ipang.claudexbar.plist",
  ]
end

# Template cask. After the first GitHub Release, put this file in a tap
# (for example homebrew-boltbar/Casks/boltbar.rb) and replace YOUR_GITHUB_USER
# plus the sha256 of Boltbar-0.1.0-universal.zip.
cask "boltbar" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/YOUR_GITHUB_USER/boltbar/releases/download/v#{version}/Boltbar-#{version}-universal.zip"
  name "Boltbar"
  desc "Lightning-fast global chat bar for AI models"
  homepage "https://github.com/YOUR_GITHUB_USER/boltbar"

  app "Boltbar.app"

  zap trash: [
    "~/Library/Application Support/com.boltbar.app",
    "~/Library/Logs/com.boltbar.app",
    "~/Library/Preferences/com.boltbar.app.plist",
  ]
end

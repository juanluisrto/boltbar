# Native macOS release; copy this cask into your own tap if desired.
cask "boltbar" do
  version "0.7.2"
  sha256 "927b414a0522ce5ea04eb7d1a5d340ef5a3869dbf149be2618de00762df1c8f4"

  url "https://github.com/juanluisrto/boltbar/releases/download/v#{version}/Boltbar-#{version}-universal.zip"
  name "Boltbar"
  desc "Native global chat bar for AI models"
  homepage "https://github.com/juanluisrto/boltbar"

  depends_on macos: ">= :ventura"
  app "Boltbar.app"

  zap trash: [
    "~/Library/Application Support/Boltbar",
    "~/Library/Preferences/com.boltbar.native.plist",
    "~/Library/Application Support/com.boltbar.app",
    "~/Library/Logs/com.boltbar.app",
    "~/Library/Preferences/com.boltbar.app.plist",
  ]
end

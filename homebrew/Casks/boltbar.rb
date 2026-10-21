# Native macOS release; copy this cask into your own tap if desired.
cask "boltbar" do
  version "0.7.0"
  sha256 "87c4bc9ef0f0ea6e3da242d4f4a9eab21b0be8172d2bc60663353bc5fe1a0fd4"

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

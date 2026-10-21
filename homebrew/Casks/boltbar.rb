# Native macOS release; copy this cask into your own tap if desired.
cask "boltbar" do
  version "0.7.1"
  sha256 "68bc7f2685c337532eb38e91e6334c7fe84b6aba43cebe7a63c3b210a8f37da6"

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

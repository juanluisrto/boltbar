# Native macOS release; copy this cask into your own tap if desired.
cask "boltbar" do
  version "0.4.1"
  sha256 "9e5e1496b727afc9a902536352cc2dd9988919a9e121f36d85bfca8ac50feed4"

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

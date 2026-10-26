# Copy of Casks/boltbar.rb in the juanluisrto/homebrew-boltbar tap, which Homebrew installs from.
cask "boltbar" do
  version "0.7.3"
  sha256 "2ff7788b55ac6a6ccf21ce489910bf41f12d737c670eb952957605c46ea35ed4"

  url "https://github.com/juanluisrto/boltbar/releases/download/v#{version}/Boltbar-#{version}-universal.zip"
  name "Boltbar"
  desc "Native global chat bar for AI models"
  homepage "https://github.com/juanluisrto/boltbar"

  auto_updates true
  depends_on macos: :ventura

  app "Boltbar.app"

  zap trash: [
    "~/Library/Application Support/Boltbar",
    "~/Library/Application Support/com.boltbar.app",
    "~/Library/Logs/com.boltbar.app",
    "~/Library/Preferences/com.boltbar.app.plist",
    "~/Library/Preferences/com.boltbar.native.plist",
  ]
end

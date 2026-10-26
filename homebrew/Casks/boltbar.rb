# Copy of Casks/boltbar.rb in the juanluisrto/homebrew-boltbar tap, which Homebrew installs from.
cask "boltbar" do
  version "0.7.2"
  sha256 "927b414a0522ce5ea04eb7d1a5d340ef5a3869dbf149be2618de00762df1c8f4"

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

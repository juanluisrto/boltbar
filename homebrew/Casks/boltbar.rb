# Copy of Casks/boltbar.rb in the juanluisrto/homebrew-boltbar tap, which Homebrew installs from.
cask "boltbar" do
  version "0.7.4"
  sha256 "092a811db1779b404890034ea62c2c919d463adc921f65b1e343a6b0cdd25c32"

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

# After the first GitHub Release, put this file in a tap
# (for example homebrew-boltbar/Casks/boltbar.rb) and pin sha256 to
# Boltbar-0.1.3-universal.zip.
cask "boltbar" do
  version "0.1.3"
  sha256 "6248fe3def74f4a0e6929009e1dca557f0df88183172e9eb60bf1875fd0f8c8e"

  url "https://github.com/juanluisrto/boltbar/releases/download/v#{version}/Boltbar-#{version}-universal.zip"
  name "Boltbar"
  desc "Lightning-fast global chat bar for AI models"
  homepage "https://github.com/juanluisrto/boltbar"

  app "Boltbar.app"

  zap trash: [
    "~/Library/Application Support/com.boltbar.app",
    "~/Library/Logs/com.boltbar.app",
    "~/Library/Preferences/com.boltbar.app.plist",
  ]
end

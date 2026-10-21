# Native macOS release; copy this cask into your own tap if desired.
cask "boltbar" do
  version "0.7.1"
  sha256 "8c140569a589950eeefb28475888da4b786edf532af4bd249ecd00e7ccebe5af"

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

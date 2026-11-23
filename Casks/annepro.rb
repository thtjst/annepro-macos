# Homebrew cask for Anne Pro for Mac. Updated automatically by .github/workflows/release.yml.
#
#   brew tap thtjst/annepro-macos https://github.com/thtjst/annepro-macos
#   brew install --cask annepro
cask "annepro" do
  version "1.2.0"
  sha256 "292aa90dd375e181bbf0b2be543c054eebee495d3ee9edcb53a1ddcb34b8aed7"

  url "https://github.com/thtjst/annepro-macos/releases/download/v#{version}/AnnePro-#{version}.zip"
  name "Anne Pro for Mac"
  desc "Control lighting and layouts of the original Anne Pro keyboard over Bluetooth"
  homepage "https://github.com/thtjst/annepro-macos"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "AnnePro.app"
  binary "#{appdir}/AnnePro.app/Contents/Helpers/anne"

  # The app isn't notarized; installing from this tap means you trust it, so skip the
  # Gatekeeper "unverified developer" prompt.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "AnnePro.app"],
        chdir:          ".",
        must_succeed:   false,
        writable_paths: ["AnnePro.app"],
        writable_base:  :appdir
  end

  uninstall quit: "io.github.thtjst.AnnePro"

  zap trash: "~/Library/Containers/io.github.thtjst.AnnePro"
end

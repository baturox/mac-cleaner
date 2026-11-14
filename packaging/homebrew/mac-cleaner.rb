# Homebrew cask template for Mac Cleaner.
#
# This is a TEMPLATE: __VERSION__ and __SHA256__ are filled in by scripts/update-cask.sh
# (from VERSION and dist/SHA256SUMS). The published copy lives in the tap baturox/homebrew-tap.
#
# How to publish it through a personal tap:
#   1. Create the GitHub repository `baturox/homebrew-tap` (the `homebrew-` prefix is required).
#   2. After a GitHub release exists, run `scripts/package.sh` (or download the release's SHA256SUMS
#      into dist/) and then `scripts/update-cask.sh`.
#   3. Copy dist/mac-cleaner.rb to `Casks/mac-cleaner.rb` in the tap repository, commit and push.
#   4. Users then run:  brew install --cask baturox/tap/mac-cleaner
#
# Note: a release that is not notarized is blocked by macOS Gatekeeper (app and bundled CLI).
cask "mac-cleaner" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/baturox/mac-cleaner/releases/download/v#{version}/MacCleaner-#{version}.dmg"
  name "Mac Cleaner"
  desc "Disk cleaner for developers who ship with AI agents"
  homepage "https://github.com/baturox/mac-cleaner"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Mac Cleaner.app"
  binary "#{appdir}/Mac Cleaner.app/Contents/Resources/bin/mac-cleaner"
end

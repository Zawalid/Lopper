# Homebrew cask for Lopper. Lives in the tap repository Zawalid/homebrew-lopper as Casks/lopper.rb.
# `scripts/cask.sh <version>` prints this file with the version and the DMG's SHA-256 filled in.
cask "lopper" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Zawalid/Lopper/releases/download/v#{version}/Lopper-#{version}.dmg"
  name "Lopper"
  desc "Finds the branches, worktrees and generated folders you no longer need, and removes them safely"
  homepage "https://github.com/Zawalid/Lopper"

  depends_on macos: ">= :sonoma"

  app "Lopper.app"

  # Until the app is notarized, macOS quarantines it on first launch. Remove the flag so it opens normally.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Lopper.app"], must_succeed: false
  end

  zap trash: [
    "~/Library/Application Support/Lopper",
    "~/Library/Preferences/com.zawalid.lopper.plist",
    "~/Library/Caches/com.zawalid.lopper",
  ]
end

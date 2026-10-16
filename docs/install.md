# Installing Lopper

Lopper needs **macOS 14 (Sonoma) or later** and **git** on your path. Git comes with the Xcode command line tools:
`xcode-select --install`. The GitHub CLI (`gh`) is optional; with it Lopper can tell when a branch was merged through
a pull request.

## Download (recommended)

1. Open the [latest release](https://github.com/Zawalid/Lopper/releases/latest) and download `Lopper-<version>.dmg`.
2. Open the DMG and drag **Lopper** onto **Applications**.
3. Open Lopper from Applications. The first launch needs one extra step, see below.

You can check the download against the `Lopper-<version>.dmg.sha256` file on the same page:

```bash
shasum -a 256 -c Lopper-0.1.0.dmg.sha256
```

## The first launch (until Lopper is notarized)

Lopper is not yet signed with an Apple Developer ID, so macOS shows "Lopper cannot be opened" the first time. Pick one:

- **Right-click Open.** In Applications, right-click Lopper, choose **Open**, then **Open** again in the dialog.
- **System Settings.** After the first blocked attempt, go to **Privacy & Security**, scroll to the message about
  Lopper and choose **Open Anyway**.
- **Terminal.** One line removes the quarantine flag:

  ```bash
  xattr -dr com.apple.quarantine /Applications/Lopper.app
  ```

You only do this once. Lopper is open source, so you can also read exactly what it does or build it yourself.

## Homebrew

```bash
brew install --cask zawalid/lopper/lopper
```

The cask removes the quarantine flag for you. Upgrade with `brew upgrade --cask lopper`.

## Build from source

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/Zawalid/Lopper.git
cd Lopper
scripts/build-app.sh      # build/Lopper.app
scripts/make-dmg.sh       # build/Lopper.dmg (optional)
```

Drag `build/Lopper.app` to Applications. A build from source is ad hoc signed on your own machine, so it opens without
the first-launch steps above.

## Updating

Lopper does not update itself yet. Download the new DMG and replace the app, or run `brew upgrade --cask lopper`.
Your settings and your undo history are kept between versions.

## Uninstalling

Quit Lopper and move it to the Trash. To remove its data as well:

```bash
rm -r ~/Library/Application\ Support/Lopper
defaults delete com.zawalid.lopper
```

Folders Lopper moved to the Trash are still in the Trash until you empty it. Branches it removed stay restorable from
History for 30 days, so restore anything you want back before you uninstall.

## Where Lopper keeps things

| What | Where |
|---|---|
| Settings | `~/Library/Application Support/Lopper/settings.json` |
| Undo history | `~/Library/Application Support/Lopper/undo-log.jsonl` |
| Preferences (appearance, menu bar, digest) | `~/Library/Preferences/com.zawalid.lopper.plist` |

Lopper never sends any of this anywhere.

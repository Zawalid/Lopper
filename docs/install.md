# Installing Lopper

Lopper needs **macOS 14 (Sonoma) or later** and **git** on your path. Git comes with the Xcode command line tools:
`xcode-select --install`. The GitHub CLI (`gh`) is optional; with it Lopper can tell when a branch was merged through
a pull request.

## Download (recommended)

1. Open the [latest release](https://github.com/Zawalid/Lopper/releases/latest) and download `Lopper-<version>.dmg`.
2. Open the DMG and drag **Lopper** onto **Applications**.
3. Open Lopper from Applications. The first launch needs one extra step, see [the first launch](#the-first-launch).

You can check the download against the `Lopper-<version>.dmg.sha256` file on the same page:

```bash
shasum -a 256 -c Lopper-0.1.0.dmg.sha256
```

## The first launch

Lopper is not signed with an Apple Developer ID, so macOS blocks it the first time ("Apple could not verify Lopper is
free of malware"). You confirm it once and it never asks again:

1. Open Lopper from Applications. When the warning appears, click **Done**. Do not choose Move to Trash.
2. Open **System Settings**, then **Privacy & Security**, and scroll down to the Security section. It says Lopper was
   blocked. Click **Open Anyway**, confirm with your password or Touch ID, then **Open**.

On macOS 15 (Sequoia) and later this is the only way in; right-click, Open no longer works there. On macOS 14 you can
also right-click Lopper in Applications, choose **Open**, then **Open** again.

Prefer the Terminal? One line removes the quarantine flag and skips the warning:

```bash
xattr -dr com.apple.quarantine /Applications/Lopper.app
```

Lopper is open source, so you can also read exactly what it does or build it yourself.

## Homebrew

```bash
brew install --cask zawalid/lopper/lopper
```

Homebrew does not remove the macOS quarantine flag, so the first launch needs the same one-time Open Anyway step as the
download (the cask prints the reminder). Upgrade with `brew upgrade --cask lopper`.

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

Lopper can update itself. In Settings, General, turn on "Check for updates automatically", or choose Lopper, Check for
Updates… at any time. It shows you what is new and installs nothing until you press Install Update. An update installed
this way does not normally ask you to confirm the app again. See [updates.md](updates.md) for exactly what is checked.

You can also download the new DMG and replace the app, or run `brew upgrade --cask lopper`. Your settings and your undo
history are kept between versions.

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

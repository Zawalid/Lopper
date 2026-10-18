# Updates

Lopper can update itself, using [Sparkle](https://sparkle-project.org). It is off until you turn it on.

## What it does

- **Settings, General, Check for updates automatically** is off by default. When it is on, Lopper asks GitHub once a day
  for `releases/latest/download/appcast.xml`, a small file that names the newest version and where to download it.
- **Lopper, Check for Updates…** (and a button in Settings, General and About) asks right now, whether or not the
  automatic check is on.
- If a newer version exists, Sparkle shows the release notes and waits. Nothing is downloaded or installed until you press
  Install Update. There is no silent installation.
- Nothing else is sent. GitHub sees the request the way it sees any download. Lopper has no account and no analytics.

This is the only time Lopper goes online by itself. Everything else it does, it does by running `git` (and `gh`, if you
have it) on your Mac.

## Why an in-app update is not blocked

Lopper is not signed with an Apple Developer ID, so a copy downloaded from the web asks you to confirm it once. Sparkle
downloads updates itself, so the new app carries no download flag and macOS does not ask again. Each update is checked
before it is installed: the zip is signed with an EdDSA key, and the app only accepts a signature that matches the
public key inside it (`SUPublicEDKey`). An archive that was changed, or signed with another key, is refused with
"The update is improperly signed".

## The one trade-off

An app signed ad hoc (no Developer ID team) cannot load Sparkle's framework under the hardened runtime's library
validation, and crashes at launch. Lopper therefore has the entitlement
`com.apple.security.cs.disable-library-validation`, which lets it load libraries signed by other identities. The app is
not sandboxed and does not load plug-ins, and the only library it embeds is Sparkle.

## Homebrew

`brew upgrade --cask lopper` keeps working and is unaffected. The cask does not declare `auto_updates`, so Homebrew still
upgrades it. Pick one way of updating and stay with it.

## For the maintainer

- The signing key was made with Sparkle's `generate_keys --account lopper`. The public half is in `App/project.yml`
  (`SUPublicEDKey`). The private half is in the maintainer's keychain, in `~/.lopper-secrets/sparkle-ed-private-key`
  and in the GitHub secret `SPARKLE_ED_PRIVATE_KEY`.
- **Losing the private key strands every installed copy**: it could never accept an update again, and the only way out
  is a manual download. Keep an offline backup. Anyone who holds the key can ship an update to every install, so it is
  never committed and never printed.
- `scripts/appcast.sh <version>` builds `appcast.xml` and `Lopper-<version>.zip` from `build/Lopper.app`. The release
  workflow runs it and attaches both files to the release.
- Debug builds read `LOPPER_FEED_URL` as the feed, to try an update against a local appcast without publishing one.
- The spike that proved this works (Release builds, ad hoc signed, 0.4.0 to 0.4.1 over a local feed, and a tampered
  archive refused) is on the branch `spike/sparkle`, in `docs/sparkle-spike.md`.

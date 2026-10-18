# Releasing Lopper

How a new version gets from `main` to a download. One command cuts it, one push publishes it.

## Versions

- **Semantic Versioning.** `0.x` while the app is young: a new feature bumps the minor number (0.2.0), a fix bumps
  the patch (0.1.1). `1.0.0` when the safety model and the settings file format are stable.
- **One source of truth.** The version is `MARKETING_VERSION` in `App/project.yml`. `scripts/release.sh` is the only
  thing that changes it.
- **Build number.** The number of commits (`git rev-list --count HEAD`), set by `scripts/build-app.sh`. It only goes up,
  and any two builds of different commits differ. The About pane shows `Version 0.2.0 (214)`.
- **Tags.** Every release is the annotated tag `vX.Y.Z` on `main`. A tag with a dash (`v0.2.0-beta.1`) is published
  as a pre-release.

## Cutting a release

1. Make sure `main` is green (the CI workflow) and the working tree is clean.
2. Write what changed under **Unreleased** in `CHANGELOG.md` as you merge work (Added, Changed, Fixed). If you leave it
   empty, the script writes the notes from `feat:` and `fix:` commit subjects since the last tag.
3. Preview: `scripts/release.sh 0.2.0 --dry-run` prints the release notes and changes nothing.
4. Cut it: `scripts/release.sh 0.2.0`. It runs the engine tests, moves the Unreleased notes under `## [0.2.0]`, bumps
   `MARKETING_VERSION`, commits `chore: release v0.2.0` and tags `v0.2.0`. It never pushes.
5. Publish: `git push origin main --follow-tags`.

The tag starts `.github/workflows/release.yml`: it checks that the tag matches `MARKETING_VERSION`, runs the engine tests,
builds the app, packs `Lopper-0.2.0.dmg`, writes a SHA-256 file and creates the GitHub Release with the changelog entry
as its notes.

## Signing and notarization

Today the app is ad hoc signed, so users do the one-time first-launch step in [install.md](install.md). To remove it you
need an Apple Developer Program membership (99 USD a year) and a **Developer ID Application** certificate. Add these
repository secrets and the same workflow signs and notarizes with no other change:

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | the certificate and private key exported as a `.p12`, base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12` password |
| `DEVELOPER_ID_NAME` | `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_KEY_P8` | an App Store Connect API key (`.p8`), base64 encoded |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | that key's id and the issuer id |

The signing and notarization steps in the workflow have not been run yet; the first signed release is the test, so
cut a pre-release (`0.2.0-beta.1`) first.

## Homebrew

Create the repository `Zawalid/homebrew-lopper` once. After each release, as soon as the release workflow has finished:

```bash
mkdir -p ../homebrew-lopper/Casks
scripts/cask.sh 0.2.0 > ../homebrew-lopper/Casks/lopper.rb
cd ../homebrew-lopper && git add -A && git commit -m "lopper 0.2.0" && git push
```

People install with `brew install --cask zawalid/lopper/lopper`.

## In-app updates

Each release also publishes `appcast.xml` and `Lopper-<version>.zip` (see [updates.md](updates.md)). The workflow builds
them with `scripts/appcast.sh` when the repository secret `SPARKLE_ED_PRIVATE_KEY` is set; without it the release still
publishes, just with no update feed. Check after a release that `releases/latest/download/appcast.xml` opens.

## Later

- Automating the cask update from the release workflow.

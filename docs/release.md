# Release process

`@siteed/capture-helper` is intended to publish both a GitHub release binary and an npm wrapper package.

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/) and is the source of
truth for release notes.

- **Every PR that changes behavior, the CLI, the protocol, packaging, or docs must add an
  entry under `## [Unreleased]`** in the appropriate group (`Added` / `Changed` / `Fixed` /
  `Removed` / `Deprecated` / `Security`). Keep entries user-facing and concise. Trivial
  internal-only changes (refactors with no observable effect, test-only tweaks) may be
  skipped.
- Do not assign a version number in a PR — leave the change under `[Unreleased]`. The
  version is set only at release time (see below).

## Before release

0. **Roll the changelog.** Move everything under `## [Unreleased]` into a new
   `## [X.Y.Z] - YYYY-MM-DD` section, leave an empty `[Unreleased]` above it, and update the
   compare links at the bottom of `CHANGELOG.md`:

   ```text
   [Unreleased]: https://github.com/deeeed/capture-helper/compare/vX.Y.Z...HEAD
   [X.Y.Z]: https://github.com/deeeed/capture-helper/compare/vPREV...vX.Y.Z
   ```


1. Confirm the version matches in `package.json`, `Sources/capture-helper/BuildInfo.swift`, the tests, and the new `CHANGELOG.md` heading.
2. Confirm `NPM_TOKEN` is set in GitHub Actions secrets. The token must publish without OTP in CI.
3. Run local validation:

```bash
swift build -c release
swift test
npm run build:native
npm run doctor
npm pack --dry-run
```

## Tag release

```bash
git tag -a v0.2.0 -m "v0.2.0"
git push origin main
git push origin v0.2.0
```

The release workflow builds a universal macOS binary (arm64 + x86_64), ad-hoc signs it,
attaches `capture-helper-darwin-universal` (+ SHA256 sidecar) to the GitHub release, and
publishes the npm package.

## Verify release

```bash
gh release view v0.2.0 --repo deeeed/capture-helper
npm dist-tag ls @siteed/capture-helper
npm install -g @siteed/capture-helper@latest
capture-helper version
```

## Signing and notarization

Release builds run `scripts/sign-macos-binary.sh`, which ad-hoc signs with hardened
runtime (`codesign -s - --options runtime`). This is sufficient for npm installs (no
quarantine) and for engineers who install via Homebrew.

For curl-downloaded binaries, Gatekeeper may still prompt until the user removes
quarantine (`xattr -d com.apple.quarantine`) or approves in System Settings. Full
Gatekeeper silence requires Developer ID signing + notarization:

```bash
export CAPTURE_HELPER_CODESIGN_IDENTITY="Developer ID Application: …"
npm run build:native
xcrun notarytool submit native/capture-helper --apple-id … --team-id … --password …
xcrun stapler staple native/capture-helper
```

## Maintainer publish checklist (after merge, before tagging)

1. Confirm `CHANGELOG.md`, `package.json`, and `BuildInfo.swift` versions match.
2. Tag and push: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`
3. Wait for the release workflow (GitHub asset + npm publish + tap bump).
4. Verify on a machine **without Swift**:

```bash
npm install -g @siteed/capture-helper@latest
capture-helper doctor --json
brew install deeeed/tap/capture-helper
capture-helper doctor --json
codesign -dv --verbose=2 "$(which capture-helper)"
```

5. Report downstream teach-line updates (do not edit those repos in this PR):
   - farmslot `install.sh`: set default `FARMSLOT_CAPTURE_HELPER_BREW_FORMULA=deeeed/tap/capture-helper`
   - `experimental-metamask-farm/scripts/check-prereqs.sh` and `bootstrap-toolchains.sh`: same brew default

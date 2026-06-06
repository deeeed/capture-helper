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

The release workflow builds a macOS arm64 binary, attaches it to the GitHub release, and publishes the npm package.

## Verify release

```bash
gh release view v0.2.0 --repo deeeed/capture-helper
npm dist-tag ls @siteed/capture-helper
npm install -g @siteed/capture-helper@latest
capture-helper version
```

## Current limitations

- The release workflow currently builds arm64 on `macos-14`.
- Universal binary / x86_64 release packaging is a follow-up.
- Homebrew formula publishing is mirrored into `deeeed/homebrew-tap`.

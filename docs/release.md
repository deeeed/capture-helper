# Release process

`@siteed/capture-helper` is intended to publish both a GitHub release binary and an npm wrapper package.

## Before release

1. Confirm the package version in `package.json`, `Sources/capture-helper/BuildInfo.swift`, and tests match.
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
git tag -a v0.1.8 -m "v0.1.8"
git push origin main
git push origin v0.1.8
```

The release workflow builds a macOS arm64 binary, attaches it to the GitHub release, and publishes the npm package.

## Verify release

```bash
gh release view v0.1.8 --repo deeeed/capture-helper
npm dist-tag ls @siteed/capture-helper
npm install -g @siteed/capture-helper@latest
capture-helper version
```

## Current limitations

- The release workflow currently builds arm64 on `macos-14`.
- Universal binary / x86_64 release packaging is a follow-up.
- Homebrew formula publishing is mirrored into `deeeed/homebrew-tap`.

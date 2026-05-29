# Release process

`@siteed/capture-helper` is intended to publish both a GitHub release binary and an npm wrapper package.

## Before first public release

1. Create the GitHub repository, for example `siteed/capture-helper`.
2. Add an npm automation token as `NPM_TOKEN` in GitHub Actions secrets.
3. Confirm the package version in `package.json` and `Sources/capture-helper/BuildInfo.swift` match.
4. Run local validation:

```bash
swift build -c release
swift test
npm run build:native
npm run doctor
npm pack --dry-run
```

## Tag release

```bash
git tag v0.1.0
git push origin main --tags
```

The release workflow builds a macOS arm64 binary, attaches it to the GitHub release, and publishes the npm package.

## Current limitations

- The release workflow currently builds arm64 on `macos-14`.
- Universal binary / x86_64 release packaging is a follow-up.
- Homebrew formula publishing is a follow-up.

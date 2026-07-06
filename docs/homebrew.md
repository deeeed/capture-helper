# Homebrew tap

The canonical formula lives in the tap repo:

```text
deeeed/homebrew-tap/Formula/capture-helper.rb
```

Install (auto-taps; no separate `brew tap` step):

```bash
brew install deeeed/tap/capture-helper
capture-helper doctor --json
```

The release workflow updates the tap on each tagged release. The formula downloads
`capture-helper-darwin-universal` from GitHub releases (arm64 + x86_64).

There is no repo-local formula copy in `capture-helper` — the tap is the single source
of truth. Update `version`, `url`, and `sha256` only in `deeeed/homebrew-tap` (or via the
release workflow when `HOMEBREW_TAP_TOKEN` is configured).
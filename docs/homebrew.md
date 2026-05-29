# Homebrew tap notes

A draft formula lives at `Formula/capture-helper.rb`.

To publish it, create or reuse a tap repo, for example:

```bash
gh repo create deeeed/homebrew-tap --public
```

Then copy the formula into that tap:

```text
homebrew-tap/
  Formula/
    capture-helper.rb
```

Users can then install with:

```bash
brew tap deeeed/tap
brew install capture-helper
```

The current formula is arm64-only and points at the GitHub release binary for `v0.1.1`. Update both `url` and `sha256` for every release.

# Troubleshooting

## `Code=-3801 "The user declined TCCs for application, window, display capture"`

This means macOS Screen Recording permission is denied for the app that launched `capture-helper`.

Open the permission pane:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Then grant permission based on how the helper is launched:

- Local shell: enable Terminal, iTerm, Codex, or whichever app owns the shell.
- SSH shell: enable `/usr/libexec/sshd-keygen-wrapper`.

If macOS is stuck on a previous denial, reset the Screen Recording decision and try again:

```bash
tccutil reset ScreenCapture
capture-helper doctor --json
```

After changing the permission, restart the launching app or SSH session and run:

```bash
capture-helper doctor --json
capture-helper list
```

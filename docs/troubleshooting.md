# Troubleshooting

## `Code=-3801 "The user declined TCCs for application, window, display capture"`

This means macOS Screen Recording permission is denied for the app that launched `capture-helper`.

Open the permission pane:

```bash
capture-helper doctor --request-permission --open-permissions
```

Then grant permission based on how the helper is launched:

- Desktop UI or agent host: enable that app, not Terminal. If Terminal passes `doctor` but the UI still fails, the UI app needs its own Screen Recording grant.
- Local shell: enable Terminal, iTerm, Codex, or whichever app owns the shell.
- SSH shell: enable `/usr/libexec/sshd-keygen-wrapper`.

If macOS is stuck on a previous denial, reset the Screen Recording decision and try again:

```bash
tccutil reset ScreenCapture
capture-helper doctor --request-permission --open-permissions
```

After changing the permission, restart the launching app or SSH session and run:

```bash
capture-helper doctor --json
capture-helper list
```

# LimitBar

Touch Bar + menu bar monitor for AI coding-plan limits on macOS (built for a MacBook Pro M1 with Touch Bar).

- **Limits** — Claude (Pro/Max subscription), Codex (ChatGPT plan): 5-hour and weekly usage, reset countdowns, colour warnings at 75% / 90%.
- **Hermes** — live view of Hermes Agent sessions (working / done / idle, what each is doing); tap to open a session in the Hermes desktop app.
- **Mac stats** — CPU, RAM (Activity Monitor's "Memory Used"), battery.
- **Notifications** — limit at 90% / reached, Hermes session finished, Claude login about to expire.
- Keeps the system Control Strip, ~50 MB RAM.

## Build

```sh
cd LimitBar
./build.sh                     # -> build/LimitBar.app (ad-hoc signed)
cp -R build/LimitBar.app /Applications/
```

Icon: `swift tools/make_icon.swift /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns`.

## Credentials

Nothing is stored in this repo. At runtime LimitBar reads:

- Claude: the `Claude Code-credentials` keychain item (refreshed automatically before expiry)
- Codex: `~/.codex/auth.json` or `~/Library/Application Support/LimitBar/codex-auth.json`

Uses private DFRFoundation / NSTouchBar APIs to present a system-modal Touch Bar — not App Store material.

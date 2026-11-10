# LimitBar

**A Touch Bar and menu-bar monitor on macOS for AI coding-plan limits (Claude, Codex), Hermes Agent sessions and Mac vitals.**

Built for a MacBook Pro M1 with a Touch Bar. It puts the 5-hour and weekly usage windows on the Touch Bar so you can see when a limit is coming before you hit it. The system Control Strip stays where it is, and the app uses about 50 MB of RAM.

## Features

- **Plan limits:** Claude (Pro / Max 5x / Max 20x subscription) and Codex (ChatGPT plan). Shows 5-hour and weekly usage, a pace marker, and reset countdowns. Bars turn orange at 75% and red at 90%. The overview shows one pinned AI; tap it to open the "Show on bar" picker and choose which one to pin.
- **Claude login keeper:** refreshes the Claude Code OAuth token about 45 minutes before it expires, so the login stays valid even if `claude` isn't run.
- **Claude account switcher** (optional): tap Claude → **Account** chips to switch between saved logins. Each chip shows days left on that login, orange at ≤ 3 days and red when expired.
- **Hermes sessions:** a live list of Hermes Agent sessions across all profiles (● working / ✓ done / · idle, plus what each one is doing). Swipe through them and tap one to open it in the Hermes desktop app.
- **Mac stats:** CPU, RAM (the same "Memory Used" figure as Activity Monitor) and battery, read straight from the kernel without subprocesses.
- **Local AI + AI Tools** (optional): start or stop a local Ollama model, and switch local AI tools on or off (speech to text, text to speech, remove BG, upscale, …).
- **Candie & Dior:** two vector toy poodles drawn in code that live in a Touch Bar yard. Feed, play, pet, clean, bath and medicine buttons, plus bond levels, outfits and tricks. They react to the Mac (CPU sweat, AC zoomies, limit-reset party).
- **Notifications:** a limit reached 90% or ran out, a Hermes session finished, a Claude login is about to expire.

## Touch Bar layout

```
overview : [Claude|Codex]  [Hermes now]  [cpu ram bat]  [pet]     | control strip
detail   : [‹][logo plan][5h ▬▬|▬ pace][weekly ▬|▬▬ pace][extras]
sessions : [‹][● working …][✓ done …][· idle …]   (swipe, tap = open in Hermes)
```

## Requirements

- A Mac with a Touch Bar. The menu-bar item also works without one.
- Xcode Command Line Tools (`swiftc`)
- Claude Code signed in (`claude auth login`) and/or Codex CLI signed in

## Build & install

```sh
cd LimitBar
./build.sh                     # -> build/LimitBar.app (ad-hoc signed)
cp -R build/LimitBar.app /Applications/
```

Open it from `/Applications`. It runs as a menu-bar agent with no Dock icon. **Settings** has the refresh interval (30 s / 1 / 2 / 5 min), notifications on/off and **Launch at login** (installed as a LaunchAgent because the app is ad-hoc signed).

Rebuild the icon:

```sh
swift tools/make_icon.swift /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns
```

## Credentials & data

The repo contains no credentials. At runtime LimitBar reads:

| Source | Used for |
|---|---|
| `Claude Code-credentials` keychain item (+ `~/.claude/.credentials.json`) | Claude usage, token refresh |
| `~/.codex/auth.json` or `~/Library/Application Support/LimitBar/codex-auth.json` | Codex usage |
| Hermes profile `state.db` files (read-only) | Hermes sessions |
| `~/.hermes/bin/claude-akun` + `~/.hermes/claude-akun.json` | Account switcher (only appears when it's installed and more than one account is saved) |
| `~/Code/local-ai/` (`models.json`, `extras.json`) | Local AI / AI Tools chips |

Settings live in `~/Library/Application Support/LimitBar/config.json`.

## Project structure

```
LimitBar/
├── main.swift            # AppDelegate, Touch Bar modes, menu
├── DFR.swift             # private DFRFoundation bridge (system-modal Touch Bar)
├── Providers.swift       # Claude / Codex usage fetchers
├── ClaudeAuth.swift      # OAuth refresh
├── ClaudeAccounts.swift  # account switcher
├── Hermes.swift          # session reader
├── Stats.swift           # CPU / RAM / battery
├── LocalAI.swift, Extras.swift
├── Pet.swift             # Candie & Dior
├── Views.swift, Settings.swift, Advisor.swift
└── build.sh
```

## Status

A personal tool at v2.5. It's ad-hoc signed and not notarized, so the first launch may need right-click → **Open**. It uses private DFRFoundation / NSTouchBar APIs, which rules out the App Store, and a macOS update could break it.

---

Built by [Melvern Mogens](https://github.com/MelvernMogens).

# Isle

A macOS dynamic-island utility for the notch: now playing with synced lyrics, calendar agenda, AirDrop and Shelf drop targets, device pop-ups, an AI-agents usage tab, and a display-only now-playing card on the lock screen. Menu-bar only; the app icon is an oasis and shows in the Dock while Settings is open.

## Build and install
    ./build.sh            # release build -> build/Isle.app (signed with a stable local identity so permissions persist)
    ./build.sh --test     # unit tests (206)
    ./build.sh --install  # build, copy to /Applications, relaunch
    ./build.sh --debug    # debug build

Developer flags: `--demo` (fake playback), `--simulate-lock` (lock card in a normal window), `--expand [home|airdrop|shelf|agents]`, `--debug-control` (scripted control), `--lyrics-probe "Title|Artist|Album|Seconds"`.

## Permissions
Calendar (agenda), Automation (Spotify / Music control), Bluetooth (device pop-ups). Nothing else. Not sandboxed.

## Now Playing
"System (any app)" uses a small helper (`Helper/isle_nowplaying.m`, original code) loaded into Apple's `/usr/bin/perl`, because recent macOS only answers MediaRemote for Apple-signed processes. If that ever stops working, Isle says so and you can pick Spotify or Apple Music, which use AppleScript and their notifications. Spotify cover art comes from the system helper (no network fetch).

## Lyrics privacy
Off by default. When on, the song's title, artist, album and duration are sent to LRCLIB (lrclib.net) with an identifying User-Agent. Audio is never sent. Nothing is sent while it is off. Results are cached on disk.

## Lock screen (private API caveat)
Off by default. Third-party windows cannot normally appear on the lock screen, so Isle uses private SkyLight window-space functions, loaded with dlopen/dlsym at runtime inside `LockWindowElevator.swift` only. If a symbol is missing the feature disables itself and Settings says so. The card ignores all mouse input, never becomes key, and has no controls. **The real lock screen is unverified until you check it**: play a song, lock with Control-Command-Q, and look near the bottom center.

## AI agents (privacy)
Off by default. Reads only local metadata from Claude Code, Codex, OpenCode and Copilot session files: timestamps, model names, token counts, project folder name, session id. Never prompt text, responses, file contents or tool output. No network access. Plan limits appear only when the agent itself reports them (Codex logs them); otherwise "Limit data not available".

## Extra live activities and widgets
- **Cover and equalizer** beside the notch while playing; **mic / camera / screen-recording dots** (read from system signals, no content); **charging** readout; **browser downloads** (watches ~/Downloads for partial-file names and sizes only; macOS asks for Files and Folders access).
- **Full screen:** while the frontmost app is in a full-screen Space, the cover, equalizer and song banner stay off.
- **Weather** (opt-in): sends the city you type, then its coordinates, to Open-Meteo (open-meteo.com, free, no key, no location permission; "Weather data by Open-Meteo.com"). Nothing is sent while off.
- **Lock screen widgets** (opt-in): weather, charging and connected Bluetooth batteries, display only, same private-API caveat as the lock card.
- **Themes:** Classic, Minimalistic, Frutiger Aero (Settings > Look).

## Animations
Settings > Animations: master switch, style (Smooth / Snappy / Bouncy / Minimal), speed, and a switch for each group (island opening, content fade, tabs, artwork/media, lyrics, banner flip, button press). Reduce Motion is respected. All timings live in `Sources/IsleCore/Motion.swift`.

## Known limits
- The next/previous controls in System mode depend on the playing app; shuffle is hidden there.
- AirDrop device lists are not available to apps; the system sheet picks the recipient.

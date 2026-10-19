# Isle

A macOS dynamic-island utility for the notch: now playing with synced lyrics, calendar agenda, AirDrop and Shelf drop targets, device pop-ups, an AI-agents usage tab, and a display-only now-playing card on the lock screen. Menu-bar only; the app icon is an oasis and shows in the Dock while Settings is open.

## Build and install
    ./build.sh            # release build -> build/Isle.app (signed with a stable local identity so permissions persist)
    ./build.sh --test     # unit tests (259)
    ./build.sh --install  # build, copy to /Applications, relaunch
    ./build.sh --debug    # debug build

Developer flags: `--demo` (fake playback), `--simulate-lock` (lock card in a normal window), `--expand [home|shelf|agents]`, `--debug-control` (scripted control), `--lyrics-probe "Title|Artist|Album|Seconds"`.

## Install with Homebrew
    brew install --cask ranvirskh/isle/isle     # or: brew tap ranvirskh/isle, then brew install --cask isle
    brew upgrade --cask isle                    # after a new release

The app is signed with a local identity and is not notarized: on first open, right-click it and choose Open.

## Permissions
Calendar (agenda), Automation (Spotify / Music control), Bluetooth (device pop-ups), and Location only if you turn on weather from your Mac's location. Nothing else. Not sandboxed.

## Now Playing
"System (any app)" uses a small helper (`Helper/isle_nowplaying.m`, original code) loaded into Apple's `/usr/bin/perl`, because recent macOS only answers MediaRemote for Apple-signed processes. If that ever stops working, Isle says so and you can pick Spotify or Apple Music, which use AppleScript and their notifications. Spotify cover art comes from the system helper (no network fetch).

## Lyrics privacy
Off by default. When on, the song's title, artist, album and duration are sent to LRCLIB (lrclib.net) with an identifying User-Agent. Audio is never sent. Nothing is sent while it is off. Results are cached on disk.

## Lock screen (private API caveat)
Off by default. Third-party windows cannot normally appear on the lock screen, so Isle uses private SkyLight window-space functions, loaded with dlopen/dlsym at runtime inside `LockWindowElevator.swift` only. If a symbol is missing the feature disables itself and Settings says so. The card ignores all mouse input, never becomes key, and has no controls. **The real lock screen is unverified until you check it**: play a song, lock with Control-Command-Q, and look near the bottom center.

## AI agents (privacy)
Off by default. Reads only local metadata from Claude Code, Codex, OpenCode and Copilot session files: timestamps, model names, token counts, project folder name, session id. Never prompt text, responses, file contents or tool output. The agents scan itself has no network access. Plan limits appear only when the agent itself reports them (Codex logs them); otherwise "Limit data not available".

## Extra live activities and widgets
- **Cover and equalizer** beside the notch while playing; **mic / camera / screen-recording dots** (read from system signals, no content); **charging** readout; **browser downloads** (watches ~/Downloads for partial-file names and sizes only; macOS asks for Files and Folders access).
- **Full screen:** while the frontmost app is in a full-screen Space, the cover, equalizer and song banner stay off.
- **Weather** (opt-in): sends your Mac's location (if you allow it) or the city you type, then its coordinates, to Open-Meteo (open-meteo.com, free, no key; "Weather data by Open-Meteo.com"). Nothing is sent while off.
- **Lock screen widgets** (opt-in): weather, charging and connected Bluetooth batteries, display only, same private-API caveat as the lock card.
- **Themes:** Classic, Minimalistic, Frutiger Aero (Settings > Look).

## Optional tabs and shortcuts (all off by default, Settings > Look)
- **Tools:** Keep Awake (power assertion, 15 minutes to 4 hours or until turned off).
- **Clipboard:** last 12 copied texts, memory only, never written to disk; copies that password managers mark as concealed or transient are skipped.
- **System:** CPU, memory, network and disk, sampled once a second only while the tab is open.
- **Reminders:** open Apple Reminders soonest first, tick them off (asks for Reminders access).
- **Mirror:** camera preview; the camera runs only while the tab is open (asks for Camera access).
- **Scripts:** shell commands you save in Settings and run by clicking them; `/bin/zsh`, 30 second limit, output shown in the tab.
- **Volume and brightness indicator:** replaces the macOS overlay. A session event tap (Accessibility permission) sees the media keys, sets the level (CoreAudio for volume, private DisplayServices for brightness, private CoreBrightness for the keyboard backlight), swallows the key and shows a level bar. Keys it cannot act on pass through to macOS. Step size per press is adjustable. The microphone level is shown when it changes.
- **Tab order, parallax hover, welcome tour, update check** (a daily request to GitHub's releases API, opt-in, or "Check now").
- **AirPods banner:** macOS draws it from Notification Center (`com.apple.BluetoothUIServer`) and offers no way to hide it from an app; turn off Bluetooth notifications in System Settings > Notifications (Settings has a button).

- **Global shortcuts:** Control-Option-Space opens or closes the island; Control-Option-1 to 6 pick a tab.
- **External displays:** the island appears only on the built-in display unless "Show the island on external displays" is on.

## Animations
Settings > Animations: master switch, style (Smooth / Snappy / Bouncy / Minimal), speed, and a switch for each group (island opening, content fade, tabs, artwork/media, lyrics, banner flip, button press). Reduce Motion is respected. All timings live in `Sources/IsleCore/Motion.swift`.

## Claude plan usage
On by default (Settings > Agents). Shows 5-hour and weekly usage as a header chip. The readout follows activity, not which app is in front: **while anything is actively spending your Claude limit** (a Claude Code session that wrote to its log in the last 90 seconds, in any terminal, editor, or the Claude app's Code tab, even in the background while you work in another app; or the Claude app in front), the 5-hour limit is shown at any level in the chip and the collapsed notch, and from 90% the percentage and time left appear beside the notch. When nothing is using Claude, the notch stays plain black, the weekly limit stays in the chip, and the 5-hour limit appears only once it passes 50%. Activity is detected from file-system events on Claude's session folders (only the time of a write is used; the logs are never opened). It reads your Claude Code sign-in token from the Keychain (macOS asks once) and calls Anthropic's usage endpoint every 5 minutes and when the island opens. Only percentages and reset times are kept; the token is never stored or logged. The endpoint is undocumented and may change.

## Battery
Everything is event driven where macOS allows it. The remaining timers all use tolerances so macOS can batch wake-ups:
clipboard (1 s, only if enabled), system stats (1 s, only while that tab is open; 2 s in Low Power Mode), screen-recording check (3 s; 6 s in Low Power Mode; stopped while the display sleeps), Claude usage (5 min, backs off on 401/429 and in Low Power Mode). Mouse-move events are merged to about 30 per second.

## Known limits
- The next/previous controls in System mode depend on the playing app; shuffle is hidden there.
- AirDrop device lists are not available to apps; the system sheet picks the recipient.

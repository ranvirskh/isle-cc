# Feature gap: what Atoll has that Isle lacks

Sources (read as data only): the Atoll README on GitHub (Ebullioscopic/Atoll), its release notes (v2.3.x alpha, beta and
stable, via newreleases.io), the getatoll.app front page (no feature detail), and a look at Atoll 2.3.3 running on this Mac.

Isle already has: media with synced lyrics, calendar agenda with day navigation, AirDrop and Shelf, Bluetooth and power
pop-ups, AI agents tab, lock screen media card, mic/camera/screen-recording indicator, cover and equalizer live activity,
song-change tab, per-animation options.

## Status after you chose

Built: charging live activity (5 s), downloads live activity, weather (device location or typed city), Minimalistic and
Frutiger Aero themes, lock screen widgets (weather, charging, Bluetooth batteries). Not chosen and not built: everything else in the table.

## Missing features

| # | Feature | What it is | Needs | Difficulty | Risk |
|---|---|---|---|---|---|
| 1 | Clipboard history | Last N copied items in a tab, click to paste again | Polls the pasteboard change count (no permission) | Medium | Copies can contain passwords. Would keep in memory only, skip concealed/transient types, never write to disk. |
| 2 | System stats panel | Live CPU, GPU, memory, network, disk | Public APIs (host_statistics, IOKit, getifaddrs); no permission | Medium | Low. Sampling only while the tab is open. |
| 3 | CPU temperature | Temperature in the stats panel | SMC access (private, changes between Macs and macOS versions) | High | **Private API**; may break. Optional, off by default. |
| 4 | Timers and Pomodoro | Countdown with a live activity in the notch | No permission (notification permission if you want an alert) | Small to medium | Low |
| 5 | Color picker | Pick any pixel color, copy hex | `NSColorSampler` (public); no permission | Small | Low |
| 6 | Keep Mac awake | Cup button, indefinite or 15 min to 4 h | Power assertion (public) | Small | Low |
| 7 | Downloads live activity (beta in Atoll) | Progress while a file downloads | Watches ~/Downloads (Files and Folders permission) | Medium | Browsers differ in how they name partial files. |
| 8 | Weather | Weather on Home and the lock card | **Network** (Open-Meteo, no key) and a city or Location permission | Medium | Sends your coarse location to a third party. Opt-in. |
| 9 | Focus / Do Not Disturb indicator | Shows the current Focus | No public API. Reading the state needs Full Disk Access or a private API | High | **Private/fragile**; permission heavy. |
| 10 | Lock screen widgets: timers, charging, Bluetooth, weather | More cards on the lock screen like Atoll | Uses the existing private lock-screen window; weather needs network | Medium | Reveals more on a locked screen. Display only. |
| 11 | Notch gestures | Two-finger swipe to open/close, horizontal swipe for next/previous | Scroll-wheel event monitor; Atoll asks for Accessibility | Medium | Low; permission may be needed on some macOS versions. |
| 12 | Global shortcuts and remapping | Hotkeys to open the island, switch tabs, play/pause | Carbon hotkeys (public); no permission | Small | Low |
| 13 | Themes: Minimalistic and Frutiger Aero looks | Alternate visual styles | None | Medium | Low |
| 14 | Parallax hover | Content shifts slightly with the cursor | None | Small | Low |
| 15 | Charging live activity | Charging state shown in the collapsed notch | None (data already read) | Small | Low |
| 16 | Embedded terminal tab | A shell inside the island | Spawns a pseudo-terminal | Medium to high | A keyboard-capturing panel needs focus, which the island avoids. |
| 17 | System volume / brightness HUD replacement | Show volume and brightness in the notch instead of the macOS HUD | Event tap (Accessibility) and private brightness APIs | High | **Private API** and an input-capturing permission. |
| 18 | Onboarding and a larger settings layout | First-run walkthrough | None | Small | Low |

## Not recommended

| Feature | Why |
|---|---|
| Screen Assistant (AI) | Sends screen contents to an AI service and needs an account or API key. Conflicts with the no-credentials, no-tracking rules. |
| Spotify Canvas (looping artwork videos) | Only available through a Spotify login cookie or token. Never. |
| Anything that reuses another app's login, token, key or cookie | Same reason. |

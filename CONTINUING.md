# Picking Isle up again

## Get going
    git clone https://github.com/ranvirskh/isle-cc.git && cd isle-cc     # or just `cd ~/isle-cc`
    ./build.sh --test      # 240 unit tests, about a second
    ./build.sh --install   # build, copy to /Applications, relaunch
    ./build.sh --debug     # faster build into build/Isle.app (run it with flags, see README)

Requires macOS 14+ and the Xcode command line tools (Swift 5.9+). The first build creates a local signing identity so
permissions (Calendar, Automation, Bluetooth, Location) survive rebuilds.

## Where things live
- `Sources/IsleCore`: pure logic with the unit tests (state machines, parsers, lyrics, agents, weather, downloads, motion constants). Change behavior here first and add a test.
- `Sources/Isle`: the app (window, SwiftUI views, controllers that talk to macOS). `IslandController` runs the notch, `IslandRootView` draws it.
- `Helper/`: the now-playing helper that is loaded into Apple's perl. `tools/`: icon generator and dev helpers.
- All animation timings are in `Sources/IsleCore/Motion.swift`; see `ANIMATIONS.md` for what they were matched to.
- `FEATURE_GAP.md` lists Atoll features not built yet (clipboard history, system stats, timers, color picker, keep-awake, gestures, shortcuts, and more).

## Continue with Claude Code
    cd ~/isle-cc && claude --continue      # resumes the last conversation here, or:
    cd ~/isle-cc && claude                 # fresh session; ask it to read README.md, CONTINUING.md and ANIMATIONS.md first

Good first prompts: "Build the clipboard history from FEATURE_GAP.md", "Check the lock screen widget position", "Tune the open animation".
Tell it to run `./build.sh --test` after each change and to verify visuals with the tools in `tools/dev`.

## Still unverified (needs you)
1. Real lock screen: play a song, lock with Control-Command-Q. Check the card (bottom center) and the widgets (screen center) do not cover the clock, avatar or password field.
2. Full screen: with a video or browser tab in a full-screen Space, the cover, equalizer and song banner should stay off.
3. Weather from your Mac's location: turn it on in Settings and allow the macOS location prompt.
4. Microphone and camera dots with a real call; device connect pop-up with a new Bluetooth device; display plug/unplug and sleep/wake.
5. Whether open and close feel smooth enough on your ProMotion display (measured at 60 fps in recordings).

## Known limits
- Claude Code plan limits (5-hour, weekly) come from Anthropic's undocumented usage endpoint using the Claude Code token in your Keychain (v1.1, opt out in Settings). It may change or break. Codex limits come from its own logs.
- System-mode shuffle is hidden (the system does not report it).
- Atoll's cover-flying open animation and device/drag animations were not matched.

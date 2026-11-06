# Installing Athan App Mac (for AI agents)

Athan App Mac is a macOS menu-bar app (Swift Package, no Xcode project). If a user asks you to install it:

1. Check the requirements: macOS 14 or later (`sw_vers -productVersion`) and a Swift toolchain (`xcrun --find swift`). If Swift is missing, run `xcode-select --install` and ask the user to finish that install.
2. Install:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/APasha1/AthanAppMac/main/install.sh | bash
   ```
   This clones to `~/.athan-app-mac`, runs `build.sh` (a release build, a codesigned `.app`, copied to `/Applications`, or `~/Applications` if that isn't writable) and opens the app.
3. Verify it's running: `pgrep -x AthanAppMac`.
4. Tell the user to look at their notch and to allow **Location** (or set a city in Settings), plus **Calendars** if they want it quiet in meetings. These permission prompts need the user to click. You can't approve them.

## Configuring it from the terminal (optional)

Settings live in the `com.abdullahpasha.prayerisland` defaults domain. Quit the app first (`pkill -x AthanAppMac`), write the setting, then `open "/Applications/Athan App Mac.app"`.

| Key | Values |
|---|---|
| `method` | `isna`, `mwl`, `karachi`, `makkah`, `egypt`, `dubai`, `singapore`, `turkey` |
| `madhab` | `standard` (Shafiʿi/Maliki/Hanbali) or `hanafi` |
| `useAutoLocation`, `latitude`, `longitude`, `placeName` | a fixed location, e.g. `useAutoLocation -bool false; latitude -float 51.5072; longitude -float -0.1276; placeName "London"` |
| `adjustments` | per-prayer minutes, e.g. `-dict fajr -int 1 isha -int -2` |
| `skipFridayDhuhr` | bool |
| `fridayDuaMinutes` | `0`, `30`, `60`, `90` |
| `endReminderMinutes`, `preReminderMinutes` | minutes, `0` = off |
| `hideFromCapture`, `openOnHover`, `showWings` | bool |

## Developing

- `./build.sh` builds and installs. `swift build` is enough just to compile.
- `.build/release/AthanAppMac --snapshot <dir>` renders every island state to PNGs (it's how the README screenshots are made).
- `ATHAN_APP_MAC_CAPTURABLE=1` makes the island visible to screen capture while debugging.

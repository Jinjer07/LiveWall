# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [SemVer](https://semver.org/).

## [1.6.0] — 2026-11-24

Most of this release was contributed by [@Nanda070](https://github.com/Nanda070) in [#1](https://github.com/Jinjer07/LiveWall/pull/1).

### Added
- **Snow tab:** snow over the desktop. Three depth layers, gusty wind, crystals on the nearest flakes, soft drifts on the top edges of windows that move with the window, the cursor pushes flakes and sweeps drifts, string lights under the menu bar. The transparent layer never catches clicks. Off by default.
- **Separate pause settings for snow and wallpapers** (battery, full-screen app, maximized window, lock and sleep), on the Snow tab. Snow also stops under Reduce Motion and halves its density in Low Power Mode.
- **Multi-select in the library:** Cmd-click, Shift-click, Cmd+A and a selection bar (favorite, delete). **Cmd+Backspace** deletes the selection after a confirmation; the files go to the Trash.
- **Playlists start on launch** (the last active one, or the last chosen one if no wallpaper is set) instead of after the first interval.

### Fixed
- **Huge text in imported Wallpaper Engine scenes** (“Date” and “D a y” overlapping): for tall text boxes the font size came from the box height. They now use `pointsize`, and sizes are clamped to the editor's range. Re-import affected scenes to apply the fix.
- **Delay when clicking a wallpaper:** the pair of single-click and double-click handlers made SwiftUI wait out the double-click interval. Selection is now instant.
- **Cmd+Backspace in the library search field** no longer opens “Delete selected wallpapers?”. The shortcut only works while the wallpaper grid has focus, so in text fields it deletes to the start of the line as usual.

### Docs
- All documentation is now in English; the Russian README is in [README.ru.md](README.ru.md).

## [1.5.0] — 2026-11-24

### Added
- **Pause when another app is focused** (Settings → Performance). Wallpapers play only while you are on the desktop (Finder) or in LiveWall. Off by default.

### Fixed
- **The “Find” button for the weather city:** on macOS 27 the text field in Settings was invisible, so the search looked broken. The field now has a border and a hint, Enter searches too, and the button is disabled while the field is empty.
- The same fix for invisible text fields in Workshop (Steam login, steamcmd path, ID/link), Playlists (name) and the scene editor (layer name, text).

## [1.4.1] — 2026-11-24

### Performance
- The audio meter on the “Now” card and the pulsing LIVE dot are drawn with Core Animation layers and no longer redraw the SwiftUI interface. CPU with the window open dropped from about 17% to 4%.

## [1.4.0] — 2026-11-24

Testing and fixes on macOS 27.

### Changed
- **Audio reactivity through a Core Audio system tap** (macOS 14.2+): only the “System Audio Recording Only” permission is needed instead of “Screen Recording”, and the screen is not captured. Older systems keep using ScreenCaptureKit.

### Fixed
- **Two copies of the app at once** (window restoration after a reboot plus launch at login): wallpapers were drawn twice and the load doubled. The second copy now hands over to the first and quits.
- **Signing out of Steam** no longer touches the regular Steam client's files; it only resets the sign-in of the steamcmd that LiveWall installed.
- **Workshop wallpapers you deleted** no longer come back on sync; “Import all” brings them back explicitly.
- **False Steam sign-in errors:** only steamcmd lines with `FAILED (…)` and `ERROR!` count as errors.
- **Black covers** for wallpapers whose Workshop preview is a GIF with a dark first frame: the middle frame is used.
- **Interface:** wrapping of “Library” and its counter in the sidebar, pages overlapping while switching sections, wrapping of the “Sync Workshop” button, system buttons in Workshop restyled to match the app, Settings shows the real version instead of “LiveWall 1.0”.
- **Install instructions** for macOS 15+ (Gatekeeper: “Open Anyway”).

## [1.3.1] — 2026-11-24

### Fixed
- The system prompt “LiveWall would like to record the screen and audio” no longer appears on every launch. Without permission, LiveWall quietly shows “Grant access” and “Relaunch LiveWall” buttons in Settings, and the macOS prompt appears only when you press them or turn on audio reactivity.

## [1.3.0] — 2026-11-24

### Added
- **Steam sign-in inside LiveWall**, no Terminal needed: username and password, then a Steam Mobile confirmation or a Steam Guard code. Under the hood the official steamcmd runs in a hidden pseudo-terminal; the password goes only to it and is never stored.
- **One-click steamcmd install** (Valve's official archive, no Homebrew).
- **“Sync Workshop”**: LiveWall fetches your Wallpaper Engine subscriptions itself (through a built-in steamcommunity.com window, QR sign-in from Steam Mobile), downloads new ones, converts scenes and adds everything to the “Wallpaper Engine” playlist.
- “Sign out” clears the saved steamcmd sign-in and Steam cookies.

## [1.2.2] — 2026-11-24

### Fixed
- macOS no longer asks for permissions (“Screen & System Audio Recording”, “Calendars”) again after every update. The app is signed with a stable certificate, so the system recognizes it by certificate rather than by the fingerprint of a particular build. After installing 1.2.2 the permission has to be granted one last time.

## [1.2.1] — 2026-11-24

### Fixed
- Clicking the LiveWall icon in the Dock, Launchpad or Finder while the app runs in the background now opens the main window (macOS used to just show the desktop).

## [1.2.0] — 2026-11-24

### Added
- **Wallpaper Engine scene converter.** Unpacks `scene.pkg` and `.tex` textures (LZ4, DXT1/3/5, RGBA, embedded JPG/PNG), keeps images at their original resolution and builds a LiveWall scene: layers, depth parallax, particles (rain, snow, ash, sparks…), blend modes, text clocks and similar effects.
- WE GIF scenes become animated GIF wallpapers; pixel art scales without blurring.
- Workshop presets: settings and their own files on top of the base web project.
- An “Import all and create a playlist” button in Workshop.

### Limitations
- WE puppet animation of characters and custom WE shaders are not converted: those layers stay static.

## [1.1.0] — 2026-11-24

### Added
- **Gallery**: 6 scenes and 6 shaders from the repository, one-click install, cached previews.
- **Time of day and weather**: scenes get darker at night, warmer at sunset and show rain or snow from Open-Meteo weather. Shaders get `iAmbient`, web wallpapers get the `lw-ambient` event.
- **Widgets**: tokens `{cpu}` `{ram}` `{battery}` `{charging}` `{track}` `{artist}` `{event}` `{eventTime}` `{temp}` `{weather}` `{city}` and presets in the scene editor.
- **Auto-updates through GitHub Releases**: banner, download with progress, SHA-256 check, app swap and relaunch.
- **English interface**: switches on the fly; dates in scenes are translated too.

### Performance
- Previews are decoded in the background with an LRU cache of 200 images.
- Cursor polling and system data collection run only while wallpapers are visible.
- Endless animations remain only where they are needed; the audio meter updates at most 12 times a second.

## [1.0.0] — 2026-11-24

First stable release.

### Added
- App icon (generated by `tools/make_icon.swift`).
- Documentation: README, user guide, wallpaper formats, architecture.

## [0.9.0-beta] — 2026-11-24

Full functionality and redesign, without the icon and docs.

### Features
- Desktop engine: video, web, images and GIFs, slideshows, GLSL shaders, scenes; multiple displays and a “stretch” mode.
- Wallpaper Engine web wallpaper API, import of Steam Workshop projects and downloads through steamcmd.
- Scene editor: layers, particles, parallax, waves, glow, color grading, clock and date.
- System audio reactivity (ScreenCaptureKit + vDSP FFT).
- Library with tags and favorites, playlists by timer and time of day, `.wallpkg` packages, launch at login.
- Charcoal and crimson design: custom sidebar with a mini player, animated cards and chips, splash screen, terms of use, credits, 7-page onboarding.

### Performance
- Scene load cut from about 42% to 6% CPU:
  - 15 FPS limit by default and an adaptive boost to 30 FPS on mouse movement;
  - 1× rendering, an opaque WebView, no `preserveDrawingBuffer`;
  - pause when windows cover ≥85% of the desktop;
  - the SwiftUI interface is unloaded while the window is closed.

### Fixed
- WebKit didn't call `requestAnimationFrame` in the desktop window; added a custom frame scheduler.
- Assigned wallpapers were reset on launch.
- Global mouse monitoring asked for Accessibility access; the cursor is now polled without permissions.

[1.6.0]: https://github.com/Jinjer07/LiveWall/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/Jinjer07/LiveWall/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/Jinjer07/LiveWall/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/Jinjer07/LiveWall/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/Jinjer07/LiveWall/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/Jinjer07/LiveWall/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/Jinjer07/LiveWall/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/Jinjer07/LiveWall/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Jinjer07/LiveWall/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Jinjer07/LiveWall/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Jinjer07/LiveWall/compare/v0.9.0-beta...v1.0.0
[0.9.0-beta]: https://github.com/Jinjer07/LiveWall/releases/tag/v0.9.0-beta

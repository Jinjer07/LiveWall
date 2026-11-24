# User guide

## First launch

1. **Splash screen**: an animated logo (click or press any key to skip; can be turned off in Settings).
2. **Terms of use**: scroll to the end, tick the checkbox and press “Accept”.
3. **Onboarding**: 7 pages about the features. On the last one you can turn on launch at login, audio reactivity and parallax right away.

Onboarding, terms and credits are always available in **Settings → LiveWall**.

## Menu bar

The picture icon in the menu bar gives you:

- the current wallpaper, **Pause / Resume**, “Next wallpaper” (for a playlist);
- quick access to playlists and favorites;
- wallpaper sound and audio reactivity;
- “Open LiveWall…” for the main window.

## Library

- **Add**: drag files or folders onto the window, or press “Add”.
  - videos, images, GIFs are copied into the library;
  - a folder of images becomes a slideshow (linked, so you can keep adding files);
  - a folder with `index.html` becomes a web wallpaper; with `scene.json`, a scene; with `project.json`, a Wallpaper Engine project;
  - `.frag` / `.glsl` becomes a shader; `.wallpkg` is a LiveWall package.
- **Double-click** a card to apply it to all displays.
- **Click** opens the details panel: name, tags, favorite, apply to a specific display, wallpaper settings, export, delete.
- **Select several wallpapers**: Cmd-click adds or removes a card, Shift-click selects a range, Cmd+A selects everything shown, Esc clears the selection. The selection bar can favorite or delete them all. **Cmd+Backspace** deletes the selection after a confirmation; the files go to the Trash.
- Filter by type, favorites and tags; search by name and tags.

## Gallery

**Gallery** has ready-made scenes and shaders. “Install” downloads an item into the library and puts it on the desktop right away; “+” only adds it to the library.

## Snow

The **Snow** tab puts snow over your desktop and windows. It's off by default.

- **Amount** and **flake size** sliders.
- **Settles on the top edges of windows**: drifts move with the window and melt when it closes.
- **The cursor pushes snow and sweeps drifts away.**
- **String lights under the menu bar.**
- **Clear drifts** removes all settled snow.
- **Pause settings** for snow are separate from the wallpaper ones: battery, full-screen app, maximized window, lock and sleep. Snow also stops under Reduce Motion and uses half the flakes in Low Power Mode.

The snow layer never catches clicks: the desktop and windows underneath work as usual. It is drawn by the CPU, so it adds some load while it's on.

## Time of day and weather

**Settings → Time of day and weather**: type a city and press “Find” (or Enter). Scenes with adaptation turned on (in the editor: scene → “Adapt to time of day and weather”) get darker at night, warmer at sunset and show rain or snow. Without a city, day is 07:00–18:30.

## Widgets

In the scene editor: “+” → “Widget” → clock, date, system monitor, battery, now playing, next event, weather. For the calendar, turn on **Settings → Widgets → Next event** and allow access.

## Updates

LiveWall checks GitHub for new versions itself. When one is out, a banner appears; press “Update”. You can turn the check off in **Settings → Updates**.

## Language

**Settings → Language**: “System”, “Русский” or “English”. The interface switches at once.

## Playlists

- **Timer**: an interval from 1 minute to a day, in order or shuffled.
- **Time of day**: a schedule like “07:00 morning, 19:00 evening, 23:00 night”.
- The active playlist (or, if no wallpaper is set, the last chosen one) applies right away when LiveWall starts.
- Picking a wallpaper by hand stops the active playlist.

## Steam Workshop

You need Wallpaper Engine purchased on your account.

1. **Workshop → “Install”**: if steamcmd isn't there yet, LiveWall downloads Valve's official tool.
2. **“Sign in to Steam”**: username and password, then a Steam Mobile confirmation (or a Steam Guard code). The password goes only to steamcmd and is not stored.
3. **“Sync Workshop”**: the first time, a steamcommunity.com window opens; sign in with the QR code. After that LiveWall finds your subscriptions, downloads new ones, converts scenes and adds everything to the “Wallpaper Engine” playlist.

Video and web wallpapers are imported as is, scenes through the converter (original images, layers, parallax, particles). WE puppet animation and custom WE shaders are not converted. If text in a scene imported before 1.6.0 looks huge, re-import it.

## Scene editor

- **Layers** (bottom to top): image, particles, text/clock, color fill.
- Drag layers with the mouse right in the preview; reorder them with the arrows in the list.
- Per layer: position, scale, rotation and spin, opacity, **parallax** (depth), blend mode, soft edges.
- Effects: waves, glow, color grading (hue, saturation, brightness), audio pulse.
- Particles: emitter (top, bottom, full screen, point), count, size, speed, direction, spread, gravity, wobble, colors, shape (dot, ring, streak, your own image), repel from cursor, bass reaction.
- Text supports tokens: `{time}`, `{time:s}`, `{date}`, `{weekday}`, `{year}`.
- “Save and apply” (`⌘S` saves).

## Settings

| Section | What it controls |
|---|---|
| Performance | FPS limit; pause for a full-screen app, covered desktop, maximized window, another app focused, battery, lock |
| Wallpaper sound | Volume, mute (sound only from the main display) |
| Audio visualization | Reaction to system audio |
| Interactivity | Mouse parallax, desktop clicks |
| Displays | Stretch one wallpaper across all displays |
| System | Launch at login, data folder, samples |

## Where data is stored

`~/Library/Application Support/LiveWall/`:

- `library.json` is the library, `settings.json` the settings, `state.json` the assignments and playlists;
- `Library/` holds imported wallpaper files, `Previews/` previews of linked wallpapers, `Runtime/` the JS runtimes.

## FAQ

**Dark bars at the screen edges when I click the desktop.** Those are the edges of other windows that macOS pushes aside in “Show Desktop” mode. Turn it off in System Settings → Desktop & Dock → “Click wallpaper to reveal desktop”.

**The wallpaper is paused.** Check the pause settings: full-screen app, covered desktop, another app focused, battery.

**Audio reactivity doesn't work.** Allow LiveWall in Privacy & Security → “Screen & System Audio Recording” (the “System Audio Recording Only” list on macOS 14.2+) and relaunch the app.

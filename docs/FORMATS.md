# Wallpaper formats

## GLSL shaders

Shaders are written Shadertoy style (GLSL ES 3.0 / WebGL 2):

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
```

### Built-in uniforms

| Name | Type | Meaning |
|---|---|---|
| `iResolution` | `vec3` | Size in pixels |
| `iTime`, `iTimeDelta` | `float` | Time and frame step (scaled by “Speed”) |
| `iFrame` | `int` | Frame number |
| `iMouse` | `vec4` | Cursor position in pixels (origin at bottom left) |
| `iAudio` | `vec4` | x: bass, y: mids, z: highs, w: overall level (0…1) |
| `iSpectrum` | `sampler2D` | 64×1 spectrum (`texture(iSpectrum, vec2(x, 0.5)).r`) |
| `iDate` | `vec4` | Year, month, day, seconds since midnight |
| `iChannel0` | `sampler2D` | Alias of `iSpectrum` for Shadertoy code |
| `iAmbient` | `vec4` | x: night (0…1), y: golden hour, z: precipitation (0 none, 1 rain, 2 snow), w: cloudiness |

### Custom settings

Uniforms with a `u_` prefix and a comment show up in the settings panel:

```glsl
uniform float u_speed;  // Speed [0, 5] = 1
uniform vec3  u_color;  // Color = 1 0.2 0.25
uniform bool  u_glow;   // Glow = true
uniform int   u_count;  // Count [1, 10] = 4
```

Format: `// Label [min, max] = value`. A color is three numbers from 0 to 1.

## Scenes (`scene.json`)

```json
{
  "version": 1,
  "width": 1920,
  "height": 1080,
  "background": "#070b1c",
  "layers": [
    { "id": "…", "name": "Clock", "kind": "text", "text": "{time}", "fontSize": 230, "x": 0.5, "y": 0.42 }
  ]
}
```

Layers are drawn bottom to top. `x`, `y` are the layer's center as fractions of the layout (0…1). The layout is scaled to fill the screen.

| Field | Layers | Description |
|---|---|---|
| `kind` | all | `image`, `particles`, `text`, `color` |
| `x`, `y`, `scale`, `rotation`, `rotationSpeed` | all | Transform (degrees, degrees/s) |
| `opacity`, `parallax`, `blend` | all | Opacity, parallax depth, `normal` / `add` / `screen` / `multiply` |
| `feather` | all but particles | Soft edges 0…0.5 |
| `tint`, `hue`, `saturation`, `brightness` | all but particles | Tint and color grading |
| `waveEnabled`, `waveAmplitude`, `waveFrequency`, `waveSpeed`, `waveVertical` | all but particles | Waves |
| `glowEnabled`, `glowRadius`, `glowIntensity`, `glowColor` | all but particles | Glow |
| `audioPulse`, `audioBand` | all but particles | Audio pulse (`bass` / `mid` / `high` / `level`) |
| `file` | image, image particles | File name in the scene folder |
| `text`, `fontSize`, `fontWeight`, `textColor` | text | Tokens `{time}`, `{time:s}`, `{date}`, `{weekday}`, `{year}` |
| `width`, `height` | color | Fill size in layout units |
| `pCount`, `pEmitter`, `pSizeMin`, `pSizeMax`, `pSpeed`, `pDirection`, `pSpread`, `pLifetime`, `pGravity`, `pWobble`, `pColor`, `pColor2`, `pShape`, `pMouseRepel`, `pAudio` | particles | Emitter `top` / `bottom` / `full` / `point`, shape `soft` / `circle` / `streak` / `image` |

Scene document fields: `ambient` (adapt to time of day and weather) and `ambientPrecip` (precipitation from weather, on by default).

Text layer tokens: `{time}` `{time:s}` `{date}` `{weekday}` `{year}`, plus widgets: `{cpu}` `{ram}` `{battery}` `{charging}` `{track}` `{artist}` `{event}` `{eventTime}` `{temp}` `{weather}` `{city}`.

Scene properties in the panel: `parallax`, `speed`, `quality` (render resolution; 1 means no Retina doubling).

## Web wallpapers

Any folder with `index.html`. The Wallpaper Engine API is supported:

```js
// Settings from the panel (WE format: { key: { value } }, colors are "r g b" 0…1)
window.wallpaperPropertyListener = {
  applyUserProperties(props) { /* … */ },
  applyGeneralProperties(general) { /* general.fps */ },
  setPaused(paused) { /* … */ }
};

// Audio spectrum: an array of 128 numbers 0…1 (64 left channel + 64 right)
window.wallpaperRegisterAudioListener(audio => { /* … */ });
```

Also:

- `requestAnimationFrame` is automatically limited to the FPS cap and stops while paused;
- mouse events (`mousemove`, `mousedown`, `mouseup`, `click`, pointer events) arrive as in a normal browser;
- the `lw-properties` event (`CustomEvent`) mirrors `applyUserProperties`;
- `<video>` and `<audio>` get their volume from LiveWall's settings;
- `window.__lw.info` and the `lw-info` event carry widget data (same keys as the tokens);
- `window.__lw.ambient` and the `lw-ambient` event carry `{night, golden, precip, intensity, cloud}`;
- `window.__lw.lang` is the interface language (`ru` / `en`).

## `.wallpkg` packages

A ZIP archive with the contents of the wallpaper folder and a `manifest.json` (the library item: type, main file, tags, properties). Created with “Export to .wallpkg”, opened by dragging it into the library.

## Wallpaper Engine projects

From `project.json` LiveWall reads `type` (`video` / `web` / `scene`), `file`, `title`, `preview`, `tags` and `general.properties` (types `slider`, `color`, `bool`, `combo`, `textinput`). Video and web projects are linked, not copied. Scenes are converted: `scene.pkg` and `.tex` textures are unpacked and rebuilt as a LiveWall scene.

## Gallery (`gallery/index.json`)

```json
{ "version": 1, "items": [
  { "id": "aurora", "type": "shader", "title": {"ru": "Аврора", "en": "Aurora"},
    "description": {"ru": "…", "en": "…"}, "tags": ["шейдер"],
    "file": "shaders/aurora.frag", "preview": "previews/aurora.jpg", "version": 1 }
]}
```

The app reads the catalog from `raw.githubusercontent.com/Jinjer07/LiveWall/main/gallery/`. To refresh previews for users, bump the item's `version`.

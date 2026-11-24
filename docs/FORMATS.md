# Форматы обоев

## GLSL-шейдеры

Шейдеры пишутся в стиле Shadertoy (GLSL ES 3.0 / WebGL 2):

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
```

### Встроенные uniform-переменные

| Имя | Тип | Значение |
|---|---|---|
| `iResolution` | `vec3` | Размер в пикселях |
| `iTime`, `iTimeDelta` | `float` | Время и шаг кадра (с учётом «Скорости») |
| `iFrame` | `int` | Номер кадра |
| `iMouse` | `vec4` | Позиция курсора в пикселях (начало снизу слева) |
| `iAudio` | `vec4` | x — бас, y — середина, z — верха, w — общий уровень (0…1) |
| `iSpectrum` | `sampler2D` | Спектр 64×1 (`texture(iSpectrum, vec2(x, 0.5)).r`) |
| `iDate` | `vec4` | Год, месяц, день, секунды с начала суток |
| `iChannel0` | `sampler2D` | Псевдоним `iSpectrum` для кода из Shadertoy |

### Свои настройки

Uniform-переменные с префиксом `u_` и комментарием появляются в панели настроек:

```glsl
uniform float u_speed;  // Скорость [0, 5] = 1
uniform vec3  u_color;  // Цвет = 1 0.2 0.25
uniform bool  u_glow;   // Свечение = true
uniform int   u_count;  // Количество [1, 10] = 4
```

Формат: `// Подпись [мин, макс] = значение`. Цвет — три числа 0…1.

## Сцены (`scene.json`)

```json
{
  "version": 1,
  "width": 1920,
  "height": 1080,
  "background": "#070b1c",
  "layers": [
    { "id": "…", "name": "Часы", "kind": "text", "text": "{time}", "fontSize": 230, "x": 0.5, "y": 0.42 }
  ]
}
```

Слои рисуются снизу вверх. `x`, `y` — центр слоя в долях макета (0…1). Макет масштабируется по принципу «заполнить экран».

| Поле | Слои | Описание |
|---|---|---|
| `kind` | все | `image`, `particles`, `text`, `color` |
| `x`, `y`, `scale`, `rotation`, `rotationSpeed` | все | Трансформация (градусы, градусы/с) |
| `opacity`, `parallax`, `blend` | все | Прозрачность, глубина параллакса, `normal` / `add` / `screen` / `multiply` |
| `feather` | кроме частиц | Мягкие края 0…0.5 |
| `tint`, `hue`, `saturation`, `brightness` | кроме частиц | Оттенок и цветокоррекция |
| `waveEnabled`, `waveAmplitude`, `waveFrequency`, `waveSpeed`, `waveVertical` | кроме частиц | Волны |
| `glowEnabled`, `glowRadius`, `glowIntensity`, `glowColor` | кроме частиц | Свечение |
| `audioPulse`, `audioBand` | кроме частиц | Пульсация от звука (`bass` / `mid` / `high` / `level`) |
| `file` | image, частицы-картинки | Имя файла в папке сцены |
| `text`, `fontSize`, `fontWeight`, `textColor` | text | Токены `{time}`, `{time:s}`, `{date}`, `{weekday}`, `{year}` |
| `width`, `height` | color | Размер заливки в единицах макета |
| `pCount`, `pEmitter`, `pSizeMin`, `pSizeMax`, `pSpeed`, `pDirection`, `pSpread`, `pLifetime`, `pGravity`, `pWobble`, `pColor`, `pColor2`, `pShape`, `pMouseRepel`, `pAudio` | particles | Источник `top` / `bottom` / `full` / `point`, форма `soft` / `circle` / `streak` / `image` |

Свойства сцены в панели: `parallax`, `speed`, `quality` (разрешение рендера, 1 = без Retina-удвоения).

## Веб-обои

Любая папка с `index.html`. Поддерживается API Wallpaper Engine:

```js
// Настройки из панели (формат WE: { key: { value } }, цвета — "r g b" 0…1)
window.wallpaperPropertyListener = {
  applyUserProperties(props) { /* … */ },
  applyGeneralProperties(general) { /* general.fps */ },
  setPaused(paused) { /* … */ }
};

// Спектр звука: массив из 128 чисел 0…1 (64 левый канал + 64 правый)
window.wallpaperRegisterAudioListener(audio => { /* … */ });
```

Дополнительно:

- `requestAnimationFrame` автоматически ограничивается лимитом FPS и останавливается на паузе;
- события мыши (`mousemove`, `mousedown`, `mouseup`, `click`, pointer-события) приходят, как в обычном браузере;
- событие `lw-properties` (`CustomEvent`) дублирует `applyUserProperties`;
- `<video>` и `<audio>` получают громкость из настроек LiveWall.

## Пакеты `.wallpkg`

ZIP-архив с содержимым папки обоев и файлом `manifest.json` (описание элемента библиотеки: тип, главный файл, теги, свойства). Создаётся через «Экспорт в .wallpkg», открывается перетаскиванием в библиотеку.

## Проекты Wallpaper Engine

Из `project.json` читаются `type` (`video` / `web`), `file`, `title`, `preview`, `tags` и `general.properties` (типы `slider`, `color`, `bool`, `combo`, `textinput`). Проекты подключаются по ссылке и не копируются.

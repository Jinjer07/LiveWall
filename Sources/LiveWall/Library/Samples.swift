import Foundation

/// Встроенные примеры, которые появляются при первом запуске.
@MainActor
enum Samples {
    static let shaderTemplate = #"""
// Шейдер в стиле Shadertoy (GLSL ES 3.0).
// Доступно: iTime, iTimeDelta, iFrame, iResolution, iMouse,
// iAudio (x — бас, y — середина, z — верха, w — общий уровень),
// iSpectrum (текстура 64x1 со спектром), iDate.
// Свойства для панели настроек объявляются так:
//   uniform float u_name; // Подпись [min, max] = значение
//   uniform vec3  u_name; // Подпись = r g b
//   uniform bool  u_name; // Подпись = true
uniform vec3 u_color1;  // Цвет 1 = 0.05 0.25 0.85
uniform vec3 u_color2;  // Цвет 2 = 0.95 0.25 0.55
uniform float u_waves;  // Плотность волн [1, 12] = 4
uniform float u_audio;  // Реакция на звук [0, 2] = 1

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    vec2 m = iMouse.xy / iResolution.xy - 0.5;
    p += m * 0.15;
    float t = iTime * 0.3;
    float v = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        v += sin(p.x * u_waves * (1.0 + fi * 0.5) + t * (1.0 + fi) + sin(p.y * 3.0 + t));
        v += cos(p.y * u_waves * (1.2 + fi * 0.3) - t * (0.7 + fi * 0.4));
    }
    v = v / 8.0 + 0.5;
    vec3 col = mix(u_color1, u_color2, smoothstep(0.1, 0.9, v));
    float bass = iAudio.x * u_audio;
    col += bass * 0.4 * u_color2 * (1.0 - length(p));
    float spec = texture(iSpectrum, vec2(uv.x, 0.5)).r * u_audio;
    col += vec3(0.6, 0.8, 1.0) * smoothstep(0.02, 0.0, abs(uv.y - spec * 0.35 - 0.05)) * 0.6;
    col *= 0.75 + 0.25 * sin(uv.y * 3.14159);
    fragColor = vec4(col, 1.0);
}
"""#

    static let visualizerHTML = #"""
<!doctype html>
<html><head><meta charset="utf-8">
<style>html,body{margin:0;height:100%;overflow:hidden;background:#05060a}canvas{display:block;width:100%;height:100%}</style>
</head><body><canvas id="c"></canvas>
<script>
// Пример веб-обоев с API Wallpaper Engine: wallpaperRegisterAudioListener + wallpaperPropertyListener
var c = document.getElementById('c'), x = c.getContext('2d');
var audio = new Array(128).fill(0), smooth = new Array(64).fill(0);
var color = [0.3, 0.7, 1.0], bars = 64, mirror = true, mouse = {x: 0.5, y: 0.5};
window.wallpaperPropertyListener = {
  applyUserProperties: function (p) {
    if (p.barcolor) color = p.barcolor.value.split(' ').map(parseFloat);
    if (p.bars) bars = Math.round(p.bars.value);
    if (p.mirror) mirror = p.mirror.value;
  }
};
window.wallpaperRegisterAudioListener(function (a) { audio = a; });
document.addEventListener('mousemove', function (e) { mouse.x = e.clientX / innerWidth; mouse.y = e.clientY / innerHeight; });
function frame(t) {
  requestAnimationFrame(frame);
  var d = Math.min(devicePixelRatio || 1, 2);
  if (c.width !== innerWidth * d) { c.width = innerWidth * d; c.height = innerHeight * d; }
  var W = c.width, H = c.height;
  var g = x.createRadialGradient(W * mouse.x, H * mouse.y, 0, W / 2, H / 2, Math.max(W, H));
  g.addColorStop(0, 'rgba(' + (color[0] * 60 | 0) + ',' + (color[1] * 60 | 0) + ',' + (color[2] * 90 | 0) + ',1)');
  g.addColorStop(1, '#05060a');
  x.fillStyle = g; x.fillRect(0, 0, W, H);
  var n = Math.max(8, Math.min(64, bars)), bw = W / n;
  for (var i = 0; i < n; i++) {
    var k = Math.floor(i / n * 64);
    var v = (audio[k] + audio[k + 64]) * 0.5;
    if (!audio.some(function (q) { return q > 0.01; })) v = 0.08 + 0.05 * Math.sin(t / 700 + i * 0.4);
    smooth[i] += (v - smooth[i]) * 0.35;
    var h = smooth[i] * H * 0.45;
    var r = color[0] * 255 | 0, gg = color[1] * 255 | 0, b = color[2] * 255 | 0;
    x.fillStyle = 'rgba(' + r + ',' + gg + ',' + b + ',0.9)';
    x.shadowColor = x.fillStyle; x.shadowBlur = 20 * d;
    x.fillRect(i * bw + bw * 0.15, H / 2 - h, bw * 0.7, h);
    if (mirror) { x.fillStyle = 'rgba(' + r + ',' + gg + ',' + b + ',0.25)'; x.fillRect(i * bw + bw * 0.15, H / 2, bw * 0.7, h * 0.6); }
  }
  x.shadowBlur = 0;
}
requestAnimationFrame(frame);
</script></body></html>
"""#

    static func sampleScene() -> SceneDoc {
        var doc = SceneDoc()
        doc.background = "#070b1c"

        var sky = SceneLayer(name: tr("Небо"), kind: .color)
        sky.tint = "#0d1740"
        sky.waveEnabled = false
        var glow = SceneLayer(name: tr("Сияние"), kind: .color)
        glow.tint = "#5a3fc0"; glow.opacity = 0.45; glow.y = 0.9; glow.height = 700; glow.width = 2600; glow.blend = "add"; glow.feather = 0.5
        glow.waveEnabled = true; glow.waveAmplitude = 2; glow.waveFrequency = 1; glow.waveSpeed = 0.6
        glow.audioPulse = 0.15

        var fireflies = ParticlePreset.fireflies.make()
        fireflies.parallax = 0.8
        var snow = ParticlePreset.snow.make()
        snow.parallax = 0.5

        var clock = SceneLayer(name: tr("Часы"), kind: .text)
        clock.text = "{time}"; clock.fontSize = 230; clock.fontWeight = "200"; clock.y = 0.42
        clock.parallax = 0.3; clock.glowEnabled = true; clock.glowRadius = 6; clock.glowIntensity = 0.5
        clock.glowColor = "#7fa8ff"; clock.audioPulse = 0.06

        var date = SceneLayer(name: tr("Дата"), kind: .text)
        date.text = "{weekday}, {date}"; date.fontSize = 52; date.fontWeight = "400"; date.y = 0.57
        date.opacity = 0.75; date.parallax = 0.3

        doc.layers = [sky, glow, fireflies, clock, date, snow]
        return doc
    }

    static func install(into library: LibraryStore) {
        // Сцена
        let sceneDir = library.newFolder()
        if let d = try? JSONEncoder.lw.encode(sampleScene()) {
            try? d.write(to: sceneDir.appendingPathComponent("scene.json"))
        }
        library.add(WallpaperItem(id: UUID().uuidString, title: tr("Ночные часы"), type: .scene, folder: sceneDir.path,
                                  entry: "scene.json", tags: [tr("пример"), tr("часы")],
                                  properties: DefaultProps.forType(.scene)))

        // Шейдер
        let shDir = library.newFolder()
        try? shaderTemplate.write(to: shDir.appendingPathComponent("shader.frag"), atomically: true, encoding: .utf8)
        library.add(WallpaperItem(id: UUID().uuidString, title: tr("Волны (шейдер)"), type: .shader, folder: shDir.path,
                                  entry: "shader.frag", tags: [tr("пример")],
                                  properties: DefaultProps.forType(.shader) + ShaderParser.properties(from: shaderTemplate)))

        // Веб-визуализатор
        let webDir = library.newFolder()
        try? visualizerHTML.write(to: webDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        library.add(WallpaperItem(id: UUID().uuidString, title: tr("Аудио-визуализатор"), type: .web, folder: webDir.path,
                                  entry: "index.html", tags: [tr("пример"), tr("звук")],
                                  properties: [
                                    WallpaperProperty(key: "barcolor", label: tr("Цвет полос"), kind: .color, value: .string("0.3 0.7 1"), order: 0),
                                    WallpaperProperty(key: "bars", label: tr("Количество полос"), kind: .slider, value: .number(48), min: 8, max: 64, step: 1, order: 1),
                                    WallpaperProperty(key: "mirror", label: tr("Отражение"), kind: .bool, value: .bool(true), order: 2),
                                  ]))
    }
}

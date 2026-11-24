// Аврора — полярное сияние / Aurora
uniform vec3 u_color1;  // Цвет 1 = 0.10 0.95 0.60
uniform vec3 u_color2;  // Цвет 2 = 0.85 0.10 0.45
uniform float u_bands;  // Полосы [1, 6] = 3
uniform float u_audio;  // Реакция на звук [0, 2] = 1

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.0; a *= 0.5; } return v; }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 m = iMouse.xy / iResolution.xy - 0.5;
    vec3 sky = mix(vec3(0.01, 0.01, 0.04), vec3(0.03, 0.02, 0.10), uv.y);
    float stars = step(0.997, hash(floor(fragCoord * 0.5))) * (0.5 + 0.5 * sin(iTime * 3.0 + hash(floor(fragCoord)) * 6.28));
    vec3 col = sky + stars * uv.y;
    float t = iTime * 0.08;
    for (int i = 0; i < 6; i++) {
        if (float(i) >= u_bands) break;
        float fi = float(i);
        float x = uv.x * (1.5 + fi * 0.3) + m.x * 0.3 + fi * 1.7;
        float h = 0.55 + 0.12 * fi + 0.15 * fbm(vec2(x * 1.3, t + fi)) - m.y * 0.1;
        float curtain = exp(-pow((uv.y - h) * (9.0 - fi), 2.0)) * smoothstep(0.0, 0.25, fbm(vec2(x * 4.0, t * 3.0 + fi)));
        float rays = 0.6 + 0.4 * fbm(vec2(x * 20.0, t * 6.0));
        vec3 c = mix(u_color1, u_color2, 0.5 + 0.5 * sin(fi * 1.9 + uv.x * 2.2 + t * 2.0));
        col += c * curtain * rays * (0.9 + iAudio.x * u_audio);
    }
    col = mix(col, col * vec3(0.6, 0.65, 0.9), iAmbient.x * 0.3);
    fragColor = vec4(col, 1.0);
}

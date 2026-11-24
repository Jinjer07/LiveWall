// Неоновая сетка / Neon synth grid
uniform vec3 u_grid;    // Цвет сетки = 1.0 0.15 0.35
uniform vec3 u_sun;     // Цвет солнца = 1.0 0.45 0.2
uniform float u_speed;  // Скорость [0, 3] = 1
uniform float u_audio;  // Реакция на звук [0, 2] = 1

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.x += (iMouse.x / iResolution.x - 0.5) * 0.1;
    float horizon = -0.05;
    vec3 col = mix(vec3(0.02, 0.0, 0.05), vec3(0.18, 0.0, 0.12), smoothstep(-0.5, 0.5, uv.y));
    vec2 sp = uv - vec2(0.0, 0.18);
    float r = length(sp);
    float sun = smoothstep(0.26, 0.255, r);
    float stripes = step(0.0, sin((uv.y - 0.18) * 90.0 + iTime * 2.0)) + step(0.12, uv.y);
    sun *= clamp(stripes, 0.0, 1.0);
    col += mix(u_sun, u_grid, smoothstep(0.35, 0.0, uv.y)) * sun * (1.0 + iAudio.x * 0.6 * u_audio);
    col += u_sun * 0.25 * exp(-r * 4.0);
    if (uv.y < horizon) {
        float z = 0.35 / (horizon - uv.y);
        vec2 g = vec2(uv.x * z, z + iTime * u_speed * 1.5);
        vec2 gf = abs(fract(g) - 0.5);
        float line = smoothstep(0.06 * z * 0.25, 0.0, min(gf.x, gf.y) - 0.01);
        float fade = smoothstep(0.0, 0.25, horizon - uv.y);
        col = mix(vec3(0.02, 0.0, 0.04), col, 0.0) + u_grid * line * fade * (0.8 + iAudio.y * u_audio);
        col += u_grid * 0.15 * exp(-(horizon - uv.y) * 12.0);
    }
    fragColor = vec4(col, 1.0);
}

// Звёздный тоннель / Warp starfield
uniform float u_speed;  // Скорость полёта [0, 4] = 1
uniform vec3 u_tint;    // Оттенок = 1.0 0.35 0.45
uniform float u_audio;  // Реакция на звук [0, 3] = 1.2

float hash(vec2 p) { return fract(sin(dot(p, vec2(41.3, 289.1))) * 15731.7); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv -= (iMouse.xy / iResolution.xy - 0.5) * 0.15;
    vec3 col = vec3(0.0);
    float speed = u_speed * (1.0 + iAudio.x * u_audio);
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float depth = fract(iTime * 0.12 * speed + fl * 0.25);
        float scale = mix(18.0, 0.6, depth);
        float fade = smoothstep(0.0, 0.25, depth) * smoothstep(1.0, 0.85, depth);
        vec2 g = uv * scale + fl * 13.7;
        vec2 id = floor(g), f = fract(g) - 0.5;
        float n = hash(id);
        if (n > 0.75) {
            vec2 off = vec2(hash(id + 3.1), hash(id + 7.7)) - 0.5;
            float d = length(f - off * 0.6);
            float star = max(0.0, 0.012 / (d * d + 0.0015) - 0.05) * smoothstep(0.5, 0.2, d) * fade * (n - 0.75) * 4.0;
            col += mix(vec3(1.0), u_tint, hash(id + 1.3)) * star;
        }
    }
    col += u_tint * 0.08 * exp(-length(uv) * 3.0) * (1.0 + iAudio.w * u_audio);
    fragColor = vec4(min(col, 1.5), 1.0);
}

// Алая плазма / Crimson plasma
uniform vec3 u_color1;  // Тёмный = 0.05 0.0 0.02
uniform vec3 u_color2;  // Яркий = 1.0 0.18 0.25
uniform float u_scale;  // Масштаб [0.5, 4] = 1.6
uniform float u_audio;  // Реакция на звук [0, 2] = 1

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y * u_scale;
    p += (iMouse.xy / iResolution.xy - 0.5) * 0.2;
    float t = iTime * 0.5;
    float v = sin(p.x * 3.0 + t) + sin(p.y * 2.7 - t * 1.1) + sin((p.x + p.y) * 2.2 + t * 0.7)
            + sin(length(p * 3.1 + vec2(sin(t * 0.3), cos(t * 0.4)) * 2.0) - t);
    v = v * 0.25 + 0.5 + iAudio.x * 0.25 * u_audio;
    float bands = 0.5 + 0.5 * sin(v * 9.0);
    vec3 col = mix(u_color1, u_color2, smoothstep(0.15, 0.95, v));
    col += u_color2 * pow(bands, 12.0) * 0.6;
    col *= 0.8 + 0.2 * smoothstep(1.2, 0.2, length(p) / u_scale);
    fragColor = vec4(col, 1.0);
}

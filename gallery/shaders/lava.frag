// Лавовая лампа / Lava lamp
uniform vec3 u_hot;     // Горячий = 1.0 0.25 0.15
uniform vec3 u_cold;    // Холодный = 0.35 0.0 0.08
uniform float u_blobs;  // Капли [3, 10] = 7
uniform float u_audio;  // Реакция на звук [0, 2] = 1

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float field = 0.0;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        if (fi >= u_blobs) break;
        vec2 c = vec2(sin(iTime * 0.21 * (1.0 + fi * 0.13) + fi * 1.7) * 0.6,
                      sin(iTime * 0.17 * (1.0 + fi * 0.11) + fi * 2.9) * 0.4);
        float r = 0.13 + 0.04 * sin(fi * 3.3) + iAudio.x * 0.03 * u_audio;
        field += r * r / dot(uv - c, uv - c);
    }
    float m = smoothstep(0.85, 1.1, field);
    vec3 bg = mix(vec3(0.03, 0.01, 0.02), u_cold * 0.45, uv.y + 0.5);
    vec3 inner = mix(u_cold * 1.6, u_hot, smoothstep(1.0, 6.0, field));
    vec3 col = mix(bg, inner, m);
    col += u_hot * smoothstep(0.4, 0.85, field) * (1.0 - m) * 0.3;
    fragColor = vec4(col, 1.0);
}

// Океан на закате / Ocean at dusk
uniform vec3 u_sky;     // Небо = 0.95 0.35 0.30
uniform vec3 u_water;   // Вода = 0.05 0.08 0.20
uniform float u_waves;  // Волнение [0.2, 3] = 1
uniform float u_audio;  // Реакция на звук [0, 2] = 0.6

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 m = iMouse.xy / iResolution.xy - 0.5;
    float hz = 0.45 + m.y * 0.03;
    vec3 sky = mix(u_sky, vec3(0.08, 0.05, 0.18), smoothstep(hz, 1.0, uv.y));
    float sunD = length((uv - vec2(0.5 + m.x * 0.05, hz + 0.06)) * vec2(iResolution.x / iResolution.y, 1.0));
    sky += vec3(1.0, 0.7, 0.4) * smoothstep(0.08, 0.07, sunD) + u_sky * 0.4 * exp(-sunD * 6.0);
    vec3 col = sky;
    if (uv.y < hz) {
        float d = hz - uv.y;
        float w = 0.0;
        for (int i = 1; i <= 5; i++) {
            float fi = float(i);
            w += sin(uv.x * 40.0 * fi / (d * 6.0 + 0.3) + iTime * (0.6 + fi * 0.3) + fi * 2.1) / fi;
        }
        w *= 0.5 * u_waves * (1.0 + iAudio.x * u_audio);
        vec3 water = mix(u_water * 1.6, u_water, smoothstep(0.0, 0.45, d));
        float glint = smoothstep(0.65, 1.0, w * 0.5 + 0.5) * exp(-abs(uv.x - 0.5 - m.x * 0.05) * 9.0 / (d + 0.2)) ;
        col = water + u_sky * glint * 0.8 + u_sky * 0.15 * exp(-d * 20.0);
    }
    col = mix(col, col * vec3(0.5, 0.55, 0.85), iAmbient.x * 0.4);
    fragColor = vec4(col, 1.0);
}

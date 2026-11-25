import Foundation

/// JS-рантаймы, которые записываются в ~/Library/Application Support/LiveWall/Runtime при запуске.
enum RuntimeFiles {
    static func install() {
        Paths.ensure()
        let files = ["shader.html": shaderHTML, "scene.html": sceneHTML, "media.html": mediaHTML]
        for (name, content) in files {
            try? content.write(to: Paths.runtime.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Мост (API Wallpaper Engine + управление из Swift)

    static let bridge = #"""
(function(){
  if (window.__lw) return;
  var lw = window.__lw = { paused:false, fps:60, props:{}, audio:new Array(128).fill(0), mouse:{x:0.5,y:0.5}, volume:0,
    lang:'__LANG__', info:{}, ambient:{night:0, golden:0, precip:'none', intensity:0, cloud:0} };
  window.__lwInfo = function(i){ lw.info = i || {}; lw.needFrame = 2; try{ window.dispatchEvent(new CustomEvent('lw-info', {detail:lw.info})); }catch(e){} };
  window.__lwAmbient = function(a){ lw.ambient = a || lw.ambient; lw.needFrame = 2; try{ window.dispatchEvent(new CustomEvent('lw-ambient', {detail:lw.ambient})); }catch(e){} };
  function post(m){ try{ window.webkit.messageHandlers.lw.postMessage(m); }catch(e){} }
  window.__lwPost = post;
  // WebGL-контекст может пропасть (нехватка видеопамяти, сброс GPU): тогда холст навсегда
  // остаётся чёрным. Сообщаем приложению — оно перезагрузит обои и восстановит настройки.
  window.addEventListener('webglcontextlost', function(e){ post({type:'contextlost'}); }, true);
  window.addEventListener('error', function(e){
    post({type:'error', message: String(e.message||e) + (e.filename ? (' @ ' + String(e.filename).split('/').pop() + ':' + e.lineno) : '')});
  });
  var audioCbs = [];
  window.wallpaperRegisterAudioListener = function(cb){ if (typeof cb === 'function') audioCbs.push(cb); };
  // Умный FPS: в покое не чаще lw.idle кадров/с, а на ударах в музыке и при движении мыши — до лимита.
  lw.idle = 0; var bassAvg = 0;
  window.__lwSmart = function(n){ lw.idle = n | 0; };
  function beat(a){
    var b = 0; for (var i = 0; i < 6; i++) b += ((a[i] || 0) + (a[i + 64] || 0)) * 0.5; b /= 6;
    if (lw.idle > 0 && b - bassAvg > 0.12) lw.boostUntil = performance.now() + 600;
    bassAvg += (b - bassAvg) * 0.08;
  }
  window.__lwAudio = function(a){ lw.audio = a; beat(a); for (var i=0;i<audioCbs.length;i++){ try{ audioCbs[i](a); }catch(e){} } };
  window.__lwProps = function(p){
    for (var k in p) lw.props[k] = p[k];
    lw.needFrame = 2;
    var l = window.wallpaperPropertyListener;
    if (l && typeof l.applyUserProperties === 'function') { try{ l.applyUserProperties(p); }catch(e){ post({type:'error', message:'applyUserProperties: ' + e}); } }
    try{ window.dispatchEvent(new CustomEvent('lw-properties', {detail:p})); }catch(e){}
  };
  window.__lwFPS = function(f){
    lw.fps = f > 0 ? f : 60;
    var l = window.wallpaperPropertyListener;
    if (l && typeof l.applyGeneralProperties === 'function') { try{ l.applyGeneralProperties({fps:lw.fps}); }catch(e){} }
  };
  function media(fn){ try{ document.querySelectorAll('video,audio').forEach(fn); }catch(e){} }
  window.__lwPause = function(p){
    lw.paused = !!p; if (lw.paused) lw.needFrame = 2;
    var l = window.wallpaperPropertyListener;
    if (l && typeof l.setPaused === 'function') { try{ l.setPaused(lw.paused); }catch(e){} }
    media(function(m){
      if (lw.paused) { if (!m.paused) { m.__lwWas = true; m.pause(); } }
      else if (m.__lwWas) { m.__lwWas = false; var r = m.play(); if (r && r.catch) r.catch(function(){}); }
    });
    try{ window.dispatchEvent(new CustomEvent('lw-pause', {detail:lw.paused})); }catch(e){}
  };
  window.__lwVolume = function(v){ lw.volume = v; media(function(m){ m.volume = Math.max(0, Math.min(1, v)); m.muted = v <= 0; }); };
  document.addEventListener('play', function(e){
    var m = e.target;
    if (m && (m.tagName === 'VIDEO' || m.tagName === 'AUDIO')) { m.volume = Math.max(0, Math.min(1, lw.volume)); m.muted = lw.volume <= 0; }
  }, true);
  window.__lwMouse = function(type, x, y){
    lw.boostUntil = performance.now() + 1500;
    lw.mouse = {x: x / Math.max(1, innerWidth), y: y / Math.max(1, innerHeight)};
    var el = document.elementFromPoint(x, y) || document.body || document.documentElement;
    if (!el) return;
    var init = {clientX:x, clientY:y, screenX:x, screenY:y, bubbles:true, cancelable:true, view:window, button:0, buttons: type === 'mousedown' ? 1 : 0};
    try {
      var pt = type === 'mousemove' ? 'pointermove' : (type === 'mousedown' ? 'pointerdown' : 'pointerup');
      el.dispatchEvent(new PointerEvent(pt, Object.assign({pointerId:1, pointerType:'mouse', isPrimary:true}, init)));
    } catch(e) {}
    el.dispatchEvent(new MouseEvent(type, init));
    if (type === 'mouseup') el.dispatchEvent(new MouseEvent('click', init));
  };
  // Свой планировщик кадров вместо requestAnimationFrame:
  // окно на уровне рабочего стола macOS считает перекрытым (его закрывает окно иконок Finder),
  // и WebKit перестаёт вызывать requestAnimationFrame. Таймеры при этом работают.
  // Заодно здесь ограничение FPS и пауза.
  var queue = [], seq = 0, cancelled = {}, timer = null, lastFrame = 0;
  function schedule(){
    if (timer !== null) return;
    // Адаптивная частота: пока двигается мышь — до 30 FPS (плавный параллакс), в покое — лимит из настроек.
    var now = performance.now(), boost = now < (lw.boostUntil || 0);
    var fps = boost ? Math.max(lw.fps, 30) : (lw.idle > 0 ? Math.min(lw.fps, lw.idle) : lw.fps);
    var iv = 1000 / fps;
    var wait = Math.max(0, lastFrame + iv - now);
    timer = setTimeout(tick, (lw.paused && !lw.needFrame) ? 250 : wait);
  }
  function tick(){
    timer = null;
    // На паузе всё равно рисуем пару кадров после загрузки/смены настроек, чтобы был виден стоп-кадр.
    if (lw.paused) { if (lw.needFrame > 0) lw.needFrame--; else { schedule(); return; } }
    var t = performance.now(); lastFrame = t;
    var q = queue; queue = [];
    for (var i = 0; i < q.length; i++) {
      var e = q[i];
      if (cancelled[e.id]) { delete cancelled[e.id]; continue; }
      try { e.cb(t); } catch (err) { setTimeout(function(){ throw err; }); }
    }
    if (queue.length) schedule();
  }
  window.requestAnimationFrame = function(cb){ var id = ++seq; queue.push({id:id, cb:cb}); schedule(); return id; };
  window.cancelAnimationFrame = function(id){ cancelled[id] = true; };
  window.webkitRequestAnimationFrame = window.requestAnimationFrame;
})();
"""#

    // MARK: Медиа (webm, gif)

    static let mediaHTML = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;height:100%;overflow:hidden;background:#000}video,img{position:fixed;inset:0;width:100%;height:100%;object-fit:cover;display:none}</style>
</head><body><video id="v" autoplay loop muted playsinline></video><img id="i">
<script>
var V = document.getElementById('v'), I = document.getElementById('i');
var FIT = {fill:'cover', fit:'contain', stretch:'fill'};
window.__lwSetMedia = function(o){
  if (o.kind === 'video') { V.style.objectFit = o.fit; V.style.display = 'block'; V.src = o.url; var r = V.play(); if (r && r.catch) r.catch(function(){}); }
  else {
    I.style.objectFit = o.fit; I.style.display = 'block';
    // Пиксель-арт и маленькие GIF масштабируем без размытия
    I.onload = function(){ if (I.naturalWidth && I.naturalWidth < 900) I.style.imageRendering = 'pixelated'; };
    I.src = o.url;
  }
  applyProps(window.__lw ? __lw.props : {});
};
function applyProps(p){
  if (p.fill) { var f = FIT[p.fill.value] || 'cover'; V.style.objectFit = f; I.style.objectFit = f; }
  if (p.rate) V.playbackRate = parseFloat(p.rate.value) || 1;
}
window.addEventListener('lw-properties', function(e){ applyProps(e.detail || {}); });
</script></body></html>
"""#

    // MARK: GLSL-шейдеры (WebGL2, совместимость с Shadertoy)

    static let shaderHTML = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;height:100%;overflow:hidden;background:#000}canvas{position:fixed;inset:0;width:100%;height:100%;display:block}
#err{position:fixed;left:16px;top:16px;right:16px;color:#ff8080;font:12px Menlo,monospace;white-space:pre-wrap;display:none;background:rgba(0,0,0,.75);padding:10px;border-radius:8px}</style>
</head><body><canvas id="c"></canvas><div id="err"></div>
<script>
(function(){
var cv = document.getElementById('c'), errEl = document.getElementById('err');
var gl = cv.getContext('webgl2', {antialias:false, alpha:false, preserveDrawingBuffer:false, powerPreference:'low-power', desynchronized:true});
function post(m){ if (window.__lwPost) window.__lwPost(m); }
if (!gl) { post({type:'error', message:'WebGL2 недоступен'}); return; }
var prog = null, U = {}, time = 0, last = null, frame = 0, sm = [0,0,0,0];
var vao = gl.createVertexArray(); gl.bindVertexArray(vao);
var vb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, vb);
gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
var atex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, atex);
gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 64, 1, 0, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(64));
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
var abuf = new Uint8Array(64);
function showErr(m){ errEl.textContent = m; errEl.style.display = m ? 'block' : 'none'; if (m) post({type:'error', message:m}); }
function sh(type, src){ var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { var l = gl.getShaderInfoLog(s); gl.deleteShader(s); throw new Error(l); } return s; }
var VS = '#version 300 es\nlayout(location=0) in vec2 p;\nvoid main(){ gl_Position = vec4(p, 0.0, 1.0); }';
var HEAD = '#version 300 es\nprecision highp float;\nprecision highp int;\nuniform vec3 iResolution;\nuniform float iTime;\nuniform float iTimeDelta;\nuniform int iFrame;\nuniform vec4 iMouse;\nuniform vec4 iAudio;\nuniform vec4 iDate;\nuniform sampler2D iSpectrum;\nuniform vec4 iAmbient;\n';
window.__lwSetShader = function(src){
  try {
    var body = String(src).replace(/^\s*#version[^\n]*\n/, '');
    var fs;
    if (/mainImage/.test(body)) {
      var extra = '';
      if (/iChannel0/.test(body) && !/uniform\s+sampler2D\s+iChannel0/.test(body)) extra += 'uniform sampler2D iChannel0;\n';
      fs = HEAD + extra + 'out vec4 lw_out;\n' + body + '\nvoid main(){ vec4 c = vec4(0.0,0.0,0.0,1.0); mainImage(c, gl_FragCoord.xy); lw_out = vec4(c.rgb, 1.0); }\n';
    } else fs = HEAD + body;
    var p = gl.createProgram();
    gl.attachShader(p, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    prog = p; U = {}; if (window.__lw) __lw.needFrame = 3;
    var n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (var i = 0; i < n; i++) { var inf = gl.getActiveUniform(p, i); U[inf.name.replace(/\[0\]$/, '')] = {loc: gl.getUniformLocation(p, inf.name), type: inf.type}; }
    showErr('');
  } catch(e) { showErr('Ошибка шейдера:\n' + e.message); }
};
function prop(k, d){ var p = window.__lw && __lw.props[k]; return p ? p.value : d; }
function rgb(v){ var a = String(v).trim().split(/\s+/).map(parseFloat); return [a[0]||0, a[1]||0, a[2]||0]; }
function u(name, fn){ var e = U[name]; if (e) fn(e.loc); }
function loop(t){
  requestAnimationFrame(loop);
  render(t);
}
// Снимок: рендерим кадр и читаем canvas в той же задаче (буфер не сохраняется между кадрами).
window.__lwSnapshot = function(){ render(performance.now()); return cv.toDataURL('image/jpeg', 0.85); };
function render(t){
  if (!prog) return;
  var dt = last == null ? 0.016 : Math.min(0.1, (t - last) / 1000); last = t;
  var sdt = dt * (parseFloat(prop('speed', 1)) || 0); time += sdt;
  var q = Math.max(0.1, parseFloat(prop('quality', 1)) || 1);
  var w = Math.max(1, Math.round(innerWidth * q)), h = Math.max(1, Math.round(innerHeight * q));
  if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
  gl.viewport(0, 0, w, h); gl.useProgram(prog);
  var a = (window.__lw && __lw.audio) || [], b = 0, m = 0, hi = 0, all = 0;
  for (var i = 0; i < 64; i++) { var v = ((a[i]||0) + (a[i+64]||0)) * 0.5; abuf[i] = Math.min(255, v * 255); all += v; if (i < 6) b += v; else if (i < 26) m += v; else hi += v; }
  var tg = [b/6, m/20, hi/38, all/64]; for (var j = 0; j < 4; j++) sm[j] += (tg[j] - sm[j]) * 0.35;
  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, atex);
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 64, 1, gl.RED, gl.UNSIGNED_BYTE, abuf);
  var mo = (window.__lw && __lw.mouse) || {x:.5, y:.5}, d = new Date();
  u('iResolution', function(l){ gl.uniform3f(l, w, h, 1); });
  u('iTime', function(l){ gl.uniform1f(l, time); });
  u('iTimeDelta', function(l){ gl.uniform1f(l, sdt); });
  u('iFrame', function(l){ gl.uniform1i(l, frame); });
  u('iMouse', function(l){ gl.uniform4f(l, mo.x * w, (1 - mo.y) * h, 0, 0); });
  u('iAudio', function(l){ gl.uniform4f(l, sm[0], sm[1], sm[2], sm[3]); });
  u('iDate', function(l){ gl.uniform4f(l, d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()*3600 + d.getMinutes()*60 + d.getSeconds()); });
  u('iSpectrum', function(l){ gl.uniform1i(l, 0); });
  var am = (window.__lw && __lw.ambient) || {};
  u('iAmbient', function(l){ gl.uniform4f(l, am.night || 0, am.golden || 0, am.precip === 'snow' ? 2 : (am.precip === 'rain' ? 1 : 0), am.cloud || 0); });
  u('iChannel0', function(l){ gl.uniform1i(l, 0); });
  for (var k in U) {
    if (k.indexOf('u_') !== 0) continue;
    var val = prop(k, null); if (val == null) continue;
    var e = U[k];
    if (e.type === gl.FLOAT) gl.uniform1f(e.loc, parseFloat(val));
    else if (e.type === gl.FLOAT_VEC3) { var c = rgb(val); gl.uniform3f(e.loc, c[0], c[1], c[2]); }
    else if (e.type === gl.BOOL) gl.uniform1i(e.loc, (val === true || val === 'true' || val === 1) ? 1 : 0);
    else if (e.type === gl.INT) gl.uniform1i(e.loc, typeof val === 'boolean' ? (val ? 1 : 0) : parseInt(val));
  }
  gl.bindVertexArray(vao); gl.drawArrays(gl.TRIANGLES, 0, 3); frame++;
}
requestAnimationFrame(loop);
})();
</script></body></html>
"""#

    // MARK: Сцены (WebGL2: слои, эффекты, частицы, текст)

    static let sceneHTML = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;height:100%;overflow:hidden;background:#000}canvas{position:fixed;inset:0;width:100%;height:100%;display:block}#ov{pointer-events:none}</style>
</head><body><canvas id="c"></canvas><canvas id="ov"></canvas>
<script>
(function(){
'use strict';
var cv = document.getElementById('c'), ov = document.getElementById('ov'), octx = ov.getContext('2d');
var gl = cv.getContext('webgl2', {alpha:false, antialias:false, premultipliedAlpha:true, preserveDrawingBuffer:false, powerPreference:'low-power', desynchronized:true});
function post(m){ if (window.__lwPost) window.__lwPost(m); }
if (!gl) { post({type:'error', message:'WebGL2 недоступен'}); return; }

var scene = {width:1920, height:1080, background:'#000000', layers:[]}, base = '', editor = false, selected = null, editorParallax = false;
var W = 1, H = 1, DPR = 1, S = 1, OX = 0, OY = 0, time = 0, last = null;
var mouse = {sx:.5, sy:.5}, au = {bass:0, mid:0, high:0, level:0}, P = {parallax:1, speed:1, quality:1};
var texCache = {}, systems = {}, texts = {}, lastXf = {}, ovDirty = true;

function hex(h, a){ h = String(h || '#ffffff').replace('#', ''); if (h.length === 3) h = h.split('').map(function(c){ return c + c; }).join('');
  var n = parseInt(h.slice(0, 6), 16); if (isNaN(n)) n = 0xffffff; return [((n>>16)&255)/255, ((n>>8)&255)/255, (n&255)/255, a == null ? 1 : a]; }
function compile(vs, fs){
  function s(t, src){ var o = gl.createShader(t); gl.shaderSource(o, src); gl.compileShader(o); if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(o)); return o; }
  var p = gl.createProgram(); gl.attachShader(p, s(gl.VERTEX_SHADER, vs)); gl.attachShader(p, s(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  var u = {}, n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
  for (var i = 0; i < n; i++) { var inf = gl.getActiveUniform(p, i); u[inf.name] = gl.getUniformLocation(p, inf.name); }
  return {p:p, u:u};
}
var QVS = '#version 300 es\nin vec2 a_pos;uniform vec2 u_res;uniform vec2 u_center;uniform vec2 u_size;uniform float u_rot;out vec2 v_uv;\nvoid main(){vec2 p=a_pos*u_size;float c=cos(u_rot),s=sin(u_rot);p=vec2(p.x*c-p.y*s,p.x*s+p.y*c)+u_center;vec2 q=p/u_res*2.0-1.0;gl_Position=vec4(q.x,-q.y,0.0,1.0);v_uv=a_pos+0.5;}';
var QFS = ['#version 300 es','precision highp float;','in vec2 v_uv;','uniform sampler2D u_tex;','uniform float u_opacity;','uniform vec3 u_hsb;','uniform vec4 u_wave;','uniform float u_time;','uniform vec4 u_tint;','uniform float u_blur;','uniform vec2 u_texel;','uniform float u_feather;','out vec4 o;',
 'vec3 rgb2hsv(vec3 c){vec4 K=vec4(0.0,-1.0/3.0,2.0/3.0,-1.0);vec4 p=mix(vec4(c.bg,K.wz),vec4(c.gb,K.xy),step(c.b,c.g));vec4 q=mix(vec4(p.xyw,c.r),vec4(c.r,p.yzx),step(p.x,c.r));float d=q.x-min(q.w,q.y);float e=1.0e-10;return vec3(abs(q.z+(q.w-q.y)/(6.0*d+e)),d/(q.x+e),q.x);}',
 'vec3 hsv2rgb(vec3 c){vec4 K=vec4(1.0,2.0/3.0,1.0/3.0,3.0);vec3 p=abs(fract(c.xxx+K.xyz)*6.0-K.www);return c.z*mix(K.xxx,clamp(p-K.xxx,0.0,1.0),c.y);}',
 'void main(){vec2 uv=v_uv;',
 ' if(u_wave.x>0.0){ if(u_wave.w>0.5){ uv.x+=sin(uv.y*u_wave.y*6.2831+u_time*u_wave.z)*u_wave.x*0.02; } else { uv.y+=sin(uv.x*u_wave.y*6.2831+u_time*u_wave.z)*u_wave.x*0.02; } }',
 ' vec4 c; if(u_blur>0.0){ c=vec4(0.0); for(int i=-2;i<=2;i++){ for(int j=-2;j<=2;j++){ c+=texture(u_tex,uv+vec2(float(i),float(j))*u_texel*u_blur); } } c/=25.0; } else { c=texture(u_tex,uv); }',
 ' vec3 h=rgb2hsv(c.rgb); h.x=fract(h.x+u_hsb.x); h.y=clamp(h.y*u_hsb.y,0.0,1.0); vec3 rgb=hsv2rgb(h)*u_hsb.z*u_tint.rgb;',
 ' float a=c.a*u_opacity*u_tint.a;',
 ' if(u_feather>0.0){ a*=smoothstep(0.0,u_feather,v_uv.x)*smoothstep(0.0,u_feather,1.0-v_uv.x)*smoothstep(0.0,u_feather,v_uv.y)*smoothstep(0.0,u_feather,1.0-v_uv.y); }',
 ' o=vec4(rgb*a,a);}'].join('\n');
var PVS = '#version 300 es\nin vec2 a_p;in float a_s;in float a_a;in float a_m;uniform vec2 u_res;out float v_a;out float v_m;\nvoid main(){vec2 q=a_p/u_res*2.0-1.0;gl_Position=vec4(q.x,-q.y,0.0,1.0);gl_PointSize=a_s;v_a=a_a;v_m=a_m;}';
var PFS = '#version 300 es\nprecision highp float;in float v_a;in float v_m;uniform vec3 u_c1;uniform vec3 u_c2;uniform int u_shape;uniform int u_useTex;uniform sampler2D u_tex;out vec4 o;\n' +
 'void main(){vec2 d=gl_PointCoord-0.5;float r=length(d);vec3 col=mix(u_c1,u_c2,v_m);float a;' +
 'if(u_useTex==1){vec4 t=texture(u_tex,gl_PointCoord);col*=t.rgb;a=t.a;}' +
 'else if(u_shape==1){a=(1.0-smoothstep(0.40,0.5,r))*(0.35+0.65*smoothstep(0.25,0.48,r));}' +
 'else if(u_shape==2){a=max(0.0,1.0-abs(d.x)*10.0)*max(0.0,1.0-abs(d.y)*2.0);}' +
 'else{a=pow(max(0.0,1.0-r*2.0),1.6);}a*=v_a;o=vec4(col*a,a);}';

var QP, PP;
try { QP = compile(QVS, QFS); PP = compile(PVS, PFS); } catch(e) { post({type:'error', message:'Рантайм сцены: ' + e.message}); return; }

var qvao = gl.createVertexArray(); gl.bindVertexArray(qvao);
var qb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, qb);
gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-.5,-.5, .5,-.5, -.5,.5, -.5,.5, .5,-.5, .5,.5]), gl.STATIC_DRAW);
var ql = gl.getAttribLocation(QP.p, 'a_pos'); gl.enableVertexAttribArray(ql); gl.vertexAttribPointer(ql, 2, gl.FLOAT, false, 0, 0);
var pvao = gl.createVertexArray(); gl.bindVertexArray(pvao);
var pb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, pb);
[['a_p',2,0],['a_s',1,8],['a_a',1,12],['a_m',1,16]].forEach(function(a){ var l = gl.getAttribLocation(PP.p, a[0]); if (l < 0) return; gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, a[1], gl.FLOAT, false, 20, a[2]); });
gl.bindVertexArray(null);

function texParams(mip){
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mip ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}
var white = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, white);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([255,255,255,255])); texParams(false);
var wtex = {t:white, pw:1, ph:1};

function getTex(file){
  if (!file) return null;
  var url = base + String(file).split('/').map(encodeURIComponent).join('/');
  var e = texCache[url];
  if (!e) {
    e = texCache[url] = {t:gl.createTexture(), pw:0, ph:0, ready:false};
    var im = new Image();
    im.onload = function(){
      gl.bindTexture(gl.TEXTURE_2D, e.t); gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, im); gl.generateMipmap(gl.TEXTURE_2D); texParams(true);
      e.pw = im.naturalWidth; e.ph = im.naturalHeight; e.ready = true;
    };
    im.onerror = function(){ post({type:'error', message:'Не удалось загрузить ' + file}); };
    im.src = url;
  }
  return e.ready ? e : null;
}

function layout(){
  // Разрешение рендера: quality × CSS-пиксели (1 = без Retina-удвоения, в 4 раза дешевле).
  var d = editor ? Math.min(window.devicePixelRatio || 1, 2) : Math.max(0.25, Math.min(2, num(parseFloat(P.quality), 1))), w = innerWidth, h = innerHeight;
  if (w !== W || h !== H || d !== DPR) { W = w; H = h; DPR = d; cv.width = Math.round(W*DPR); cv.height = Math.round(H*DPR); ov.width = cv.width; ov.height = cv.height; ovDirty = true; }
  S = Math.max(W / scene.width, H / scene.height); OX = (W - scene.width * S) / 2; OY = (H - scene.height * S) / 2;
}
function updAudio(){
  var a = (window.__lw && __lw.audio) || [], b = 0, m = 0, h = 0, l = 0;
  for (var i = 0; i < 64; i++) { var v = ((a[i]||0) + (a[i+64]||0)) * 0.5; l += v; if (i < 6) b += v; else if (i < 26) m += v; else h += v; }
  var t = {bass:b/6, mid:m/20, high:h/38, level:l/64}; for (var k in t) au[k] += (t[k] - au[k]) * 0.35;
}
function band(n){ return au[n] || 0; }
function rawMouse(){ return (window.__lw && __lw.mouse) || {x:.5, y:.5}; }
function updMouse(dt){
  var m = rawMouse(), tx = m.x, ty = m.y;
  if (editor && !editorParallax) { tx = .5; ty = .5; }
  var k = Math.min(1, dt * 5); mouse.sx += (tx - mouse.sx) * k; mouse.sy += (ty - mouse.sy) * k;
}
function blend(m){
  if (m === 'add') gl.blendFunc(gl.ONE, gl.ONE);
  else if (m === 'screen') gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_COLOR);
  else if (m === 'multiply') gl.blendFunc(gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA);
  else gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
}
function num(v, d){ return (v == null || isNaN(v)) ? d : v; }
function xform(L, w, h){
  var par = num(L.parallax, 0) * P.parallax;
  var dx = -(mouse.sx - .5) * par * 80 * S, dy = -(mouse.sy - .5) * par * 80 * S;
  var pulse = 1 + num(L.audioPulse, 0) * band(L.audioBand || 'bass');
  var ex = 1 + 0.05 * par;
  return {cx: OX + L.x * scene.width * S + dx, cy: OY + L.y * scene.height * S + dy,
          sw: w * L.scale * S * ex * pulse, sh: h * L.scale * S * ex * pulse,
          rot: (num(L.rotation, 0) + num(L.rotationSpeed, 0) * time) * Math.PI / 180};
}
function quad(t, X, o){
  gl.useProgram(QP.p); gl.bindVertexArray(qvao);
  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, t.t);
  var u = QP.u;
  gl.uniform1i(u.u_tex, 0); gl.uniform2f(u.u_res, W, H); gl.uniform2f(u.u_center, X.cx, X.cy); gl.uniform2f(u.u_size, X.sw, X.sh);
  gl.uniform1f(u.u_rot, X.rot); gl.uniform1f(u.u_opacity, o.op); gl.uniform3f(u.u_hsb, o.hsb[0], o.hsb[1], o.hsb[2]);
  gl.uniform4f(u.u_wave, o.wave[0], o.wave[1], o.wave[2], o.wave[3]); gl.uniform1f(u.u_time, time);
  gl.uniform4f(u.u_tint, o.tint[0], o.tint[1], o.tint[2], o.tint[3]); gl.uniform1f(u.u_blur, o.blur || 0);
  gl.uniform2f(u.u_texel, 1 / (t.pw || 1), 1 / (t.ph || 1)); gl.uniform1f(u.u_feather, o.feather || 0);
  gl.drawArrays(gl.TRIANGLES, 0, 6);
}
function drawSprite(L, t, w, h, tint){
  var X = xform(L, w, h);
  var o = {op: num(L.opacity, 1), hsb: [num(L.hue, 0) / 360, num(L.saturation, 1), num(L.brightness, 1)],
           wave: L.waveEnabled ? [L.waveAmplitude, L.waveFrequency, L.waveSpeed, L.waveVertical ? 1 : 0] : [0,0,0,0], tint: tint, blur: 0, feather: num(L.feather, 0)};
  blend(L.blend); quad(t, X, o);
  if (L.glowEnabled) {
    var gi = num(L.glowIntensity, .5) * (1 + (num(L.audioPulse, 0) > 0 ? band(L.audioBand || 'bass') * 2 : 0));
    blend('add');
    quad(t, {cx:X.cx, cy:X.cy, sw:X.sw * 1.03, sh:X.sh * 1.03, rot:X.rot}, {op:o.op * gi, hsb:o.hsb, wave:o.wave, feather:o.feather, tint:hex(L.glowColor), blur:Math.max(0.5, num(L.glowRadius, 4))});
  }
  return X;
}
function pad(n){ return (n < 10 ? '0' : '') + n; }
function textStr(s){
  var d = new Date(), loc = (window.__lw && __lw.lang === 'en') ? 'en-US' : 'ru-RU', inf = (window.__lw && __lw.info) || {};
  s = String(s || '').replace(/\{(cpu|ram|battery|charging|track|artist|event|eventTime|temp|weather|city)\}/g, function(m, k){ return inf[k] != null ? inf[k] : '—'; });
  return s
    .replace(/\{time:s\}/g, pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()))
    .replace(/\{time\}/g, pad(d.getHours()) + ':' + pad(d.getMinutes()))
    .replace(/\{date\}/g, d.toLocaleDateString(loc, {day:'numeric', month:'long'}))
    .replace(/\{weekday\}/g, d.toLocaleDateString(loc, {weekday:'long'}))
    .replace(/\{year\}/g, String(d.getFullYear()));
}
function textTex(L){
  var s = textStr(L.text), px = Math.max(4, num(L.fontSize, 100) * S * DPR);
  var key = s + '|' + px.toFixed(1) + '|' + L.fontWeight;
  var e = texts[L.id];
  if (!e) e = texts[L.id] = {c:document.createElement('canvas'), t:gl.createTexture(), key:''};
  if (e.key === key) return e;
  var c = e.c, x = c.getContext('2d');
  var font = (L.fontWeight || '600') + ' ' + px + 'px -apple-system, "SF Pro Display", "Helvetica Neue", Arial, sans-serif';
  x.font = font;
  var lines = s.split('\n'), mw = 1; lines.forEach(function(l){ mw = Math.max(mw, x.measureText(l).width); });
  var lh = px * 1.15;
  c.width = Math.ceil(mw + px * 0.5); c.height = Math.ceil(lh * lines.length + px * 0.3);
  x.clearRect(0, 0, c.width, c.height); x.font = font; x.fillStyle = '#fff'; x.textAlign = 'center'; x.textBaseline = 'middle';
  lines.forEach(function(l, i){ x.fillText(l, c.width / 2, px * 0.15 + lh * (i + 0.5)); });
  gl.bindTexture(gl.TEXTURE_2D, e.t); gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, c); texParams(false);
  e.pw = c.width; e.ph = c.height; e.w = c.width / (S * DPR); e.h = c.height / (S * DPR); e.key = key;
  return e;
}
function rnd(a, b){ return a + Math.random() * (b - a); }
function spawn(L, p, pre){
  var dir = (num(L.pDirection, 90) + rnd(-1, 1) * num(L.pSpread, 0)) * Math.PI / 180, sp = num(L.pSpeed, 0) * rnd(0.6, 1.4);
  p.vx = Math.cos(dir) * sp; p.vy = Math.sin(dir) * sp;
  var smin = num(L.pSizeMin, 1); p.size = rnd(smin, Math.max(smin, num(L.pSizeMax, smin)));
  p.life = Math.max(0.2, num(L.pLifetime, 5) * rnd(0.6, 1)); p.age = pre ? Math.random() * p.life : 0;
  p.mix = Math.random(); p.ph = Math.random() * 6.2832;
  var sw = scene.width, sh = scene.height, m = 40;
  if (L.pEmitter === 'top') { p.x = rnd(-m, sw + m); p.y = pre ? rnd(-m, sh) : -m * 0.5; }
  else if (L.pEmitter === 'bottom') { p.x = rnd(-m, sw + m); p.y = pre ? rnd(0, sh + m) : sh + m * 0.5; }
  else if (L.pEmitter === 'point') { p.x = L.x * sw; p.y = L.y * sh; if (pre) { p.x += p.vx * p.age; p.y += p.vy * p.age; } }
  else { p.x = rnd(0, sw); p.y = rnd(0, sh); }
  return p;
}
function drawParticles(L, dt){
  var n = Math.max(0, Math.min(5000, L.pCount | 0)), s = systems[L.id];
  if (!s || s.n !== n || s.em !== L.pEmitter) {
    s = systems[L.id] = {n:n, em:L.pEmitter, p:[], buf:new Float32Array(Math.max(1, n) * 5)};
    for (var i = 0; i < n; i++) s.p.push(spawn(L, {}, true));
  }
  if (!n) return;
  var par = num(L.parallax, 0) * P.parallax, dx = -(mouse.sx - .5) * par * 80 * S, dy = -(mouse.sy - .5) * par * 80 * S;
  var boost = 1 + num(L.pAudio, 0) * au.bass * 3, sw = scene.width, sh = scene.height, m = 160;
  var rm = rawMouse(), mx = (rm.x * W - OX) / S, my = (rm.y * H - OY) / S, repel = !!L.pMouseRepel;
  var g = num(L.pGravity, 0), wob = num(L.pWobble, 0), op = num(L.opacity, 1), sizeK = S * DPR * (1 + num(L.pAudio, 0) * au.bass);
  for (var j = 0; j < n; j++) {
    var p = s.p[j];
    p.age += dt; p.vy += g * dt;
    p.x += (p.vx * boost + Math.sin(time * 1.3 + p.ph) * wob) * dt; p.y += p.vy * boost * dt;
    if (repel) { var ddx = p.x - mx, ddy = p.y - my, d2 = ddx * ddx + ddy * ddy; if (d2 < 22500 && d2 > 1) { var d = Math.sqrt(d2), f = (150 - d) / 150 * 400 * dt; p.x += ddx / d * f; p.y += ddy / d * f; } }
    if (p.age > p.life || p.x < -m || p.x > sw + m || p.y < -m || p.y > sh + m) spawn(L, p, false);
    var a = Math.min(1, p.age / (p.life * 0.15), (p.life - p.age) / (p.life * 0.15)); if (a < 0) a = 0;
    var o = j * 5;
    s.buf[o] = OX + p.x * S + dx; s.buf[o+1] = OY + p.y * S + dy; s.buf[o+2] = p.size * sizeK; s.buf[o+3] = a * op; s.buf[o+4] = p.mix;
  }
  gl.useProgram(PP.p); gl.bindVertexArray(pvao); gl.bindBuffer(gl.ARRAY_BUFFER, pb); gl.bufferData(gl.ARRAY_BUFFER, s.buf, gl.DYNAMIC_DRAW);
  var u = PP.u, c1 = hex(L.pColor), c2 = hex(L.pColor2);
  gl.uniform2f(u.u_res, W, H); gl.uniform3f(u.u_c1, c1[0], c1[1], c1[2]); gl.uniform3f(u.u_c2, c2[0], c2[1], c2[2]);
  var shp = {soft:0, circle:1, streak:2}[L.pShape] || 0, t = L.pShape === 'image' ? getTex(L.file) : null;
  gl.uniform1i(u.u_shape, shp); gl.uniform1i(u.u_useTex, t ? 1 : 0);
  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, t ? t.t : white); gl.uniform1i(u.u_tex, 0);
  blend(L.blend); gl.drawArrays(gl.POINTS, 0, n);
}
function drawOverlay(xf){
  if (!editor && !ovDirty) return;
  octx.setTransform(1, 0, 0, 1, 0, 0); octx.clearRect(0, 0, ov.width, ov.height); ovDirty = false;
  if (!editor || !selected || !xf[selected]) return;
  ovDirty = true;
  var X = xf[selected];
  octx.setTransform(DPR, 0, 0, DPR, 0, 0); octx.translate(X.cx, X.cy); octx.rotate(X.rot);
  octx.strokeStyle = '#4da3ff'; octx.lineWidth = 1.5; octx.setLineDash([6, 4]); octx.strokeRect(-X.sw / 2, -X.sh / 2, X.sw, X.sh);
}
function frame(t){
  requestAnimationFrame(frame);
  render(t);
}
window.__lwSnapshot = function(){ var s = selected; selected = null; render(performance.now()); var u = cv.toDataURL('image/jpeg', 0.85); selected = s; return u; };
function render(t){
  var rdt = last == null ? 0.016 : Math.min(0.1, (t - last) / 1000); last = t;
  var dt = rdt * num(parseFloat(P.speed), 1); time += dt;
  layout(); updAudio(); updMouse(rdt);
  gl.viewport(0, 0, cv.width, cv.height);
  var bg = hex(scene.background); gl.clearColor(bg[0], bg[1], bg[2], 1); gl.clear(gl.COLOR_BUFFER_BIT); gl.enable(gl.BLEND);
  var xf = {}, ls = scene.layers || [];
  for (var i = 0; i < ls.length; i++) {
    var L = ls[i]; if (L.visible === false) continue;
    try {
      if (L.kind === 'image') { var tx = getTex(L.file); if (tx) xf[L.id] = drawSprite(L, tx, tx.pw, tx.ph, hex(L.tint)); }
      else if (L.kind === 'color') xf[L.id] = drawSprite(L, wtex, num(L.width, scene.width), num(L.height, scene.height), hex(L.tint));
      else if (L.kind === 'text') { var te = textTex(L); xf[L.id] = drawSprite(L, te, te.w, te.h, hex(L.textColor)); }
      else if (L.kind === 'particles') drawParticles(L, dt);
    } catch(e) { post({type:'error', message:'Слой «' + L.name + '»: ' + e.message}); }
  }
  if (scene.ambient) drawAmbient(dt);
  lastXf = xf; drawOverlay(xf);
}

// Адаптация к времени суток и погоде: осадки + цветокоррекция всей сцены.
var AMB_RAIN = {id:'__amb_rain', name:'rain', kind:'particles', pEmitter:'top', pCount:0, pSizeMin:10, pSizeMax:22, pSpeed:1100, pDirection:95, pSpread:2,
  pLifetime:3, pGravity:0, pWobble:0, pColor:'#a9c7ff', pColor2:'#d8e6ff', pShape:'streak', opacity:0.55, parallax:0.3, blend:'normal', x:.5, y:.5};
var AMB_SNOW = {id:'__amb_snow', name:'snow', kind:'particles', pEmitter:'top', pCount:0, pSizeMin:2, pSizeMax:7, pSpeed:45, pDirection:90, pSpread:15,
  pLifetime:40, pGravity:0, pWobble:22, pColor:'#ffffff', pColor2:'#cfe3ff', pShape:'soft', opacity:0.9, parallax:0.4, blend:'normal', x:.5, y:.5};
function drawAmbient(dt){
  var a = (window.__lw && __lw.ambient) || {};
  if (scene.ambientPrecip !== false && a.precip && a.precip !== 'none') {
    var L = a.precip === 'snow' ? AMB_SNOW : AMB_RAIN;
    L.pCount = Math.round((a.precip === 'snow' ? 320 : 520) * Math.max(0.2, a.intensity || 0.5));
    drawParticles(L, dt);
  }
  var n = a.night || 0, g = a.golden || 0, c = a.cloud || 0;
  var full = {cx: W / 2, cy: H / 2, sw: W, sh: H, rot: 0};
  var base = {op: 1, hsb: [0, 1, 1], wave: [0, 0, 0, 0], blur: 0, feather: 0};
  if (n > 0.01 || c > 0.05) {
    var k = 1 - 0.12 * c;
    base.tint = [k * (1 - 0.48 * n), k * (1 - 0.40 * n), k * (1 - 0.15 * n), 1];
    blend('multiply'); quad(wtex, full, base);
  }
  if (g > 0.01) {
    base.tint = [1.0, 0.45, 0.18, 1]; base.op = 0.16 * g;
    blend('add'); quad(wtex, full, base);
  }
}

// Редактор: выбор и перетаскивание слоёв
var drag = null, lastPost = 0;
function find(id){ var ls = scene.layers || []; for (var i = 0; i < ls.length; i++) if (ls[i].id === id) return ls[i]; return null; }
cv.addEventListener('mousedown', function(e){
  if (!editor) return;
  var hit = null, ls = scene.layers || [];
  for (var i = ls.length - 1; i >= 0; i--) {
    var L = ls[i], X = lastXf[L.id];
    if (!X || L.visible === false) continue;
    if (Math.abs(e.clientX - X.cx) <= X.sw / 2 && Math.abs(e.clientY - X.cy) <= X.sh / 2) { hit = L; break; }
  }
  selected = hit ? hit.id : null; post({type:'select', id:selected});
  if (hit) drag = {id:hit.id, sx:e.clientX, sy:e.clientY, ox:hit.x, oy:hit.y};
});
window.addEventListener('mousemove', function(e){
  if (editor && window.__lw) __lw.mouse = {x: e.clientX / Math.max(1, innerWidth), y: e.clientY / Math.max(1, innerHeight)};
  if (!drag) return;
  var L = find(drag.id); if (!L) return;
  L.x = drag.ox + (e.clientX - drag.sx) / (scene.width * S); L.y = drag.oy + (e.clientY - drag.sy) / (scene.height * S);
  var n = performance.now(); if (n - lastPost > 50) { lastPost = n; post({type:'move', id:L.id, x:L.x, y:L.y}); }
});
window.addEventListener('mouseup', function(){ if (drag) { var L = find(drag.id); if (L) post({type:'move', id:L.id, x:L.x, y:L.y}); drag = null; } });

window.__lwLoadScene = function(s, b, ed){
  if (typeof s === 'string') s = JSON.parse(s);
  scene = s || scene; base = b || ''; editor = !!ed; ovDirty = true; if (window.__lw) __lw.needFrame = 3;
  var ids = {}; (scene.layers || []).forEach(function(L){ ids[L.id] = 1; });
  for (var k in systems) if (!ids[k]) delete systems[k];
  for (var k2 in texts) if (!ids[k2]) { gl.deleteTexture(texts[k2].t); delete texts[k2]; }
  if (drag) { var L = find(drag.id); if (L) { L.x = drag.lx != null ? drag.lx : L.x; } }
};
window.__lwSelect = function(id){ selected = id; ovDirty = true; };
window.__lwDbg = function(){ return {time:time, n:(scene.layers||[]).length, W:W, H:H, S:S, bg:scene.background}; };
window.__lwEditorParallax = function(b){ editorParallax = !!b; };
function applyProps(p){ if (p.parallax) P.parallax = parseFloat(p.parallax.value); if (p.speed) P.speed = parseFloat(p.speed.value); if (p.quality) P.quality = parseFloat(p.quality.value); }
window.addEventListener('lw-properties', function(e){ applyProps(e.detail || {}); });
if (window.__lw) applyProps(__lw.props);
requestAnimationFrame(frame);
})();
</script></body></html>
"""#
}

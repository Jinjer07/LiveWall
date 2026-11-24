#!/usr/bin/env python3
"""Собирает gallery/: сцены (полные JSON по модели SceneLayer) и index.json."""
import json, os, uuid

ROOT = os.path.join(os.path.dirname(__file__), '..', 'gallery')

DEF = dict(visible=True, file=None, x=0.5, y=0.5, scale=1.0, rotation=0.0, rotationSpeed=0.0, opacity=1.0,
           parallax=0.0, blend='normal', tint='#ffffff', feather=None, hue=0.0, saturation=1.0, brightness=1.0,
           waveEnabled=False, waveAmplitude=0.5, waveFrequency=2.0, waveSpeed=1.0, waveVertical=False,
           glowEnabled=False, glowRadius=4.0, glowIntensity=0.6, glowColor='#ffffff', audioPulse=0.0, audioBand='bass',
           pCount=150, pEmitter='top', pSizeMin=2.0, pSizeMax=6.0, pSpeed=60.0, pDirection=90.0, pSpread=20.0,
           pLifetime=20.0, pGravity=0.0, pWobble=10.0, pColor='#ffffff', pColor2='#cfe3ff', pShape='soft',
           pMouseRepel=False, pAudio=0.0, text='{time}', fontSize=160.0, fontWeight='600', textColor='#ffffff',
           width=1920.0, height=1080.0)

def layer(name, kind, **kw):
    d = dict(DEF); d.update(id=str(uuid.uuid5(uuid.NAMESPACE_URL, name + kind + json.dumps(kw, sort_keys=True))), name=name, kind=kind)
    d.update(kw)
    for k in ('scale','rotation','opacity','parallax','x','y','fontSize','pSizeMin','pSizeMax','pSpeed','pDirection','pSpread','pLifetime','pWobble','width','height','glowRadius','glowIntensity','audioPulse','pAudio','waveAmplitude','waveFrequency','waveSpeed'):
        d[k] = float(d[k])
    if d['feather'] is None: del d['feather']
    if d['file'] is None: del d['file']
    return d

def glow(name, color, y, h, op, w=2600, x=0.5, pulse=0.0):
    return layer(name, 'color', tint=color, y=y, x=x, height=h, width=w, opacity=op, blend='add', feather=0.5, audioPulse=pulse)

def particles(name, **kw):
    return layer(name, 'particles', **kw)

def clock(y=0.42, size=220, weight='200', glowc=None, pulse=0.05, parallax=0.3):
    kw = dict(text='{time}', fontSize=size, fontWeight=weight, y=y, parallax=parallax, audioPulse=pulse)
    if glowc: kw.update(glowEnabled=True, glowRadius=6, glowIntensity=0.5, glowColor=glowc)
    return layer('Часы', 'text', **kw)

def date(y=0.57, size=50, op=0.75):
    return layer('Дата', 'text', text='{weekday}, {date}', fontSize=size, fontWeight='400', y=y, opacity=op, parallax=0.3)

SNOW = dict(pEmitter='top', pCount=260, pSizeMin=2, pSizeMax=7, pSpeed=45, pDirection=90, pSpread=15, pWobble=22, pLifetime=40)
RAIN = dict(pEmitter='top', pCount=520, pSizeMin=10, pSizeMax=22, pSpeed=1100, pDirection=95, pSpread=2, pWobble=0, pLifetime=3,
            pShape='streak', pColor='#a9c7ff', pColor2='#d8e6ff', opacity=0.55)
SPARKS = dict(pEmitter='bottom', pCount=170, pSizeMin=2, pSizeMax=6, pSpeed=95, pDirection=270, pSpread=25, pWobble=18,
              pLifetime=9, blend='add', pColor='#ffb347', pColor2='#ff2d3c', pAudio=0.6)
FIREFLIES = dict(pEmitter='full', pCount=80, pSizeMin=4, pSizeMax=10, pSpeed=14, pDirection=0, pSpread=180, pWobble=30,
                 pLifetime=7, blend='add', pColor='#d8ff6b', pColor2='#7dffb0', pMouseRepel=True)
DUST = dict(pEmitter='full', pCount=160, pSizeMin=1, pSizeMax=3.5, pSpeed=8, pDirection=0, pSpread=180, pWobble=6,
            pLifetime=12, opacity=0.5, parallax=0.6)

SCENES = {
  'snow-night': dict(bg='#070b1c', ambient=True, layers=[
      layer('Небо', 'color', tint='#0d1740'),
      glow('Луна', '#cfd8ff', 0.18, 260, 0.35, w=260, x=0.78),
      glow('Сияние', '#5a3fc0', 0.95, 700, 0.45, pulse=0.15),
      clock(glowc='#7fa8ff'), date(),
      particles('Снег', parallax=0.5, **SNOW)]),
  'embers': dict(bg='#0b0b0d', ambient=False, layers=[
      glow('Жар', '#dc143c', 1.0, 760, 0.7, pulse=0.35),
      glow('Отблеск', '#ff6b42', 1.05, 420, 0.45),
      clock(y=0.40, size=240, weight='800', glowc='#ff3340', pulse=0.08),
      date(y=0.56),
      particles('Искры', parallax=0.6, **SPARKS)]),
  'fireflies': dict(bg='#050d08', ambient=True, layers=[
      glow('Туман', '#1d4a2c', 0.85, 600, 0.6),
      glow('Свет', '#7dffb0', 0.3, 500, 0.12, w=1200, x=0.3),
      particles('Светлячки', parallax=0.8, **FIREFLIES),
      date(y=0.88, size=40, op=0.6)]),
  'minimal': dict(bg='#101012', ambient=False, layers=[
      particles('Пыль', **DUST),
      clock(y=0.46, size=180, weight='100', pulse=0.0, parallax=0.15),
      date(y=0.58, size=34, op=0.5)]),
  'rainy-evening': dict(bg='#0a1020', ambient=True, layers=[
      layer('Сумерки', 'color', tint='#121c36'),
      glow('Фонари', '#ff6b42', 1.0, 500, 0.35),
      clock(glowc='#a9c7ff'), date(),
      particles('Дождь', parallax=0.3, **RAIN)]),
  'dashboard': dict(bg='#0b0b0d', ambient=True, layers=[
      glow('Свечение', '#dc143c', 1.0, 700, 0.45, pulse=0.2),
      particles('Пыль', **dict(DUST, pColor='#ff6b6b', pColor2='#ffffff', opacity=0.35)),
      clock(y=0.40, size=200, weight='200', glowc='#ff3340'),
      date(y=0.54, size=44),
      layer('Погода', 'text', text='{temp}  {weather}\n{city}', fontSize=34, fontWeight='500', x=0.86, y=0.1, opacity=0.9, parallax=0.2),
      layer('Событие', 'text', text='{eventTime}  {event}', fontSize=34, fontWeight='500', x=0.16, y=0.08, opacity=0.9, parallax=0.2),
      layer('Система', 'text', text='CPU {cpu}   RAM {ram}   {charging}{battery}', fontSize=30, fontWeight='500', x=0.2, y=0.93, opacity=0.8, parallax=0.2),
      layer('Музыка', 'text', text='♪ {track}\n{artist}', fontSize=32, fontWeight='500', x=0.84, y=0.9, opacity=0.9, parallax=0.2, textColor='#ffb3bc')]),
}

INDEX = [
  ('snow-night', 'scene', 'Снежная ночь', 'Snowy night', 'Снег, луна, часы. Темнеет и светлеет вместе с вами.', 'Snow, moon and a clock that follows the time of day.', ['часы', 'зима']),
  ('embers', 'scene', 'Угли', 'Embers', 'Алые искры поднимаются в такт басу.', 'Crimson sparks rising to the bass.', ['звук', 'часы']),
  ('fireflies', 'scene', 'Светлячки', 'Fireflies', 'Ночной лес, светлячки разлетаются от курсора.', 'A night forest; fireflies scatter from your cursor.', ['мышь', 'природа']),
  ('minimal', 'scene', 'Минимал', 'Minimal', 'Тонкие часы и пыль в луче света. Почти не нагружает систему.', 'Thin clock and drifting dust. Very light on resources.', ['часы', 'минимализм']),
  ('rainy-evening', 'scene', 'Дождливый вечер', 'Rainy evening', 'Дождь по стеклу и тёплые фонари.', 'Rain and warm street lights.', ['часы', 'дождь']),
  ('dashboard', 'scene', 'Дашборд', 'Dashboard', 'Часы, погода, календарь, музыка и нагрузка системы.', 'Clock, weather, calendar, music and system load.', ['виджеты', 'часы']),
  ('aurora', 'shader', 'Аврора', 'Aurora', 'Полярное сияние со звёздами.', 'Northern lights over a starry sky.', ['шейдер', 'звук']),
  ('plasma', 'shader', 'Алая плазма', 'Crimson plasma', 'Классическая плазма в угольно-алых тонах.', 'Classic plasma in charcoal and crimson.', ['шейдер', 'абстракция']),
  ('starfield', 'shader', 'Звёздный тоннель', 'Warp starfield', 'Полёт сквозь звёзды, ускоряется от баса.', 'Flight through stars that speeds up with the bass.', ['шейдер', 'космос']),
  ('synthgrid', 'shader', 'Неоновая сетка', 'Neon grid', 'Ретро-горизонт с полосатым солнцем.', 'Retro horizon with a striped sun.', ['шейдер', 'ретро']),
  ('lava', 'shader', 'Лавовая лампа', 'Lava lamp', 'Плавные капли лавы.', 'Slowly merging lava blobs.', ['шейдер', 'абстракция']),
  ('ocean', 'shader', 'Океан на закате', 'Ocean at dusk', 'Волны, блики и солнце у горизонта.', 'Waves, glints and the setting sun.', ['шейдер', 'природа']),
]

os.makedirs(os.path.join(ROOT, 'scenes'), exist_ok=True)
items = []
for gid, typ, ru, en, dru, den, tags in INDEX:
    if typ == 'scene':
        s = SCENES[gid]
        doc = dict(version=1, width=1920.0, height=1080.0, background=s['bg'], ambient=s['ambient'], layers=s['layers'])
        with open(os.path.join(ROOT, 'scenes', gid + '.json'), 'w') as f:
            json.dump(doc, f, ensure_ascii=False, indent=2)
        path = 'scenes/' + gid + '.json'
    else:
        path = 'shaders/' + gid + '.frag'
    items.append(dict(id=gid, type=typ, title=dict(ru=ru, en=en), description=dict(ru=dru, en=den),
                      tags=tags, file=path, preview='previews/' + gid + '.jpg', version=1))
with open(os.path.join(ROOT, 'index.json'), 'w') as f:
    json.dump(dict(version=1, items=items), f, ensure_ascii=False, indent=2)
print('items:', len(items))

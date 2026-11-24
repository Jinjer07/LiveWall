#!/usr/bin/env python3
"""Оборачивает русские строковые литералы Swift в tr(...) и собирает ключи перевода.
Интерполяции \\(expr) превращаются в %@ + аргументы tr. Сырые (#"...") и многострочные строки не трогаются."""
import re, sys, os, json

CYR = re.compile('[А-Яа-яЁё]')
SKIP_FILES = {'LocEN.swift', 'Localization.swift', 'RuntimeFiles.swift'}

def scan_string(src, i):
    """i — индекс открывающей кавычки. Возвращает (end, parts) где parts — список ('text', s) / ('interp', expr)."""
    assert src[i] == '"'
    j = i + 1; parts = []; buf = ''
    while j < len(src):
        c = src[j]
        if c == '\\' and j + 1 < len(src) and src[j+1] == '(':
            if buf: parts.append(('text', buf)); buf = ''
            k = j + 2; depth = 1; expr = ''
            while k < len(src) and depth:
                ch = src[k]
                if ch == '"':
                    e, _ = scan_string(src, k); expr += src[k:e]; k = e; continue
                if ch == '(': depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0: break
                expr += ch; k += 1
            parts.append(('interp', expr)); j = k + 1; continue
        if c == '\\':
            buf += src[j:j+2]; j += 2; continue
        if c == '"':
            if buf: parts.append(('text', buf))
            return j + 1, parts
        if c == '\n': raise ValueError('newline in string')
        buf += c; j += 1
    raise ValueError('unterminated')

def process(src):
    out = []; i = 0; keys = []
    n = len(src)
    while i < n:
        c = src[i]
        # комментарии
        if src.startswith('//', i):
            e = src.find('\n', i); e = n if e < 0 else e
            out.append(src[i:e]); i = e; continue
        if src.startswith('/*', i):
            e = src.find('*/', i) + 2; out.append(src[i:e]); i = e; continue
        # сырые и многострочные строки — пропускаем целиком
        m = re.match(r'(#+)"""', src[i:])
        if m:
            term = '"""' + m.group(1); e = src.find(term, i + len(m.group(0))) + len(term)
            out.append(src[i:e]); i = e; continue
        m = re.match(r'(#+)"', src[i:])
        if m:
            term = '"' + m.group(1); e = src.find(term, i + len(m.group(0))) + len(term)
            out.append(src[i:e]); i = e; continue
        if src.startswith('"""', i):
            e = src.find('"""', i + 3) + 3; out.append(src[i:e]); i = e; continue
        if c == '"':
            end, parts = scan_string(src, i)
            lit = src[i:end]
            text_only = ''.join(p[1] for p in parts if p[0] == 'text')
            already = re.search(r'\btr\(\s*$', ''.join(out)[-8:]) is not None
            if CYR.search(text_only) and not already:
                key = ''; args = []
                for kind, v in parts:
                    if kind == 'text': key += v
                    else: key += '%@'; args.append(v.strip())
                rendered = 'tr("' + key + '"' + ''.join(', ' + a for a in args) + ')'
                out.append(rendered); keys.append(key)
            else:
                if CYR.search(text_only) and already:
                    keys.append(''.join(('%@' if k == 'interp' else v) for k, v in parts))
                out.append(lit)
            i = end; continue
        out.append(c); i += 1
    return ''.join(out), keys

all_keys = []
root = sys.argv[1]
dry = '--dry' in sys.argv
for dp, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith('.swift') or f in SKIP_FILES: continue
        p = os.path.join(dp, f)
        s = open(p).read()
        new, keys = process(s)
        all_keys += keys
        if new != s and not dry:
            open(p, 'w').write(new)
seen = []; [seen.append(k) for k in all_keys if k not in seen]
json.dump(seen, open(sys.argv[2], 'w'), ensure_ascii=False, indent=0)
print(len(seen), 'keys')

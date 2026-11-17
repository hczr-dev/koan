#!/usr/bin/env python3
"""Koan's name in the app's own words, at build time.

Writes a branded copy of the sources into a mirror folder: "Yab" becomes the
fork's name inside Swift string literals and in the permission prompts of
build.sh, nothing else. The repository itself stays Yab's code, so merging
upstream Yab never conflicts over wording. A file is written only when its
branded text changed, so the mirror's incremental builds stay incremental.

Left alone: comments, a literal that is exactly "Yab" (keychain accounts,
protocol and header values), "Yab Dev", "Yab (...)", "Yab Prerelease" (the
data folder), names of files, bundles and helpers, and any line that reads
like an identifier (keychain, HTTP headers, defaults keys, notifications).
"""
import os, re, shutil, sys

SRC, DST, NAME = sys.argv[1], sys.argv[2], sys.argv[3]
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
WORD = re.compile(r'(?<![./\w-])Yab(?![\w.(/-])(?! Dev\b)(?! \()(?! Prerelease\b)(?! Helper\b)(?! Core\b)')
SKIP_LINE = re.compile(r'kSecAttr|forHTTPHeaderField|forAnnotationKey|forKey:|Notification\.Name|quarantine|HSTBRSR|scriptHandler|'
                       r'bundleIdentifier|NSRunningApplication|localizedName|processName|YabDataName|\baccount\b|\bservice\b|\.sdef|\.plist')

FILE = re.compile(r'\.[A-Za-z0-9]{2,5}"$')
def brand_literal(text):
    # exactly "Yab" (an identifier), or a file or resource name
    if text == '"Yab"' or FILE.search(text):
        return text
    return WORD.sub(NAME, text)

def brand_swift(source):
    out, in_block = [], False
    for line in source.split('\n'):
        stripped = line.lstrip()
        quotes = line.count('"""')
        if in_block:
            if not SKIP_LINE.search(line):
                head, sep, tail = line.partition('"""') if quotes else (line, '', '')
                line = WORD.sub(NAME, head) + sep + tail
            if quotes % 2 == 1:
                in_block = False
            out.append(line)
            continue
        if quotes % 2 == 1:
            in_block = True
            out.append(line)
            continue
        if stripped.startswith('//') or SKIP_LINE.search(line) or 'Yab' not in line:
            out.append(line)
            continue
        code, comment = line, ''
        cut = re.search(r'\s//(?![^"]*")', line)
        if cut:
            code, comment = line[:cut.start()], line[cut.start():]
        out.append(LITERAL.sub(lambda m: brand_literal(m.group(0)), code) + comment)
    return '\n'.join(out)

PROMPTS = re.compile(r'(<string>[^<]*?)\bYab (asks|reads|sends)')
def brand_build(text):
    return PROMPTS.sub(lambda m: m.group(1) + NAME + ' ' + m.group(2), text)

def put(path, data):
    if os.path.exists(path):
        with open(path, 'rb') as old:
            if old.read() == data:
                return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as new:
        new.write(data)
    return True

changed = branded = 0
wanted = set()
for root, dirs, files in os.walk(os.path.join(SRC, 'Sources')):
    for name in files:
        src = os.path.join(root, name)
        rel = os.path.relpath(src, SRC)
        wanted.add(rel)
        with open(src, 'rb') as f:
            data = f.read()
        if name.endswith('.swift'):
            text = data.decode('utf-8')
            new = brand_swift(text)
            if new != text:
                branded += 1
            data = new.encode('utf-8')
        if put(os.path.join(DST, rel), data):
            changed += 1
for root, dirs, files in os.walk(os.path.join(DST, 'Sources')):
    for name in files:
        rel = os.path.relpath(os.path.join(root, name), DST)
        if rel not in wanted:
            os.remove(os.path.join(DST, rel))
with open(os.path.join(SRC, 'build.sh'), encoding='utf-8') as f:
    if put(os.path.join(DST, 'build.sh'), brand_build(f.read()).encode('utf-8')):
        changed += 1
os.chmod(os.path.join(DST, 'build.sh'), 0o755)
print(f'brand: {NAME} in {branded} source files, {changed} written')

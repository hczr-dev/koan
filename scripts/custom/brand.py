#!/usr/bin/env python3
"""Koan's name in the app's own words, at build time.

Writes a branded copy of the sources into a mirror folder: "Yab" becomes the
fork's name inside Swift string literals and in the permission prompts of
build.sh, nothing else. The repository itself stays Yab's code, so merging
upstream Yab never conflicts over wording. A file is written only when its
branded text changed, so the mirror's incremental builds stay incremental.

Left alone: comments, a literal that is exactly "Yab" (keychain accounts,
protocol and header values), "Yab Dev", "Yab (...)", "Yab Prerelease" (the
data folder), names of files the app ships, of bundles and helpers, a
"Yab." or "Yab-" that goes on into an identifier, any line that reads like
one (keychain, HTTP headers, defaults keys, notifications), and what Google's
own sign-in page says, where Yab's app is the one asking.

Beside the Swift: Settings' strings table, the AppleScript dictionary's
words, the messages page scripts show, and a few lines that are more than
the name (PATCHES: the welcome's "yet another browser.", Settings › About).
"""
import os, re, shutil, sys

SRC, DST, NAME = sys.argv[1], sys.argv[2], sys.argv[3]
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
WORD = re.compile(r'(?<![./\w-])Yab(?![\w(/-])(?!\.\w)(?! Dev\b)(?! \()(?! Prerelease\b)(?! Helper\b)(?! Core\b)')
SKIP_LINE = re.compile(r'kSecAttr|forHTTPHeaderField|forAnnotationKey|forKey:|Notification\.Name|quarantine|HSTBRSR|scriptHandler|'
                       r'bundleIdentifier|NSRunningApplication|localizedName|processName|YabDataName|\.sdef|\.plist|'
                       r'\b(?:account|service)\s*[:=]\s*"|'
                       # Google's consent page names the app that asks: Yab's.
                       r'Go to Yab|verified Yab|checked Yab')

# A file the app ships keeps its name ("Yab Question.aiff"); a file it
# writes for you takes the fork's ("Yab Passwords.csv").
SHIPPED = set()
for top in ('Resources', 'Icon', 'Sources'):
    for _, _, names in os.walk(os.path.join(SRC, top)):
        SHIPPED.update(names)
FILE = re.compile(r'([^"/]+\.[A-Za-z0-9]{2,5})"$')
def brand_literal(text):
    # exactly "Yab" (an identifier), or a file the app ships
    if text in ('"Yab"', "'Yab'"):
        return text
    m = FILE.search(text)
    if m and m.group(1) in SHIPPED:
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
    text = PROMPTS.sub(lambda m: m.group(1) + NAME + ' ' + m.group(2), text)
    return text.replace('<string>© 2026 Serafim Korablev · Yab</string>',
                        f'<string>{NAME}, built on Yab © 2026 Serafim Korablev</string>')

# Lines that say more than the name, in the branded copy only. One that no
# longer matches upstream's is said and skipped, never half applied.
LOWER = NAME.lower()
PATCHES = {
    'Sources/Fast/WelcomeHero.swift': [
        # The welcome's name, folding into the header's logotype as Yab's
        # "yet another browser." folds into "yab".
        ('static let texts: [(String, Int?)] = [("y", 0), ("et ", nil), ("a", 1), ("nother ", nil), ("b", 2), ("rowser", nil), (".", nil)]',
         f'static let texts: [(String, Int?)] = [("{LOWER}", 0), (".", nil)]'),
        ('static let headerTexts: [(String, Int?)] = [("y", 0), ("a", 1), ("b", 2)]',
         f'static let headerTexts: [(String, Int?)] = [("{LOWER}", 0)]'),
        ('static let words: [[Int]] = [[0, 1], [2, 3], [4, 5, 6]]', 'static let words: [[Int]] = [[0, 1]]'),
        # The pen's line goes under the name.
        ('return (CTLineGetOffsetForStringIndex(line, 4, nil), CTLineGetOffsetForStringIndex(line, 11, nil))',
         f'return (CTLineGetOffsetForStringIndex(line, 0, nil), CTLineGetOffsetForStringIndex(line, {len(LOWER)}, nil))'),
    ],
    'Sources/Fast/SettingsCorePages.swift': [
        ('Text("yet another browser.").font(.system(size: 20, weight: .semibold))',
         f'Text("{LOWER}.").font(.system(size: 20, weight: .semibold))'),
        ('Text("A browser for your Mac.")', 'Text("A browser for your Mac, built on Yab.")'),
    ],
    'Sources/Fast/Mcp.swift': [
        ('Tools for Yab (yet another browser), the user', f'Tools for {NAME}, the user'),
    ],
}
def patch(rel, text):
    for old, new in PATCHES.get(rel, []):
        if old in text:
            text = text.replace(old, new)
        else:
            print(f'brand: {rel} no longer has: {old[:70]}', file=sys.stderr)
    return text

# Settings' strings table: both sides, as the Swift asking for them is.
STRINGS = re.compile(r'^("(?:[^"\\]|\\.)*")(\s*=\s*)("(?:[^"\\]|\\.)*")(;.*)$', re.M)
def brand_strings(text):
    return STRINGS.sub(lambda m: brand_literal(m.group(1)) + m.group(2) + brand_literal(m.group(3)) + m.group(4), text)

# The AppleScript dictionary: its words, never its codes or names.
SDEF = re.compile(r'((?:description|title)=")([^"]*)(")')
def brand_sdef(text):
    return SDEF.sub(lambda m: m.group(1) + WORD.sub(NAME, m.group(2)) + m.group(3), text)

# Page scripts: the messages in their string literals.
JS_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')
def brand_js(text):
    out = []
    for line in text.split('\n'):
        if 'Yab' in line and not line.lstrip().startswith(('//', '*', '/*')):
            line = JS_LITERAL.sub(lambda m: brand_literal(m.group(0)), line)
        out.append(line)
    return '\n'.join(out)

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
            new = patch(rel, brand_swift(text))
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
# Resources came over with rsync, as they are upstream: branded in place.
for root, dirs, files in os.walk(os.path.join(SRC, 'Resources')):
    for name in files:
        kind = ('strings' if name.endswith('.strings') else 'sdef' if name.endswith('.sdef')
                else 'js' if name.endswith('.js') and os.path.basename(root) == 'PageScripts' else None)
        if not kind:
            continue
        rel = os.path.relpath(os.path.join(root, name), SRC)
        with open(os.path.join(SRC, rel), encoding='utf-8') as f:
            text = f.read()
        new = {'strings': brand_strings, 'sdef': brand_sdef, 'js': brand_js}[kind](text)
        if new != text:
            branded += 1
            if put(os.path.join(DST, rel), new.encode('utf-8')):
                changed += 1
with open(os.path.join(SRC, 'build.sh'), encoding='utf-8') as f:
    if put(os.path.join(DST, 'build.sh'), brand_build(f.read()).encode('utf-8')):
        changed += 1
os.chmod(os.path.join(DST, 'build.sh'), 0o755)
print(f'brand: {NAME} in {branded} source files, {changed} written')

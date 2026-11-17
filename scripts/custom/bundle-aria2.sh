#!/bin/bash
# Usage: bundle-aria2.sh APP
# Puts this Mac's aria2c (Homebrew's), with the Homebrew libraries it loads,
# inside the app at Contents/Resources/aria2, each signed ad hoc, so Smart
# Downloads works with no Homebrew on the Mac it runs on. Run by build.sh
# before the app is signed; nothing happens on a Mac without aria2.
set -euo pipefail
APP="$1"
SRC="${YAB_ARIA2_BIN:-$(command -v aria2c || true)}"
[ -n "$SRC" ] && [ -x "$SRC" ] || { echo "aria2: none on this Mac, Smart Downloads looks for Homebrew's (brew install aria2)" >&2; exit 0; }
exec /usr/bin/python3 -I - "$APP" "$SRC" <<'PY'
import os, shutil, subprocess, sys
from pathlib import Path
app, src = Path(sys.argv[1]), Path(os.path.realpath(sys.argv[2]))
dest = app / 'Contents/Resources/aria2'
if dest.exists():
    shutil.rmtree(dest)
(dest / 'lib').mkdir(parents=True)

def deps(binary):
    lines = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    return [line.strip().split(' (')[0] for line in lines]

def ours(path):
    return not (path.startswith('/usr/lib/') or path.startswith('/System/') or path.startswith('@'))

main = dest / 'aria2c'
shutil.copy2(src, main)
os.chmod(main, 0o755)
copied = {}
queue = [main]
while queue:
    target = queue.pop()
    for dep in deps(target):
        if not ours(dep):
            continue
        name = os.path.basename(dep)
        if name not in copied:
            out = dest / 'lib' / name
            shutil.copy2(os.path.realpath(dep), out)
            os.chmod(out, 0o755)
            copied[name] = out
            subprocess.run(['install_name_tool', '-id', '@loader_path/' + name, str(out)], check=True, stderr=subprocess.DEVNULL)
            queue.append(out)
        new = ('@loader_path/lib/' if target == main else '@loader_path/') + name
        subprocess.run(['install_name_tool', '-change', dep, new, str(target)], check=True, stderr=subprocess.DEVNULL)
for path in list(copied.values()) + [main]:
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, stderr=subprocess.DEVNULL)
subprocess.run([str(main), '--version'], check=True, stdout=subprocess.DEVNULL)
print('aria2: bundled, with ' + ', '.join(sorted(copied)))
PY

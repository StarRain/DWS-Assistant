"""Collect license/notice files for modules linked into the pinned Go helper."""
import json
import pathlib
import re
import shutil
import sys

source, destination = map(pathlib.Path, sys.argv[1:3])
text = source.read_text()
decoder = json.JSONDecoder()
modules = {}
while text.strip():
    obj, end = decoder.raw_decode(text.lstrip())
    text = text.lstrip()[end:]
    mod = obj.get('Module')
    if mod:
        real = mod.get('Replace', mod)
        directory = real.get('Dir') or mod.get('Dir')
        if directory:
            modules[mod['Path']] = (mod.get('Version', 'pinned source'), pathlib.Path(directory))
destination.mkdir(parents=True, exist_ok=True)
manifest = []
for name, (version, directory) in sorted(modules.items()):
    safe = re.sub(r'[^a-zA-Z0-9._-]', '_', name)
    files = [p for p in directory.iterdir() if p.is_file() and re.match(r'^(LICENSE|COPYING|NOTICE|COPYRIGHT)', p.name, re.I)]
    out = destination / safe
    out.mkdir(exist_ok=True)
    for path in files:
        target = out / path.name
        if target.exists():
            target.chmod(0o644)
        shutil.copyfile(path, target)
        target.chmod(0o644)
    manifest.append({'module': name, 'version': version, 'files': [p.name for p in files]})
(destination / 'modules.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
print(f'Collected license notices for {len(manifest)} linked Go modules')

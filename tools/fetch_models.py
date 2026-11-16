"""Download the exact 0.8.11 dependencies and verify every file before installing."""
import argparse, hashlib, json, shutil, tempfile, urllib.request, zipfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root/'models/manifest.json').read_text())
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def check():
    return all((root/x['path']).is_file() and sha(root/x['path']) == x['sha256'] for x in manifest['files'])
parser=argparse.ArgumentParser();parser.add_argument('--archive',type=Path);parser.add_argument('--check',action='store_true');args=parser.parse_args()
if args.check:
    if not check(): raise SystemExit('Model files missing or checksum mismatch')
    print('All model checksums verified');raise SystemExit(0)
if check(): print('Models already verified');raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='suki-models-') as work:
    bundle=args.archive
    if bundle is None:
        bundle=Path(work)/'models.zip'
        print('Downloading',manifest['url'],flush=True)
        with urllib.request.urlopen(manifest['url'],timeout=120) as response,bundle.open('wb') as output:
            shutil.copyfileobj(response,output)
    if sha(bundle)!=manifest['sha256']:raise SystemExit('Archive checksum mismatch')
    with zipfile.ZipFile(bundle) as z:
        # Fixed allow-list; never extract arbitrary paths from an archive.
        for entry in manifest['files']:
            rel=Path(entry['path'])
            if rel.is_absolute() or '..' in rel.parts:raise SystemExit('Unsafe manifest path')
            temp=Path(work)/'entry'
            with z.open(entry['path']) as source,temp.open('wb') as target:shutil.copyfileobj(source,target)
            if temp.stat().st_size!=entry['bytes'] or sha(temp)!=entry['sha256']:raise SystemExit('Model checksum mismatch: '+entry['path'])
            target=root/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(temp,target)
if not check():raise SystemExit('Final model verification failed')
print('All model checksums verified')

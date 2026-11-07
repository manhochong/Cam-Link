"""Compare one isolated camera test's JPGs against a Cam Link diagnostic report.

Uses SHA-256 + size multisets, never filenames or event counts as proof.
"""
import argparse
from collections import Counter
import csv
import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile

def load_report(path):
    path = Path(path)
    if path.is_dir():
        return (path / 'files.csv').read_text(encoding='utf-8-sig'), json.loads((path / 'summary.json').read_text(encoding='utf-8'))
    with zipfile.ZipFile(path) as z:
        return z.read('files.csv').decode('utf-8-sig'), json.loads(z.read('summary.json'))

def compare(report, card_directory, expected=None):
    text, summary = load_report(report)
    cards = sorted(p for p in Path(card_directory).rglob('*') if p.is_file() and p.suffix.lower() in ('.jpg', '.jpeg'))
    if not cards:
        raise ValueError('No card JPGs found; select only this test round, not an empty folder.')
    errors = []
    if expected is not None and len(cards) != expected:
        errors.append(f'Expected {expected} card JPGs, found {len(cards)}')
    camera = Counter()
    paths = {}
    for p in cards:
        digest = hashlib.sha256()
        with p.open('rb') as f:
            for block in iter(lambda: f.read(1024 * 1024), b''):
                digest.update(block)
        key = (digest.hexdigest(), p.stat().st_size)
        camera[key] += 1
        paths.setdefault(key, []).append(str(p.relative_to(card_directory)))
    received = Counter()
    handles = set()
    for row in csv.DictReader(io.StringIO(text)):
        if row['status'] != 'OK':
            continue
        if row['handle'] in handles:
            errors.append(f'Duplicate successful handle {row["handle"]}')
        handles.add(row['handle'])
        sha = row['sha256'].lower()
        if len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha):
            errors.append(f'Invalid SHA-256 for {row["handle"]}')
        size = int(row['actual_bytes'])
        if size <= 0 or int(row['expected_bytes']) != size:
            errors.append(f'Invalid byte count for {row["handle"]}')
        received[(sha, size)] += 1
    if not summary.get('clean_stop'):
        errors.append('Session did not stop cleanly')
    if summary.get('failed', 0) or summary.get('pending', 0) or summary.get('validating', 0):
        errors.append('Session has failed/pending/unvalidated objects')
    if summary.get('valid_jpg') != sum(received.values()):
        errors.append('Summary count does not match success manifest')
    missing, extra = camera - received, received - camera
    return {
        'result': 'PASS_BYTE_MATCH' if not missing and not extra and not errors else 'FAIL',
        'scope': 'Byte-for-byte identity and multiplicity for the supplied card selection only; shooting slowdown NOT measured',
        'card_jpg': len(cards), 'received_jpg': sum(received.values()),
        'missing_or_different': [{'sha256': k[0], 'bytes': k[1], 'count': v, 'card_paths': paths[k]} for k, v in missing.items()],
        'extra_or_different': [{'sha256': k[0], 'bytes': k[1], 'count': v} for k, v in extra.items()],
        'errors': errors,
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path, help='Exported ZIP or session directory')
    parser.add_argument('--card-directory', required=True, type=Path, help='Folder containing ONLY this test round JPGs')
    parser.add_argument('--expected-count', type=int)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    try:
        result = compare(args.report, args.card_directory, args.expected_count)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as e:
        print('ERROR:', e, file=sys.stderr)
        return 2
    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        args.out.write_text(text + '\n', encoding='utf-8')
    return 0 if result['result'] == 'PASS_BYTE_MATCH' else 1

if __name__ == '__main__':
    sys.exit(main())

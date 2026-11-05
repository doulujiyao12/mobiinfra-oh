"""Inspect existing ELF exports; does not build, install or run a model.

Use the SDK's llvm-nm with --nm. A pre-fix --write-baseline snapshot can later
be supplied with --baseline to ensure MNN's public inference API was retained.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess


def exports(nm, library):
    result = subprocess.run([str(nm), '-D', '--defined-only', str(library)],
                            check=True, capture_output=True, text=True, encoding='utf-8')
    return {line.split()[-1] for line in result.stdout.splitlines() if line.split()}


def public_mnn_api(symbols):
    return {name for name in symbols if name.startswith(('_ZN3MNN', '_ZNK3MNN', 'MNN'))}


def runtime_symbols(symbols, locale=False):
    return sorted(name for name in symbols if
                  name.startswith(('_Unwind_', '__unw_', 'unw_', '__cxa_')) or
                  name == '__gxx_personality_v0' or
                  (locale and ('St4__n16locale' in name or
                   re.match(r'^_ZNSt4__n1(?:5ctype|7codecvt).*2idE$', name))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nm', required=True, type=Path)
    parser.add_argument('--mnn', type=Path, default=Path('entry/libs/arm64-v8a/libMNN.so'))
    parser.add_argument('--entry', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--write-baseline', type=Path)
    args = parser.parse_args()
    mnn, entry = exports(args.nm, args.mnn), exports(args.nm, args.entry)
    api = public_mnn_api(mnn)
    if args.write_baseline:
        args.write_baseline.parent.mkdir(parents=True, exist_ok=True)
        args.write_baseline.write_text(json.dumps(sorted(api), indent=2) + '\n', encoding='utf-8')
        print('Saved MNN public API baseline:', len(api), 'symbols')
    failures = 0
    for label, symbols, check_locale in [('libMNN.so', mnn, True), ('libentry.so', entry, False)]:
        leaked = runtime_symbols(symbols, check_locale)
        print(label, 'runtime exports:', len(leaked))
        for name in leaked[:8]:
            print(' ', name)
        failures += bool(leaked)
    if not api:
        print('ERROR: MNN public API exports are missing')
        failures += 1
    if args.baseline:
        expected = set(json.loads(args.baseline.read_text('utf-8')))
        missing = sorted(expected - api)
        print('Missing public MNN API symbols:', len(missing))
        for name in missing[:8]:
            print(' ', name)
        failures += bool(missing)
    print('Native runtime export checks:', 'FAIL' if failures else 'PASS')
    raise SystemExit(1 if failures else 0)


if __name__ == '__main__':
    main()

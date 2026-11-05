"""Download official CPU models for RecordingPage. No builds, HDC or model execution.

Run: python scripts/prepare_recording_models.py
Then copy the five output files to the phone and use RecordingPage > Models > Import.
"""
import argparse
import hashlib
import json
import shutil
import tarfile
import urllib.request
from pathlib import Path

BASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
EXPECTED = {
    'tokens.txt': 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    'sensevoice.int8.onnx': 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
    'segmentation.int8.onnx': 'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d',
    'speaker.onnx': '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b',
    'silero_vad.onnx': '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def download(url, path):
    if path.exists():
        return
    print('Downloading', path.name, flush=True)
    temp = path.with_name(path.name + '.part')
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temp.open('wb') as output:
            shutil.copyfileobj(response, output, 1024 * 1024)
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def extract_named(archive, output, mapping):
    # Never extract archive paths: copy only allowlisted member basenames.
    with tarfile.open(archive, 'r:bz2') as tar:
        for source, target in mapping.items():
            matches = [m for m in tar.getmembers() if m.isfile() and Path(m.name).name == source]
            if len(matches) != 1:
                raise ValueError('Missing or ambiguous archive member: ' + source)
            with tar.extractfile(matches[0]) as incoming, (output / (target + '.part')).open('wb') as dest:
                shutil.copyfileobj(incoming, dest)
            (output / (target + '.part')).replace(output / target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.codex-tmp/recording-models'))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archives = output / 'downloads'
    archives.mkdir(exist_ok=True)
    plans = [
        ('asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
         {'model.int8.onnx': 'sensevoice.int8.onnx', 'tokens.txt': 'tokens.txt'}),
        ('speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
         {'model.int8.onnx': 'segmentation.int8.onnx'}),
    ]
    for source, mapping in plans:
        if all((output / target).exists() for target in mapping.values()):
            continue
        archive = archives / source.split('/')[-1]
        download(BASE + source, archive)
        extract_named(archive, output, mapping)
    for source, name in [
        ('speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx', 'speaker.onnx'),
        ('asr-models/silero_vad.onnx', 'silero_vad.onnx'),
    ]:
        download(BASE + source, output / name)
    manifest = {}
    for name in EXPECTED:
        path = output / name
        digest = sha256(path)
        if name in EXPECTED and digest != EXPECTED[name]:
            raise ValueError('SHA-256 mismatch: ' + name + '; remove this file and retry')
        if name == 'tokens.txt':
            tokens = path.read_text(encoding='utf-8')
            if not tokens.startswith('<unk> 0\n') or len(tokens.splitlines()) != 25055:
                raise ValueError('SenseVoice token file does not match')
        manifest[name] = {'bytes': path.stat().st_size, 'sha256': digest}
        print(name, path.stat().st_size, digest, flush=True)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('Ready:', output, '\nCopy the five model/token files to the phone and import them in Recording Analysis.')


if __name__ == '__main__':
    main()

"""Host WebRTC reference only; no Python code is shipped to the watch."""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / '.codex-tmp' / 'watch-tests' / 'vad-reference'))
try:
    import webrtcvad
except ImportError:
    sys.exit(77)

rate = int(sys.argv[1])
data = sys.stdin.buffer.read()
frame_bytes = rate // 50 * 2
detector = webrtcvad.Vad(2)
print(json.dumps([
    detector.is_speech(data[i:i + frame_bytes], rate)
    for i in range(0, len(data) - frame_bytes + 1, frame_bytes)
]))

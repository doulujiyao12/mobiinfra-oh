# Test audio

`webrtc-speech-8k.pcm` is the unmodified `test-audio.raw` from
https://github.com/wiseman/py-webrtcvad/blob/e283ca41df3a84b0e87fb1f5cb9b21580a286b09/test-audio.raw
(8 kHz, mono, 16-bit little-endian PCM).

Its upstream license is retained in
`watch_entry/src/main/cpp/third_party/WebRTC-LICENSE.txt`. The sample is used only by
host tests and is never included in the HAP. Test upsampling uses sample
repetition for reproducible classifier input, not production audio resampling.

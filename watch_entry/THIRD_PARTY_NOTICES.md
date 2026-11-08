# Third-party software

The optional speech recording mode uses the WebRTC VAD, vendored from
https://github.com/wiseman/py-webrtcvad at commit
`e283ca41df3a84b0e87fb1f5cb9b21580a286b09` (the `cbits/webrtc` subtree).
No Python runtime or Python wrapper is shipped. The upstream DSP sources are
unchanged except for a null-allocation check in `WebRtcVad_Create`;
`voicevad.cpp` is the app's HarmonyOS Node-API binding.

WebRTC code is under the BSD 3-Clause license. The complete upstream license,
including the py-webrtcvad MIT notice, is retained at
`watch_entry/src/main/cpp/third_party/WebRTC-LICENSE.txt` and distributed in the HAP
at `resources/rawfile/third_party/WebRTC-LICENSE.txt`.

The test speech fixture, where present, comes from the same upstream repository
and is used only by host tests. It is not packaged into the application.

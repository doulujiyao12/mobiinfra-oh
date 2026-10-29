ClawMate Codex 1.1.15

- Fix macOS local control socket startup when the canonical temporary directory exceeds the Unix socket path limit. Select a short private endpoint before binding and report control-channel failures with their original error code.
- Retain per-user private directories, socket permissions and token authentication. Existing projects, sessions and phone pairing are preserved.
- Release Windows, Linux and both macOS architectures with the same connector version.
- Simplify the phone's macOS installation guide to the application-folder step and two terminal commands.

Previous release: 1.1.14

- Fix macOS portable app startup: brand the executable and resolve installed runtimes from the actual bundle instead of relying only on Electron's executable-name heuristic.
- Show existing local Codex projects and recent CLI/editor session directories before browsing for another folder. Supports search, clear individual choices and explicit authorization on save.
- Discover projects read-only, honor CODEX_HOME, and filter unavailable paths and credential-containing roots. No conversations or credentials are read.
- Initialize the update service before loading the desktop page to avoid an initial IPC race.
- Add Intel macOS packaging alongside Apple Silicon. macOS archives remain unsigned and unnotarized; native macOS startup must be verified on a Mac.

Previous release: 1.1.13

- Automatic GitHub Release checks, with stable and preview channels.
- Download progress, pause/resume, SHA256 validation and cached downloads.
- Windows: restart and install in the existing directory after active tasks finish.
- Linux desktop/CLI: staged replacement, preflight version check, rollback on replacement failure, and connection-service restoration.
- macOS: detect and download the current unsigned app, then open it for manual installation.
- Existing phone pairing, workspace permissions and conversation data are retained.
- Includes the 1.1.12 fix for moved-workspace and explicitly authorized projectless sessions.

Install this version once manually to enable updates for future releases. macOS packages remain unsigned/unnotarized unless built with production signing credentials. The updater only accepts matching connector Release assets with a published SHA256 digest or SHA256SUMS entry. Updating does not modify the official Codex desktop installation.

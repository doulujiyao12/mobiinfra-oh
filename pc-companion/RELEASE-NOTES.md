ClawMate Codex 1.1.13

- Automatic GitHub Release checks, with stable and preview channels.
- Download progress, pause/resume, SHA256 validation and cached downloads.
- Windows: restart and install in the existing directory after active tasks finish.
- Linux desktop/CLI: staged replacement, preflight version check, rollback on replacement failure, and connection-service restoration.
- macOS: detect and download the current unsigned app, then open it for manual installation.
- Existing phone pairing, workspace permissions and conversation data are retained.
- Includes the 1.1.12 fix for moved-workspace and explicitly authorized projectless sessions.

Install this version once manually to enable updates for future releases. macOS packages remain unsigned/unnotarized unless built with production signing credentials. The updater only accepts matching connector Release assets with a published SHA256 digest or SHA256SUMS entry. Updating does not modify the official Codex desktop installation.

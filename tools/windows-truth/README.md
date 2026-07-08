# windows-truth

The Windows live-truth loop: drives the toolkit's showcase apps on a real Windows 11 desktop over ssh, capturing what the OS actually does — window styles, min-size floors, input, clipboard, packaging — instead of trusting the null platform.

Prerequisites: the repo cloned at `%USERPROFILE%\repo` on the box, Zig 0.16 on PATH, the desktop logged in and UNLOCKED, and an ssh alias (key auth) whose default shell is cmd.exe. Anything that must touch the visible desktop hops through a `schtasks /IT` one-shot task; artifacts land in `%TEMP%\native-truth-out\`.

One command runs everything, or one named step:

```powershell
powershell -NoProfile -File tools\windows-truth\run-all.ps1 [recon|drive|effects|record|writeback|package|all]
```

Steps: `recon.ps1` builds and launches every showcase app, dumping snapshots, widget inventories, and screenshots; `drive.ps1` replays per-app interaction scenarios (clicks, text input, wheel, resize); `effects-run.ps1` probes spawn streaming, cancel, and clipboard; `record-replay.ps1` records a session and replays it headlessly with verification; `writeback-run.ps1` exercises markup write-back plus hot reload; `package-launch.ps1` launches and drives a packaged artifact. `window-probe.ps1` is the ad-hoc OS-window probe, and `lib.ps1` holds the shared helpers.

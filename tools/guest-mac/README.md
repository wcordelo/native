# guest-mac

An in-repo macOS guest VM host, built on Apple's Virtualization.framework — no third-party VM software. Agents run their live-GUI phases inside guests instead of on the desktop; the windowed host app is itself a Native SDK app, so the chrome around the live guest display is the framework dogfooding its own native-surface channel.

Two faces, one binary:

- **`guest-mac [--name VM]`** (no verb) — the windowed app: VM state, Start/Stop/Force Stop, install progress, and the live guest display (a `VZVirtualMachineView` adopted into the declared shell scene via `Runtime.adoptViewSurface`). The display view captures pointer and keyboard into the guest when focused. A **Help** button opens the provisioning guide in its own window (a model-declared secondary window: open while the flag is set, closing it hands the flag back). The window drives one named VM chosen at launch; an in-app VM switcher is deferred — relaunch with a different `--name`.
- **`guest-mac fetch|install|clone|start|stop|status|ip`** — headless verbs for agents and scripts. See `agents.md` for the agent workflow.

## Named guests

Every verb addresses a named VM with `--name` (default `default`). Bundles live at `~/.native/guest-mac/vms/<name>/`; the IPSW cache is shared by all of them. A pre-multi-VM layout (a single bundle at `~/.native/guest-mac/vm/`) is migrated to `vms/default` automatically on first run — a rename, never a copy, and never while that guest is running (migration defers and `default` keeps resolving to the old path until it stops).

`guest-mac clone <src> <dst>` copies a **stopped**, provisioned guest as an APFS copy-on-write clone (instant, shares disk blocks until written) with a **fresh machine identifier and MAC address** — the unique identity that makes the host's DHCP server give each guest its own IP. Everything provisioned inside the guest (user account, SSH keys, sudoers, developer tools) rides along on the disk, so one carefully provisioned guest becomes a fleet without re-running Setup Assistant.

**Concurrency cap:** Apple's macOS license terms permit two macOS guests running concurrently per host. `start` counts running guests (live owner pids in their state files) and refuses a third, naming the running VMs. Defaults are sized for that world: new installs and clones get 6 GB of guest memory so two guests coexist with host builds on a 32 GB machine — give a single dedicated guest more with `--memory-gb 8`.

## Build

```sh
cd tools/guest-mac
zig build            # builds AND ad-hoc codesigns with entitlements.plist
zig build run        # the windowed app
zig build test       # CLI parsing, paths/migration, clone identity, cap census,
                     # lease matching, scene + help-window dispatch (no VM)
```

Every process that touches Virtualization.framework needs the `com.apple.security.virtualization` entitlement — even the restore-image catalog fetch fails without it. The build signs the emitted binary in place (`codesign --force --sign -` with `entitlements.plist`), so `zig build run`, the installed binary, and anything that copies it stay signed. Requirements: Apple silicon, macOS 13+.

## First-time setup

1. `guest-mac fetch` — downloads the latest supported macOS IPSW (~15 GB) to `~/Library/Caches/native-sdk/guest-mac/` (shared by every VM).
2. `guest-mac install` — creates the VM bundle at `~/.native/guest-mac/vms/default/` (defaults: 4 CPUs, 6 GB RAM, 90 GB sparse disk; override with `--cpus/--memory-gb/--disk-gb`, and `--name` for a different VM) and restores macOS onto it. The windowed app runs both steps automatically if you skip them.
3. Run the windowed app and **click through Setup Assistant in the display area** — the one genuinely manual step. Create the user account you want agents to SSH as.
4. Follow the Help window's checklist: enable Remote Login, grant Screen Recording, then run `provision.sh` inside the guest. The script lives in the repo, and the repo rides into the guest as a virtio-fs device tagged `repo` — bootstrap the first mount by hand in the guest's Terminal:

   ```sh
   mkdir -p /Volumes/repo
   sudo mount_virtiofs repo /Volumes/repo
   /Volumes/repo/tools/guest-mac/provision.sh
   ```

   The script installs a boot-time remount daemon (so this is the only manual mount), enables what it can, installs the pinned Zig, and disables sleep.
5. Want more guests? `guest-mac clone default <name>` — the clone inherits all of the above.

After that, agents drive everything headless (`agents.md`).

## How the pieces fit

- `src/vm_host.m` — the engine: Virtualization.framework behind a C ABI in the house `appkit_host.m` style (restore-image fetch, `VZMacOSInstaller`, `VZMacPlatformConfiguration` with persistent machine identifier/aux storage, NAT network with a persistent MAC, virtio-fs share, entropy/balloon/keyboard/trackpad/graphics devices, start/stop with delegate callbacks). Everything runs on the main queue; events funnel through one callback. Also home to the standalone fresh-machine-identifier writer `clone` uses.
- `src/vm.zig` — Zig bindings plus the `Events` accumulator both faces poll, the named-VM path layout and legacy migration, the running-VM census behind the two-guest cap, and the copy-on-write file clone.
- `src/cli.zig` — verb/flag parsing (`--name` everywhere, `clone` positionals), DHCP-lease matching, state-file parsing, and the clone-identity helpers (fresh MAC generation, config rewrite) — all pure, all tested.
- `src/ui.zig` — the Native SDK app. The guest display is a plain `stack` container in the shell scene; once the engine configures the VM, its `VZVirtualMachineView` is adopted into that container through the platform's native-surface adoption channel. The Help window rides the runtime's model-declared window channel (presence-is-visibility from a model flag; a user close arrives as `.window_closed`).
- `src/main.zig` — entry point and headless verb execution. `stop`/`status`/`ip` are pure file/signal verbs (state file + `/var/db/dhcpd_leases`); `fetch`/`install`/`start` drive the engine; `clone` is file verbs plus the identity call; the legacy migration runs once, up front.

This is dev tooling: it registers no example test suites and its `zig build test` covers what is testable without a VM.

## Uninstall

```sh
rm -rf ~/.native/guest-mac \
       ~/Library/Application\ Support/native-sdk/guest-mac \
       ~/Library/Caches/native-sdk/guest-mac
```

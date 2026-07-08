# guest-mac for agents

You are an agent whose live-GUI phase must not fight over the desktop of the host Mac. Run those phases inside a guest VM this tool manages: each guest has its own display, its own window server, and the repo mounted over virtio-fs. Everything below is headless; the windowed app exists for the human provisioning pass.

Guests are **named**. Every verb takes `--name VM` (default `default`); bundles live at `~/.native/guest-mac/vms/<name>/`. A provisioned guest clones in milliseconds (`clone`), and **at most two guests run concurrently** — Apple's macOS license terms permit two virtualized macOS instances per host, and `start` enforces it.

## Prerequisites (once per machine, mostly human)

1. `cd tools/guest-mac && zig build` — builds and ad-hoc signs `zig-out/bin/guest-mac` with the virtualization entitlement (nothing in Virtualization.framework works unsigned).
2. `./zig-out/bin/guest-mac fetch` — resolves and downloads the latest supported macOS IPSW (~15 GB, resumable; cached under `~/Library/Caches/native-sdk/guest-mac/`, shared by every VM). Skip if already cached.
3. `./zig-out/bin/guest-mac install` — creates the `default` VM bundle (90 GB sparse disk, aux storage, persistent machine identifier and MAC address) and restores macOS onto it. Takes a while; prints progress.
4. **Human step**: run the windowed app (`zig build run`) and click through Setup Assistant in the display area, then follow the in-app Help window (Remote Login on, Screen Recording granted to sshd-child, `provision.sh` run inside the guest). See README.md.

If `guest-mac status --name default` reports `bundle: installed` and you can SSH in, provisioning already happened — start at the workflow below.

## Growing a fleet: clone

```sh
# Source must be STOPPED. Copy-on-write: instant, near-zero disk until
# either side writes. The clone gets a FRESH machine identifier and MAC
# (its own DHCP lease/IP) and keeps everything provisioned inside:
# user account, SSH keys, sudoers, CLT, zig, the remount daemon.
./zig-out/bin/guest-mac clone default build-bot
./zig-out/bin/guest-mac start --name build-bot &
```

Clones default to 6 GB of guest memory so two guests coexist with host builds on a 32 GB host (`--memory-gb 8` for a single dedicated guest). Delete a VM by deleting its bundle dir.

## Per-session workflow

```sh
cd tools/guest-mac
VM=default                              # or your clone's name

# 1. Boot the guest headless. The process stays in the foreground for the
#    guest's lifetime — run it in the background and keep the pid.
./zig-out/bin/guest-mac start --name "$VM" &   # add --share DIR to mount
                                               # something other than the
                                               # enclosing repo root

# 2. Wait for the guest's DHCP lease and capture the address.
GUEST_IP=$(./zig-out/bin/guest-mac ip --name "$VM" --wait 120)

# 3. SSH in (the account is whatever was created in Setup Assistant).
ssh "$GUEST_USER@$GUEST_IP"

# 4. Inside the guest: the repo share is a virtio-fs device tagged "repo",
#    mounted at /Volumes/repo by the provisioned remount daemon. The share
#    is READ-ONLY in the guest — build caches and zig-out must live on the
#    guest disk:
export ZIG_LOCAL_CACHE_DIR=$HOME/zig-cache
cd /Volumes/repo && zig build test

# 5. When the live phase is done, shut the guest down gracefully.
./zig-out/bin/guest-mac stop --name "$VM"      # SIGTERM to the owner
```

## The two-guest concurrency cap

Apple's macOS license permits **two** macOS guests running concurrently per host. `start` counts running guests (live owner pids across `vms/*/state.json`) and refuses a third with a message naming the cap and the running VMs:

```
guest-mac: two macOS guests are already running — Apple's macOS license permits 2
concurrent guests per host: build-bot (pid 57421) default (pid 16256).
Stop one first: guest-mac stop --name <vm>
```

Plan phases accordingly: prefer sharing a running guest (below) over queueing on a third boot.

## Sharing one guest between parallel agents

Two kinds of automation, two rules:

- **App-scoped (semantic) phases are safe to run concurrently** in one guest: `zig build`, launching apps, snapshots, widget verbs (`widget-click`, `widget-type`, ...), and engine screenshots all address a specific app's automation channel — they do not touch the shared pointer, keyboard, or full desktop.
- **Real-input phases are exclusive per guest**: CGEvent pointer/keyboard gestures and full-desktop captures own the guest's one seat. Take the input lock first, hold it for the whole gesture sequence, release it promptly.

Lock convention — an mkdir lock (atomic on every filesystem) at a fixed path in the guest, holding pid + timestamp, with a stale-lock takeover after 120 s:

```sh
# Acquire (run INSIDE the guest, e.g. over ssh) — waits up to ~120s.
acquire_input_lock() {
  local lock=/tmp/guest-input.lock deadline=$((SECONDS + 120))
  while ! mkdir "$lock" 2>/dev/null; do
    # Stale? Owner dead or lock older than 120s -> take it over.
    local owner; owner=$(cat "$lock/pid" 2>/dev/null || echo 0)
    if ! kill -0 "$owner" 2>/dev/null; then rm -rf "$lock"; continue; fi
    [ $SECONDS -ge $deadline ] && return 1
    sleep 2
  done
  echo $$ > "$lock/pid"; date +%s > "$lock/at"
}

release_input_lock() { rm -rf /tmp/guest-input.lock; }

# Usage over ssh, wrapping ONLY the real-input phase:
ssh "$GUEST_USER@$GUEST_IP" "$(typeset -f acquire_input_lock); acquire_input_lock" \
  || { echo "guest input seat busy"; exit 1; }
ssh "$GUEST_USER@$GUEST_IP" 'native automate ... # gestures / full-desktop capture'
ssh "$GUEST_USER@$GUEST_IP" 'rm -rf /tmp/guest-input.lock'
```

If `flock` fits your shape better (single ssh session holding the lock for its lifetime), the equivalent is `ssh ... 'exec 9>/tmp/guest-input.lockfile; flock -w 120 9; <gestures>'` — the lock dies with the session, so crashes cannot wedge the seat. Either way: one lock per guest, wrap only the real-input phase, never hold it across a build.

## Notes on honesty and mechanics

- `start` refuses to double-boot a VM: if a live instance owns the bundle (state file + alive pid) it fails loudly. `status --name VM` shows who owns it.
- `ip` works by matching the bundle's persistent MAC address against `/var/db/dhcpd_leases` — the file macOS's NAT DHCP server maintains. No agent inside the guest, no bonjour guesswork. The lease appears once the guest's network stack is up (tens of seconds after boot; longer on first boot). Clones have their own MAC, so each guest resolves to its own IP.
- `start` prints `running ip=<addr>` on stdout once the lease appears, so you can also capture it from the start process's output.
- Two SIGTERMs (or `stop` twice) escalate to a force stop; `stop --force` SIGKILLs the owner process (the VM dies with it). Prefer graceful.
- `clone` refuses a running source (a live disk image would clone torn) and an existing destination. Stop, clone, restart.
- Live-GUI tests that capture the screen need the Screen Recording grant from provisioning; SSH sessions drive the GUI via the normal automation entry points (`zig build test-*-smoke`, `native automate`, ...) exactly as on the host.
- The share is read-only in the guest: the guest reads the repo and builds into its own disk. Set `ZIG_LOCAL_CACHE_DIR` (and build `zig-out` targets on the guest disk) before building from the share — virtio-fs is correct but not fast for heavy `.zig-cache` traffic anyway.

## Files this tool owns

| Path | What |
| --- | --- |
| `~/.native/guest-mac/vms/<name>/` | one VM bundle per name: `Disk.img`, `AuxiliaryStorage`, `HardwareModel`, `MachineIdentifier`, `config.json` (persistent MAC, sizing), `state.json` (live state + owner pid) |
| `~/.native/guest-mac/vm/` | the pre-multi-VM bundle location; migrated to `vms/default` on first run (deferred while that guest is running) |
| `~/Library/Caches/native-sdk/guest-mac/` | downloaded IPSWs (shared by all VMs) |

Delete a bundle directory to remove that guest entirely (re-install or re-clone after).

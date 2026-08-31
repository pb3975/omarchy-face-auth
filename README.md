# Face Auth

Windows-Hello-style IR face authentication for [Omarchy](https://omarchy.org), covering `sudo`, polkit, and the lock screen. Backed by [howdy-next](https://aur.archlinux.org/packages/howdy-next) (an opencv/dlib face matcher, PAM module) pointed at an IR camera instead of your regular webcam.

**Hardware requirement:** a UVC IR camera — a capture node that offers *only* greyscale video (`GREY`/`Y8`/`Y16`/...), no color format. Plain RGB webcams are deliberately not supported: a face unlocked by a printed photo isn't security, it's theater. Detection is handled by `omarchy-hw-ir-camera`, which probes `/dev/video*` for a node that is greyscale-only, rather than trying to guess by vendor or card name.

If your laptop doesn't have a Windows-Hello-shaped IR sensor next to its webcam, this plugin has nothing to offer you.

## Status

Personal project, shaped to plausibly upstream into Omarchy someday (see `SPEC.md`) but shipped here as a standalone plugin in the meantime. Developed and tested on exactly one machine (see [Hardware notes](#hardware-notes)). Expect rough edges on hardware other than that one.

## What this actually is

Two independent halves, install-wise:

**1. An Omarchy shell plugin** (this repo's root — `manifest.json`, `Service.qml`, `LockView.qml`) that adds face auth to the lock screen. It's registered with `"omarchy": {"clonedFrom": "omarchy.lock"}`, which means enabling it *supersedes* Omarchy's built-in lock plugin rather than running alongside it — the stock lock auto-disables when this one is enabled, and re-enabling the stock plugin (or disabling this one) restores it. Nothing about the plugin registration touches PAM, howdy, or hardware; it only changes what draws your lock screen and which PAM services it drives.

**2. Plain CLI scripts in `scripts/`** that the Omarchy plugin system never executes on its own — `omarchy-hw-ir-camera`, `omarchy-setup-security-face`, `omarchy-remove-security-face`. Adding or enabling the plugin does not run these. You have to consciously run `scripts/install.sh`, which installs root-owned copies into Omarchy's command directory and `/usr/bin` so `omarchy setup security face` and `omarchy remove security face` become real, discoverable `omarchy` subcommands (the same mechanism `omarchy-setup-security-fingerprint` uses). Nothing is enrolled, no AUR package is built, and no PAM file is touched by `install.sh` itself.

Put plainly, for reviewers: **adding this plugin installs nothing and changes no system file.** Every consequential step — building howdy-next, touching `/etc/pam.d/*`, enrolling a face — happens only when you explicitly run `scripts/install.sh` followed by `omarchy setup security face`.

Once configured, the lock screen runs a short burst of **3 face-match attempts** as soon as the lock appears, then lets the camera rest — it does not sit there endlessly polling your face like the fingerprint reader does. It wakes back up for another burst whenever the display wakes or you interact with the lock screen (typing, clicking, moving the mouse after a blank). Fingerprint, if you also have `security fingerprint` set up, keeps working the entire time, independently — this plugin only adds a parallel path, it doesn't touch the fingerprint one.

## Install

```
omarchy plugin add https://github.com/pb3975/omarchy-face-auth   # placeholder URL
bash scripts/install.sh
omarchy setup security face
omarchy plugin enable io.github.pb3975.face-auth
```

What each step does:

1. **`omarchy plugin add <url>`** — clones this repo into `~/.config/omarchy/plugins/io.github.pb3975.face-auth/`. This alone does not enable it or run anything.
2. **`bash scripts/install.sh`** — installs the three scripts as root-owned `0755` files in Omarchy's command directory and `/usr/bin` (`sudo install`, one prompt), so `omarchy setup security face` / `omarchy remove security face` exist as commands. They are copies rather than links into the user-writable checkout; after updating or editing the checkout, rerun `install.sh` to install the new command bytes. The installer also checks `~/.config/omarchy/plugins/io.github.pb3975.face-auth`: if `omarchy plugin add` already made that a real directory, it's left alone; if it doesn't exist yet, `install.sh` symlinks the checkout in itself as a dev-style shortcut. Either way, still no PAM edits, no AUR build, no enrollment.
3. **`omarchy setup security face`** — the interactive part. Requires sudo. In order: installs `v4l-utils` if missing, runs `omarchy-hw-ir-camera` and bails with an error if no IR camera is found, builds `howdy-next` from the AUR (`omarchy pkg aur add howdy-next` — this compiles, takes a few minutes), points Howdy's `device_path` at the detected IR node in `/etc/howdy/config.ini`, then walks you through `sudo howdy add` (enrollment: look at the camera, hold still) and `sudo howdy test` (verification). **Only if both succeed** does it write PAM config — see [What gets touched](#what-gets-touched) below. A failed enrollment or verification leaves the system exactly as it was; no PAM file is written.
4. **`omarchy plugin enable io.github.pb3975.face-auth`** — switches the lock screen from Omarchy's stock lock plugin to this one, which is the copy that knows how to drive the face PAM service. `sudo` and polkit face auth work as soon as step 3 finishes; the lock screen only gets it once this step runs.

### What gets touched

`omarchy setup security face` edits or creates, in this order, and only after enrollment + verification both pass:

- `/etc/howdy/config.ini` — `device_path` under `[video]` rewritten to point at the detected IR node (not appended; safe to re-run after a replug that renumbers `/dev/video*`).
- `/etc/pam.d/sudo` — inserts a clamshell gate (`pam_exec.so ... omarchy-hw-laptop-closed`) directly above a new `auth sufficient pam_howdy.so` line at the top of the file.
- `/etc/pam.d/polkit-1` — same two lines; the file is created from scratch if it doesn't already exist.
- `/etc/pam.d/omarchy-lock-face` — a new file, the PAM service the lock screen's face path drives. Its mere existence is what the lock plugin polls to decide whether to show the face indicator and start scanning; deleting it (which removal does) turns face auth off there immediately, no shell restart needed.

All three PAM edits are idempotent (`grep -q` before `sed -i`) and use `sufficient`, never `requisite` — see [Security](#security).

## Removal

```
omarchy remove security face
scripts/uninstall.sh
omarchy plugin remove io.github.pb3975.face-auth
```

1. **`omarchy remove security face`** — strips every `pam_howdy.so` line (and the clamshell gate directly above it, but *not* one that belongs to fingerprint in the same file) from `/etc/pam.d/sudo` and `/etc/pam.d/polkit-1`, deletes `/etc/pam.d/omarchy-lock-face`, and drops the `howdy-next` package. **Enrolled face models under `/etc/howdy` are left on disk** — this mirrors how `omarchy remove security fingerprint` leaves enrolled prints behind in `/var/lib/fprint` rather than wiping them as a side effect of unwiring PAM. Run `sudo howdy clear` yourself if you actually want the face data gone.
2. **`scripts/uninstall.sh`** — reverses `install.sh`: removes each root-owned command copy only if it still matches the source in this checkout (and also cleans up symlinks made by older versions), then unlinks the plugin directory only if it is a symlink pointing here. A real plugin directory from `omarchy plugin add` is left for `omarchy plugin remove` to handle. If PAM is still wired to `pam_howdy.so` at this point, it warns loudly and tells you to run `omarchy remove security face` first, but doesn't refuse to continue — unwiring authentication is treated as a decision that command makes, not something `uninstall.sh` does as a side effect.
3. **`omarchy plugin remove io.github.pb3975.face-auth`** — normal Omarchy plugin removal, drops the clone (or, if you never ran `omarchy plugin add` and only ever used the `install.sh` symlink shortcut, this step doesn't apply — `uninstall.sh` already removed the symlink).

Do these roughly in this order. Running `uninstall.sh` while `pam_howdy.so` is still in `/etc/pam.d/sudo` won't lock you out of anything (it's `sufficient`, password still works, and the commands stay in place until you actually remove the installed copies) but it does leave a dangling reference to a PAM module whose config file is now gone, which is worth cleaning up rather than leaving.

## Security

Read this before you decide how much to trust it.

- **Howdy-class matching is meaningfully weaker than Windows Hello.** There's no fused depth sensor doing the actual anti-spoof work — Windows Hello's IR + depth combo is a materially different hardware capability than a bare IR camera. The community track record on Howdy/howdy-next includes successful photo and video spoofing on some setups. Treat face auth here as a convenience, not as hardening.
- Every PAM line this adds is `sufficient`, never `requisite` or `required`. A face match is accepted as *enough* to authenticate, but your password is never disabled or bypassed as a fallback — it's wired to always still work if the camera fails, doesn't recognize you, or isn't configured at all. This is the same posture Omarchy's fingerprint and fido2 setup scripts already take; face auth doesn't tighten or loosen it.
- The clamshell gate (`omarchy-hw-laptop-closed`) sits ahead of `pam_howdy.so` everywhere it's wired in, so a closed lid skips straight to password instead of burning Howdy's capture timeout against a black frame.
- **This does not unlock Bitwarden, or any other password-manager vault.** Face auth here is local OS authentication only — `sudo`, polkit, the lock screen. Bitwarden's Linux client has no PAM-mediated unlock path; it's master-password (optionally + TOTP/FIDO2 inside Bitwarden itself) regardless of what's configured here. Don't expect a face scan to open your vault — it never will, by design and by the limits of what Bitwarden exposes.

## Maintenance

*(This section is for whoever's actually maintaining this repo — currently just me.)*

### The lock plugin is a patch, not an original

`Service.qml` and `LockView.qml` at the repo root aren't written from scratch — they're Omarchy's own lock plugin (`$OMARCHY_PATH/shell/plugins/lock/`) with `patches/face-lock.patch` applied on top, adding the `facePam`/`faceConfigured` path alongside the existing `fingerprintPam` one. `patches/UPSTREAM_SHA256` records the checksums of the exact upstream files the patch was built against.

When Omarchy ships an update that touches its own lock plugin, this repo's copy silently falls behind — there's no build step that would fail and tell you. Run:

```
scripts/resync.sh
```

It checks the recorded checksums against `$OMARCHY_PATH/shell/plugins/lock/{Service,LockView}.qml` (default `$OMARCHY_PATH=/usr/share/omarchy`). If nothing's changed upstream, it's a no-op. If something has, it backs up the current repo copies, copies in the new upstream files, and re-applies `patches/face-lock.patch` with `git apply`. Two outcomes:

- **Patch applies cleanly** → checksums are updated, and it prints a warning that "applies cleanly" is not the same as "still correct": read the diff, then unlock the screen once by face and once by password before trusting it. A lock screen that fails both ways means a reboot, not a bug report.
- **Patch doesn't apply** → the repo is restored to exactly what it had before the script ran, and it prints the manual merge steps (copy upstream in, `patch -p1`, resolve the `.rej` files by hand, regenerate the patch with `git diff`).

Either way, run `omarchy-restart-shell` afterward — see below for why.

### Symlinked plugin dir means no hot reload

If you're running the dev-shortcut install path (`install.sh`'s symlink into `~/.config/omarchy/plugins/`, not a real `omarchy plugin add` clone), the shell's file watcher (`inotifywait -m -r`) doesn't descend into symlinks. Editing `Service.qml` or `LockView.qml` won't be picked up live the way editing a real plugin checkout would be. Run `omarchy-restart-shell` after every edit you want to see.

### Repo layout

```
manifest.json                        plugin manifest (clonedFrom: omarchy.lock)
Service.qml, LockView.qml            patched lock plugin (see Maintenance above)
patches/face-lock.patch              the diff that produces the two files above
patches/UPSTREAM_SHA256              checksums of the upstream files the patch targets
scripts/install.sh                   installs CLI commands + (maybe) links the plugin dir
scripts/uninstall.sh                 reverses install.sh
scripts/resync.sh                    rebuilds the patched QML after an Omarchy update
scripts/omarchy-hw-ir-camera         hardware probe (hidden from menus, omarchy:hidden)
scripts/omarchy-setup-security-face  omarchy setup security face
scripts/omarchy-remove-security-face omarchy remove security face
SPEC.md                              design notes / rationale this was built from
```

## Hardware notes

Developed and tested on one machine: **ASUS ROG Zephyrus G14 2024 (GA402)**. Its IR node presents as `GREY` at 640x360@15fps, with the IR emitter strobing on alternating frames rather than staying lit continuously — every other captured frame comes back dark. `howdy-next`'s `dark_threshold` setting is what makes it tolerate that; nothing in this repo does extra frame filtering of its own.

On this machine the IR emitter fires without any extra configuration. If yours doesn't — camera detects fine, `omarchy-hw-ir-camera` passes, but frames come back permanently dark or the emitter never lights up — that's a firmware/ACPI quirk on some laptops, and the community tool for it is [`linux-enable-ir-emitter`](https://aur.archlinux.org/packages/linux-enable-ir-emitter) (AUR). It is not integrated into this plugin; you'd need to configure it yourself, separately, before `omarchy setup security face` will have a usable image to enroll against.

Other laptops with IR cameras are untested. The detection logic (`scripts/omarchy-hw-ir-camera`) matches on "capture node offering only greyscale formats," not on this laptop's vendor strings, specifically so it isn't overfit to one webcam — but the greyscale-second-node-next-to-RGB pairing itself hasn't been verified against other hardware.

## Troubleshooting

**Is the camera detected at all?**
```
omarchy-hw-ir-camera; echo $?
```
`0` and a `/dev/v4l/by-path/...` (or `/dev/videoN`) path means it found a greyscale-only node. `1` and no output means it didn't — check `v4l2-ctl --list-devices` and confirm your IR node really is greyscale-only and not just guessed at.

**Is face matching actually working?**
```
sudo howdy test
```
Re-runs verification against your enrolled model without touching PAM or re-enrolling. Good first step if the lock screen or sudo stops recognizing you.

**Is PAM actually wired up?**
```
grep pam_howdy /etc/pam.d/sudo /etc/pam.d/polkit-1
cat /etc/pam.d/omarchy-lock-face
```
The first should show a `sufficient pam_howdy.so` line (with a clamshell gate line above it) in both files if setup completed. The second should exist at all — its presence is literally what the lock plugin polls to decide whether face auth is configured.

**Lock screen isn't picking up a config change.** It rechecks `omarchy-lock-face` (and the fingerprint equivalent) on every new lock, so the next time you lock it should just reflect reality. To check without actually locking the session:
```
omarchy-shell lock preview
```

## License

MIT — see `LICENSE`. Copyright (c) 2026 Will Metz.

# Omarchy Face Authentication — Spec

## Problem

This machine (2024 ASUS Zephyrus G14, 2024 GA402 series) has no fingerprint
reader, so `omarchy setup security fingerprint` is a dead end. It does have a
Windows-Hello-shaped IR camera sitting next to the RGB webcam:

```
/dev/video0, /dev/video1  USB2.0 FHD UVC WebCam: USB2.0 F   MJPG / YUYV   (RGB)
/dev/video2, /dev/video3  USB2.0 FHD UVC WebCam: USB2.0 I   GREY          (IR)
```

Omarchy today only ships two biometric/possession factors — `security
fingerprint` (pam_fprintd) and `security fido2` (pam_u2f). There is no `face`
option. This spec defines one, built to match the shape of the existing two
so it could plausibly be upstreamed, but usable as a personal plugin either
way.

## Goals

- `omarchy setup security face` enrolls a face via the IR camera and wires it
  into **sudo** and **polkit**, the same as fingerprint/fido2 do today.
- Extend face auth to the **lock screen** (Omarchy's own Quickshell lock, not
  raw hyprlock).
- `omarchy remove security face` fully reverses the above.
- Hardware detection (`omarchy-hw-ir-camera` or similar) that gates setup the
  same way `omarchy-hw-fingerprint` does, so the invite/first-run hook only
  fires on machines that actually have an IR sensor.
- Reuse the clamshell gate (`omarchy-hw-laptop-closed`) so a shut lid falls
  through to password instead of blocking on an unreachable camera.

## Non-goals

- **Bitwarden vault unlock.** The vault is remote, over Tailscale, and
  Bitwarden's Linux client has no PAM/polkit-mediated unlock path the way
  1Password's does — it's master-password (+ optional TOTP/FIDO2 in Bitwarden
  itself) only. Face auth here covers local OS auth (sudo, polkit, lock
  screen); it does **not** touch vault unlock. Don't build toward this — flag
  it explicitly in any documentation this spec produces so nobody expects the
  face scan to open Bitwarden.
- Passkey/FIDO2 storage or WebAuthn — orthogonal, already covered by
  `omarchy setup security fido2` for hardware keys. Bitwarden-stored passkeys
  are a browser-extension concern, not a PAM concern.
- Liveness/anti-spoof hardening beyond what the chosen backend ships with.
  Note the risk (below) but don't scope-creep into building our own.
- Non-laptop / desktop webcam support. Detection should positively identify
  an IR-capable UVC device, not just "any camera," to avoid inviting RGB-only
  users into a much weaker (photo-spoofable) setup.

## Backend choice: Howdy

No `howdy` package in the Arch official repos; it's AUR-only (`howdy` or
`howdy-git`). It's the de facto Linux equivalent of Windows Hello: opencv +
dlib face landmark matching, PAM module (`pam_python.so` +
`/lib64/security/howdy/pam.py`), and it already supports pointing at a
specific `/dev/videoN` device and IR-only capture via its config
(`device_path`, `dark_threshold` / IR mode), which matters here since we
specifically want it reading `/dev/video2`, not the RGB webcam.

Alternative considered: hand-rolled opencv script. Rejected — Howdy already
solves enrollment, matching thresholds, and PAM integration; reinventing it
buys nothing and loses the community-vetted matching logic.

Follow `omarchy pkg aur add howdy` for install (mirrors how the rest of
Omarchy pulls AUR-only packages) rather than a raw `pacman`/`yay` call.

## Architecture (mirroring `omarchy-setup-security-fingerprint` /
`omarchy-setup-security-fido2`)

```
omarchy-hw-ir-camera                 # hardware probe, exit 0/1
omarchy-setup-security-face          # omarchy:summary / omarchy:requires-sudo
omarchy-remove-security-face
```

`omarchy-hw-ir-camera` detection approach: enumerate `/dev/video*` via
`v4l2-ctl --list-formats`, look for a UVC device exposing a second stream in
raw `GREY`/`Y8`/`Y16` format alongside a sibling MJPG/YUYV stream (the IR +
RGB pairing pattern this webcam uses). Needs validation against at least one
other IR-webcam laptop model — don't assume this exact pairing is universal;
see Open Questions.

`omarchy-setup-security-face` responsibilities, following the fingerprint
script's shape exactly:

1. Bail early if `omarchy-hw-ir-camera` fails — no hardware, no prompt.
2. `omarchy-pkg-add` the RGB/opencv deps; `omarchy pkg aur add howdy`.
3. Write Howdy's config to point `device_path` at the detected IR node, not
   whatever `/dev/video0` Howdy would default to.
4. Run enrollment (`sudo howdy add`) and a verification pass (`sudo howdy
   test`) — mirrors the fingerprint script's enroll-then-verify sequencing,
   **before** touching any PAM file, so a bad enrollment can't leave the
   system in a half-configured state.
5. Insert the clamshell gate + `pam_python.so` howdy line into
   `/etc/pam.d/sudo` and `/etc/pam.d/polkit-1`, `sufficient`, same
   idempotency checks (`grep -q` before `sed -i`) as the existing scripts.
6. Lock screen integration — see below, this is the one genuinely open piece.

`omarchy-remove-security-face` mirrors `omarchy-remove-security-fingerprint`:
strip the PAM lines, leave `howdy` installed but unconfigured (user's face
data stays local unless they ask to purge it too — confirm this matches how
the fingerprint remove script treats enrolled prints before assuming).

## The lock screen problem (read before starting)

Omarchy's lock screen is **not** raw hyprlock — it's a custom Quickshell
component at `shell/plugins/lock/Service.qml`. Fingerprint support there is
hardcoded, not generic: a `PamContext`-like object literally named
`fingerprintPam` with `config: "omarchy-lock-fingerprint"`, gated by a
`fingerprintConfigured` property that shells out to check
`/etc/pam.d/omarchy-lock-fingerprint` + `fprintd-list`. There's no pluggable
"any PAM factor" hook to attach to — it's fingerprint-shaped, specifically.

Two real paths, pick one deliberately rather than discovering this mid-build:

- **(a) Upstream-shaped:** extend `Service.qml` itself with a parallel
  `facePam`/`faceConfigured` path (own PAM service name, e.g.
  `omarchy-lock-face`, own detection shell-out). This is the "real" fix and
  what a PR to basecamp/omarchy would need, but it's editing Omarchy's own
  source tree, not a user-space plugin — see `contributing.md` in the
  `omarchy` skill for the fork/PR workflow if this path is chosen.
- **(b) Local-only:** `omarchy plugin clone` the lock plugin into
  `~/.config/omarchy/plugins/<user>.lock/` (per `plugins.md`'s
  clone-to-customize pattern) and add face support only in the clone. Stays
  entirely local, survives `omarchy update` since it's a user override, but
  needs re-diffing against upstream's `Service.qml` after Omarchy updates it.

Sudo and polkit face auth (the actual security-relevant surface) don't have
this problem — plain PAM stack edits, no Quickshell involved. If scope needs
trimming, drop lock-screen face auth first and ship sudo+polkit only; that's
still a complete, useful `security face` command.

## Security notes (put these in the setup script's own output, not just here)

- Howdy's matching is meaningfully weaker than Windows Hello — no fused
  depth sensor, and the community track record includes successful photo/
  video spoofing on some setups. Pin it to `sufficient`, never `requisite`,
  so password stays as the real fallback everywhere it's wired in — same
  posture the fingerprint/fido2 scripts already take, keep it consistent
  rather than tightening it just for face.
- Since this is `sudo`-facing, don't gate this behind a lower trust bar than
  fingerprint gets. Do the same enroll-then-verify-before-PAM sequencing so a
  broken match doesn't lock sudo out from under a working TTY.

## Rollout

1. **Spike:** confirm Howdy actually drives `/dev/video2` cleanly on this
   hardware (IR format support, lighting behavior) before writing any of the
   omarchy-shaped scripts around it. This is the part most likely to not
   just work.
2. Build `omarchy-hw-ir-camera` + `omarchy-setup-security-face` +
   `omarchy-remove-security-face`, sudo/polkit only. Get this solid and
   dogfood it before touching the lock screen.
3. Decide (a) vs (b) above for lock-screen support, once sudo/polkit face
   auth has been lived with for a bit.
4. If going the upstream route, follow `contributing.md`: fork
   `basecamp/omarchy`, follow its `AGENTS.md`, `./test/all` before PR.

## Open questions

- Is the IR-stream-as-second-UVC-format pairing (`...I` card name + `GREY`
  format) how other IR webcams on Linux present, or is that specific to this
  webcam vendor? Detection logic shouldn't overfit to one laptop.
- Does Howdy's IR mode need `dark_threshold`/exposure tuning on this specific
  sensor, or does it work out of the box? Part of the spike.
- Fingerprint remove script's exact handling of enrolled-print cleanup —
  check `omarchy-remove-security-fingerprint` before assuming the face
  equivalent should (not) purge enrolled face data by default.

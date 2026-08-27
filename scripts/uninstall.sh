#!/bin/bash

# Undoes scripts/install.sh: takes the commands back off $PATH and unregisters
# the lock plugin. It does not touch PAM — see the warning below — because
# unwiring authentication is a decision, not cleanup.

set -e

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo_root/manifest.json" | head -1)
plugins_dir="$HOME/.config/omarchy/plugins"

commands=(
  omarchy-hw-ir-camera
  omarchy-setup-security-face
  omarchy-remove-security-face
)

echo -e "\e[32mUninstalling omarchy face authentication.\n\e[0m"

# PAM still pointing at pam_howdy after the setup command is gone is the one
# way to end up locked out of sudo, so check before anything is removed and let
# the user decide. Warn rather than remove: omarchy-remove-security-face also
# drops howdy-next, which is more than an uninstall of this repo should do on
# its own.
if grep -q 'pam_howdy\.so' /etc/pam.d/sudo 2>/dev/null ||
  grep -q 'pam_howdy\.so' /etc/pam.d/polkit-1 2>/dev/null ||
  [[ -f /etc/pam.d/omarchy-lock-face ]]; then
  echo -e "\e[31mFace authentication is still wired into PAM.\e[0m"
  echo "Run this first, while the command still exists:"
  echo
  echo "    omarchy remove security face"
  echo
  echo "Continuing anyway — the PAM lines will stay behind."
  echo
fi

omarchy_bin_dir=$(dirname -- "$(command -v omarchy)")
for command in "${commands[@]}"; do
  for dir in "$omarchy_bin_dir" /usr/bin; do
    link="$dir/$command"
    # Only reclaim a symlink that points back into this checkout. A real file
    # there is somebody else's (a packaged omarchy command, say) and is not
    # ours to delete.
    if [[ -L $link && $(readlink -f "$link") == "$repo_root/scripts/$command" ]]; then
      echo "Removing $link..."
      sudo rm -f "$link"
    fi
  done
done

if [[ -n $plugin_id && -L $plugins_dir/$plugin_id ]] &&
  [[ $(readlink -f "$plugins_dir/$plugin_id") == "$repo_root" ]]; then
  echo "Unlinking the lock plugin from $plugins_dir..."
  rm -f "$plugins_dir/$plugin_id"
  echo -e "\n\e[31mThe lock plugin may still be enabled in shell.json.\e[0m"
  echo "Fall back to the built-in lock screen with:"
  echo
  echo "    omarchy plugin disable $plugin_id"
fi

echo -e "\n\e[32mUninstalled.\e[0m"

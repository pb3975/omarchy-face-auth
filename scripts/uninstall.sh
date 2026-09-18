#!/bin/bash

# Undoes scripts/install.sh: takes the commands back off $PATH and unregisters
# the lock plugin. It does not touch PAM — see the warning below — because
# unwiring authentication is a decision, not cleanup.

set -euo pipefail

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
    installed_command="$dir/$command"
    # Remove a root-owned copy only while it still matches this checkout, so a
    # packaged or locally replaced command with the same name is left alone.
    # The symlink branch cleans up installs made before commands were copied.
    if [[ -f $installed_command && ! -L $installed_command ]] &&
      [[ $(stat -c %u:%g "$installed_command") == 0:0 ]] &&
      cmp -s "$repo_root/scripts/$command" "$installed_command"; then
      echo "Removing $installed_command..."
      sudo rm -f "$installed_command"
    elif [[ -L $installed_command ]] &&
      [[ $(readlink -f "$installed_command") == "$repo_root/scripts/$command" ]]; then
      echo "Removing legacy symlink $installed_command..."
      sudo rm -f "$installed_command"
    fi
  done
done

# Remove the root-owned packaging recipe only when it still matches this
# checkout. A newer/replaced recipe is left in place rather than deleting data
# this uninstall script did not install.
howdy_package_dir=/usr/share/omarchy-face-auth/howdy-next
if [[ -f $howdy_package_dir/PKGBUILD && -f $howdy_package_dir/polkit-camera.conf ]] &&
  [[ $(stat -c %u:%g "$howdy_package_dir/PKGBUILD") == 0:0 ]] &&
  [[ $(stat -c %u:%g "$howdy_package_dir/polkit-camera.conf") == 0:0 ]] &&
  cmp -s "$repo_root/packaging/howdy-next/PKGBUILD" "$howdy_package_dir/PKGBUILD" &&
  cmp -s "$repo_root/packaging/howdy-next/polkit-camera.conf" "$howdy_package_dir/polkit-camera.conf"; then
  echo "Removing pinned Howdy packaging data..."
  sudo rm -rf -- /usr/share/omarchy-face-auth
fi

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

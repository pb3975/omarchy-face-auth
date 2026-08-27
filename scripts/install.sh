#!/bin/bash

# Puts this repo's three omarchy-* commands on $PATH and registers the lock
# plugin with the shell. It deliberately stops there: it does not enroll a
# face, edit PAM, or enable the plugin, so installing is always reversible by
# running scripts/uninstall.sh and nothing else.

set -e

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo_root/manifest.json" | head -1)
plugins_dir="$HOME/.config/omarchy/plugins"

commands=(
  omarchy-hw-ir-camera
  omarchy-setup-security-face
  omarchy-remove-security-face
)

echo -e "\e[32mInstalling omarchy face authentication.\n\e[0m"

# The registry keeps the executable bit off the checked-in sources, so the
# scripts only become runnable at install time.
chmod +x "${commands[@]/#/$repo_root/scripts/}"

# The omarchy CLI discovers subcommands by scanning its own directory — the
# resolved location of `omarchy` on $PATH (/usr/share/omarchy/bin on a stock
# install), NOT /usr/bin. Link there so `omarchy setup security face` routes,
# and into /usr/bin as well: that's the fixed path PAM's pam_exec gate lines
# and other scripts can rely on across package installs and dev-link.
# Symlinks rather than copies so editing the repo takes effect immediately.
omarchy_bin_dir=$(dirname -- "$(command -v omarchy)")
for command in "${commands[@]}"; do
  echo "Linking $command into $omarchy_bin_dir..."
  sudo ln -sf "$repo_root/scripts/$command" "$omarchy_bin_dir/$command"
  if [[ $omarchy_bin_dir != /usr/bin ]]; then
    echo "Linking $command into /usr/bin..."
    sudo ln -sf "$repo_root/scripts/$command" "/usr/bin/$command"
  fi
done

# The lock plugin has to live under ~/.config/omarchy/plugins to be found.
# A symlink to the repo is safe here and is what keeps local edits live:
# omarchy-plugin-catalog walks the directory with `find -L`, and the shell's
# own PluginRegistry rescan globs "$dir"/*/ and then tests -f on the manifest,
# both of which follow a symlinked plugin directory.
#
# The one thing a symlink costs is hot reload: the registry's inotifywait -m -r
# watcher does not descend into symlinks, so edits need omarchy-restart-shell
# rather than being picked up as you save.
if [[ -n $plugin_id ]]; then
  mkdir -p "$plugins_dir"
  if [[ -d $plugins_dir/$plugin_id && ! -L $plugins_dir/$plugin_id ]]; then
    echo -e "\e[31m$plugins_dir/$plugin_id is a real directory (installed with omarchy plugin add?).\e[0m"
    echo "Leaving it alone — remove it first if you want it to track this repo instead."
  else
    echo "Linking the lock plugin into $plugins_dir..."
    ln -sfn "$repo_root" "$plugins_dir/$plugin_id"
  fi
fi

cat <<EOF

$(echo -e "\e[32mInstalled.\e[0m") Next steps:

  1. omarchy setup security face
     Detects the IR camera, installs howdy-next, enrolls and verifies your
     face, then wires PAM for sudo, polkit, and the lock screen.

  2. omarchy plugin enable $plugin_id
     Switches the lock screen over to the copy of the lock plugin in this
     repo, which is the one that knows about face auth.

If you'd rather install the plugin the normal way instead of from this
checkout, drop the symlink above and use: omarchy plugin add <git-url>
EOF

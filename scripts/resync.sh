#!/bin/bash

# Drift helper for the lock plugin.
#
# The plugin in this repo is a patched copy of Omarchy's built-in lock plugin,
# so every `omarchy update` that touches Service.qml or LockView.qml leaves our
# copy behind. This checks whether that has happened and, if it has, rebuilds
# our copy from the new upstream plus patches/face-lock.patch.
#
# Safe to run as often as you like: when nothing upstream has moved it does
# nothing, and when the patch does not apply it puts the repo back exactly as
# it found it.

set -e

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
upstream="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock"
checksums="$repo_root/patches/UPSTREAM_SHA256"
patch_file="$repo_root/patches/face-lock.patch"

# The order here is the order UPSTREAM_SHA256 records, so a regenerated file
# stays diff-clean against the old one.
files=(LockView.qml Service.qml)

for required in "$checksums" "$patch_file"; do
  [[ -f $required ]] || {
    echo -e "\e[31mMissing $required.\e[0m" >&2
    exit 1
  }
done

for file in "${files[@]}"; do
  [[ -f $upstream/$file ]] || {
    echo -e "\e[31mUpstream $upstream/$file is missing — has the lock plugin moved?\e[0m" >&2
    exit 1
  }
done

# UPSTREAM_SHA256 holds bare filenames, so the check has to run from the
# upstream directory rather than from the repo.
if (cd "$upstream" && sha256sum -c --status "$checksums" 2>/dev/null); then
  echo -e "\e[32mLock plugin is in sync with upstream.\e[0m"
  exit 0
fi

echo "Upstream lock plugin has changed. Rebuilding the patched copy..."

# Back the repo copies up by hand rather than leaning on `git checkout`: this
# has to restore correctly even when the working tree already had uncommitted
# edits to those files, which git checkout would throw away.
backup=$(mktemp -d)
restore() {
  local file
  for file in "${files[@]}"; do
    if [[ -f $backup/$file ]]; then
      cp "$backup/$file" "$repo_root/$file"
    else
      rm -f "$repo_root/$file"
    fi
  done
  return 0
}
trap 'rm -rf "$backup"' EXIT

for file in "${files[@]}"; do
  if [[ -f $repo_root/$file ]]; then
    cp "$repo_root/$file" "$backup/$file"
  fi
  cp "$upstream/$file" "$repo_root/$file"
done

# git apply is all-or-nothing and leaves no .rej litter behind, and its
# --verbose output names the file and line of every hunk that would not go on.
# Fall back to patch(1) only when git is unavailable.
if command -v git &>/dev/null; then
  apply_output=$(cd "$repo_root" && git apply -p1 --verbose "$patch_file" 2>&1) || apply_failed=1
else
  apply_output=$(cd "$repo_root" && patch -p1 --forward --no-backup-if-mismatch -r - <"$patch_file" 2>&1) || apply_failed=1
fi

if [[ -n ${apply_failed:-} ]]; then
  restore
  echo
  echo -e "\e[31mpatches/face-lock.patch no longer applies. The repo has been restored.\e[0m"
  echo -e "\e[31mFailures:\e[0m"
  echo "$apply_output" | grep -Ei 'error|fail|reject' || echo "$apply_output"
  echo
  echo "Merge the upstream changes by hand:"
  echo
  echo "    cp $upstream/{LockView,Service}.qml $repo_root/"
  echo "    patch -p1 <$patch_file        # resolve the .rej files it leaves"
  echo "    git -C $repo_root diff >$patch_file"
  echo
  echo "Then re-run this script to record the new upstream checksums."
  exit 1
fi

# Only now is the recorded upstream the one our copy was actually built from.
(cd "$upstream" && sha256sum "${files[@]}") >"$checksums"

echo
echo -e "\e[32mRebuilt the patched lock plugin against the new upstream.\e[0m"
echo -e "\e[31m>>> The patch applied cleanly, which is not the same as it still being"
echo -e ">>> correct. Read the diff and unlock the screen once by face and once by"
echo -e ">>> password before you trust it: a lock screen that fails both ways is a"
echo -e ">>> reboot, not a bug report.\e[0m"
echo
echo "    git -C $repo_root diff"
echo "    omarchy-restart-shell"

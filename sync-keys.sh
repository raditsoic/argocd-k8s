#!/usr/bin/env bash
# Copy Vagrant's per-machine SSH keys from /mnt/c (where Linux permissions
# don't exist) to the WSL filesystem (where chmod 600 works).
# Re-run after every `vagrant up` that (re)creates machines.
set -euo pipefail
mkdir -p "$HOME/.ssh/vagrant-lab"
for m in cp web1 web2 db; do
  src=".vagrant/machines/$m/virtualbox/private_key"
  [ -f "$src" ] || { echo "skip $m (no key yet)"; continue; }
  cp "$src" "$HOME/.ssh/vagrant-lab/$m"
  chmod 600 "$HOME/.ssh/vagrant-lab/$m"
done
ls -la "$HOME/.ssh/vagrant-lab/"

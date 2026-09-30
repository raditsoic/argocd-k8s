#!/usr/bin/env bash
# Bootstrap the lab registry: regenerate the htpasswd file from the
# vault-sealed registry password, then start the registry container.
#
# Run from WSL with docker usable in this distro (Docker Desktop →
# Settings → WSL integration, or a native docker). No args starts just
# the registry; pass `--profile tunnel` to also bring up cloudflared
# (needs TUNNEL_TOKEN in registry/.env).
set -euo pipefail
cd "$(dirname "$0")/.."

PW=$(ansible-vault view group_vars/all/vault.yml --vault-password-file ~/.vault-tiket-lab \
      | sed -n 's/^vault_registry_password: //p')
[ -n "$PW" ] || { echo "vault_registry_password missing from the vault" >&2; exit 1; }

# bcrypt hash fresh on every run; the file is gitignored. -i: password on stdin.
printf '%s' "$PW" | docker run --rm -i --entrypoint htpasswd httpd:2.4 -Bbni tiket \
  > registry/htpasswd

docker compose -f registry/compose.yaml "$@" up -d
echo "registry answering on http://127.0.0.1:5000 (auth: tiket / vault password)"

# vagrant — k3s GitOps lab (HAProxy + ArgoCD)

Four Debian 12 VMs (VirtualBox, managed by Vagrant, provisioned by Ansible):

| Machine | Private IP      | Role                                                        | NAT forward (127.0.0.1)                        |
| ------- | --------------- | ----------------------------------------------------------- | ---------------------------------------------- |
| `cp`    | `192.168.56.10` | k3s server (control plane) + HAProxy entry point + dnsmasq + ArgoCD | SSH `2210`, HTTP `8080`, ArgoCD UI `8090`, DNS `5533` |
| `web1`  | `192.168.56.11` | k3s agent (worker), runs app pods                           | SSH `2211`                                     |
| `web2`  | `192.168.56.12` | k3s agent (worker), runs app pods                           | SSH `2212`                                     |
| `db`    | `192.168.56.20` | PostgreSQL 15 (shared visits DB)                            | SSH `2213`, psql `5433`                        |

All machines share one host-only network. The app runs as a **Kubernetes
Deployment** (2 replicas, one pod per worker node, image pulled from the
lab's own registry — see "Containerized app + registry" below), and all
pods write to **one shared PostgreSQL** on `db.tiket.lab` — the production
topology: interchangeable stateless pods plus a dedicated database VM.
Pods receive their node name via the downward API (`NODE_NAME`), and
topology spread keeps one pod per worker: hitting the entry point visibly
alternates between the two backends — each pod greets with its own pod
name — while the visit total climbs monotonically no matter which pod
answers. The shared DB is exactly what makes the backends swappable.

The architecture in one paragraph: **HAProxy runs on the cp VM itself**
(host-level systemd service — there is no ingress controller in the
cluster, k3s starts with `--disable=traefik`). Its `:80` frontend
round-robins the app's NodePort `:30080` on web1/web2 (the host `8080`
forward hits it), with TCP health checks on purpose: the app's `/` writes
a `visits` row per GET, so HTTP checks would fabricate rows. Its `:8081`
frontend reaches the **ArgoCD UI** (forwarded to host `8090`, plain HTTP —
`argocd-server` runs with `server.insecure=true`; no TLS anywhere in the
lab), and `:8404` serves HAProxy stats (in-lab only, never forwarded).
**ArgoCD runs in-cluster, pinned to the tainted cp** (it tolerates
`CriticalAddonsOnly` and carries a `kubernetes.io/hostname: cp`
nodeSelector, so it never competes with app pods on the 1 GB workers). It
watches the public manifests repo **`github.com/Raditsoic/tiket-k8s`**
(Application `tiket-app`: auto-sync + prune + self-heal) — the repo is the
source of truth for the Deployment/Service; pushes deploy, manual
`kubectl` mutations get reverted. The one exception: the app **Secret**
(`tiket-app-env`, DB credentials) stays out of GitHub — Ansible applies it
from the vault, out-of-band; untracked by ArgoCD, it is neither pruned nor
flagged (orphaned-resource monitoring is off in the default project). cp
also runs **dnsmasq**, which serves the
`tiket.lab` zone for all machines (including `argocd.tiket.lab` → cp):
pod DNS (CoreDNS → dnsmasq) and the nodes' resolv.conf both resolve
through it.

## Run it

**Destroy the old `lb`-named lab first** — these VMs reuse its fixed IPs
(`192.168.56.10-12/20`):

```bash
cd ../lb && vagrant destroy -f && cd -   # only needed while the old lab still exists
```

The manifests repo (`github.com/Raditsoic/tiket-k8s`) must exist and be
pushed **before** the first provision — the cp play waits for ArgoCD to
sync from it (after this migration it does; if you ever recreate the repo,
push it first).

```bash
vagrant up            # WSL vagrant — NOT vagrant.exe (see below)
./sync-keys.sh        # copy VM keys to ~/.ssh/vagrant-lab with Linux permissions
./registry/up.sh      # start the lab registry (reads the vault; see below)
vagrant provision     # run the Ansible playbook (needs ~/.vault-tiket-lab — see Secrets)
```

First provision takes **~20–30 min**: k3s plus ~1 GB of ArgoCD images
pulled through the NAT network. If the ArgoCD availability wait times out,
just re-run `vagrant provision` — every task converges. (The ArgoCD pin
patches re-assert themselves on each run — k3s tracks no field ownership,
so the server-side install pass and the pins can't agree on "no change" —
and the ArgoCD pods quietly re-roll; that is cosmetic, not drift.)

Verify the app through HAProxy:

```bash
for i in $(seq 1 6); do curl -s http://127.0.0.1:8080/ | grep -E '<h1>|shared'; done
# <h1>Hello from web1</h1>   (each page also shows the shared visit total)
# <h1>Hello from web2</h1>
# ...
```

Verify the topology — no Traefik anywhere, ArgoCD pinned to cp, app pods
on the workers only:

```bash
vagrant ssh cp -c 'sudo k3s kubectl get pods -A -o wide'
```

Verify the Application is Synced/Healthy:

```bash
vagrant ssh cp -c 'sudo k3s kubectl -n argocd get application tiket-app'
```

ArgoCD UI — `http://127.0.0.1:8090` (also works from a Windows browser),
user `admin`, password:

```bash
vagrant ssh cp -c 'sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d'
```

HAProxy stats (from inside the lab only):

```bash
vagrant ssh cp -c 'curl -s http://127.0.0.1:8404/stats'
```

Shared-state check and direct DB access (unchanged from before):

```bash
vagrant ssh db -c "sudo -u postgres psql tiketdb -c 'SELECT host, COUNT(*) FROM visits GROUP BY host;'"

psql "host=127.0.0.1 port=5433 dbname=tiketdb user=tiket password=$(ansible-vault view group_vars/all/vault.yml --vault-password-file ~/.vault-tiket-lab | tail -1 | cut -d' ' -f2)" -c '\dt'
```

DNS — query dnsmasq from WSL (needs `dnsutils`; non-standard port):

```bash
dig @127.0.0.1 -p 5533 web1.tiket.lab        # → 192.168.56.11
dig @127.0.0.1 -p 5533 argocd.tiket.lab      # → 192.168.56.10
```

## GitOps workflow

- **Change a manifest**: edit in `../tiket-k8s` (or a clone of it), push to
  `main` → ArgoCD syncs within ~3 min. That's the whole deploy story for
  manifests.
- **Deploy a new app image**: a tag-bump commit to
  `Raditsoic/tiket-k8s/tiket/deployment.yaml` (CI pushes it on every `main`
  build — see CI/CD below). `app_version` in `group_vars` is **gone**; the
  image tag lives in the manifests repo now.
- **Rollback**: `git revert` the bump/manifest commit and push — ArgoCD
  rolls the cluster back. Never `kubectl` by hand: **self-heal** reverts
  manual mutations to the repo state.

## Containerized app + registry

The app ships as a container image built from the app repo
`github.com/Raditsoic/tiket-app` (Flask + gunicorn + psycopg2; the DSN
arrives via env vars, so **the image contains no credentials** and is
safe to push). A registry container runs on the WSL/Windows side, and
the cluster pulls from it. Two modes:

- **Tunnel mode (normal)** — `./registry/up.sh --profile tunnel` with a
  named Cloudflare tunnel (token in `registry/.env`) publishes the registry
  at a real TLS hostname. Set `registry_host` in
  `group_vars/all/vars.yml` to that hostname **and change the image prefix
  in `tiket-k8s/tiket/deployment.yaml` to match** — the registry prefix is
  baked into the manifests repo now. `registry_insecure_addresses` stays
  empty and no containerd exceptions exist.
- **Offline/NAT mode (no Cloudflare account)** — the guests reach the
  Windows host's loopback registry through the VirtualBox NAT gateway at
  `10.0.2.2:5000`. Plain HTTP, so `registry_insecure_addresses` must list
  it — the playbook writes `/etc/rancher/k3s/registries.yaml` (a
  containerd mirror + auth entry) on every node accordingly. This is the
  current default, and `deployment.yaml`'s `10.0.2.2:5000/` prefix matches
  it.

Build and publish a version (anywhere docker works):
```bash
docker build -t localhost:5000/tiket-app:v1 /path/to/tiket-app/
printf '%s' "$(ansible-vault view group_vars/all/vault.yml --vault-password-file ~/.vault-tiket-lab | sed -n 's/^vault_registry_password: //p')" \
  | docker login localhost:5000 -u tiket --password-stdin
docker push localhost:5000/tiket-app:v1
```

(Pushing as `localhost:5000/…` and pulling as `10.0.2.2:5000/…` hits the
same registry — the repo path is just `tiket-app`; only the transport
address differs. For tunnel mode, tag/push with the tunnel hostname.)

Deploy = commit the new tag to the manifests repo (CI does it; manually:
edit `image:` in `tiket-k8s/tiket/deployment.yaml` and push). There are no
liveness/readiness probes on purpose — the app's `/` writes a `visits` row
per request, so probes would fabricate rows; rollout health is
`kubectl rollout status` (what CI waits on).

### Lifecycle — `vagrant up` to `vagrant destroy`

```bash
# one-time prerequisite: vault password at ~/.vault-tiket-lab (see Secrets).
# It lives on the WSL filesystem, outside the repo — destroy never touches it.

vagrant up              # create + start the VMs
./sync-keys.sh          # after every up that (re)created machines: refresh ~/.ssh/vagrant-lab
vagrant provision       # run/re-run the playbook on running VMs (needs the vault password)

# day to day
vagrant halt            # shut down, disks kept; plain `vagrant up` boots without re-provisioning
vagrant suspend         # or freeze VM state; `vagrant resume` (or `vagrant up`) continues
vagrant destroy -f      # delete VMs + disks — this is what wipes state (the visits table)
```

Rebuilding from scratch: recreated VMs get new SSH keys, so skip the
auto-provision on `up` (it would fail auth against the stale synced keys),
resync, then provision:

```bash
vagrant destroy -f
vagrant up --no-provision
./sync-keys.sh
vagrant provision
```

Notes:

- `~/.vault-tiket-lab` is machine-independent: it survives destroy/rebuild,
  and every provision needs it.
- Destroy drops the database with the VM. The playbook recreates the role
  and database, and the app recreates the `visits` table (`CREATE TABLE IF
  NOT EXISTS`) — the counter starts over at 0.
- Recreated VMs also have new SSH host keys. Ansible doesn't care (Vagrant
  runs it with host-key checking off), but plain `ssh -p 2210
  vagrant@127.0.0.1` may need `ssh-keygen -R '[127.0.0.1]:2210'` first
  (2210–2213, one per VM).
- A **cp rebuild** also needs the Jenkins deploy pubkey re-installed on cp
  (`~/.ssh/tiket-deploy-jenkins.pub` → root's `authorized_keys`) so CI's
  read-only verification SSH keeps working.

## Secrets

The db and registry passwords live vault-encrypted in `group_vars/all/vault.yml` — the
repo contains no plaintext credential. The vault password itself is
deliberately **not** in the repo: it sits at `~/.vault-tiket-lab` (mode
0600, on the WSL filesystem). It can't live under `/mnt/c`: files there are
always marked executable, and ansible-vault treats an executable password
file as a script to execute rather than a password to read.

`vagrant provision` picks the file up via the Vagrantfile provisioner
(`ansible.vault_password_file`); manual ansible runs must pass it:

```bash
ansible-playbook -i ansible_hosts playbook.yml --vault-password-file ~/.vault-tiket-lab
```

Rotate a password (edits the vault file; the next provision updates the
PostgreSQL role and every web's container DSN — for the registry password,
`./registry/up.sh` regenerates the htpasswd and a provision re-logs-in):

```bash
ansible-vault edit group_vars/all/vault.yml --vault-password-file ~/.vault-tiket-lab
vagrant provision
```

The app Secret is applied by the control-plane play (`/opt/tiket/secret.yaml`
→ `k3s kubectl apply`) and is the **only** workload object still
Ansible-managed — everything else comes from the GitOps repo, which stays
secret-free so it can stay public.

## WSL + VirtualBox: why it's set up this way

This lab is driven from **WSL2 in mirrored networking mode**
(`wslinfo --networking-mode` → `mirrored`), with Windows-side VirtualBox.
That combination dictates everything unusual in the Vagrantfile:

- **Mirrored mode shares `127.0.0.1` between Windows and WSL**, so
  VirtualBox's NAT port forwards (bound on Windows localhost) are reachable
  from WSL. SSH/Ansible therefore go through fixed forwards `2210–2213`.
- **VirtualBox's `192.168.56.x` host-only subnet is NOT reachable from
  WSL** — the mirroring driver doesn't include Oracle's host-only adapter,
  and Windows doesn't route WSL packets into it. So the private network is
  used only guest-to-guest (cp's HAProxy → the webs); hosts never contact
  it directly. (In WSL's default NAT mode it's the exact opposite:
  localhost forwards are unreachable from WSL, host-only works.)
- **Ports are pinned with `auto: false`** because Vagrant's default SSH
  forwards (2222, 2200, …) shift around on collisions, which would break
  the static inventory.
- **WSL Vagrant drives Windows VirtualBox** via `VBoxManage.exe`. This
  requires `VAGRANT_WSL_ENABLE_WINDOWS_ACCESS=1` in the WSL environment
  (and `/mnt/c/Program Files/Oracle/VirtualBox` on PATH for manual
  VBoxManage calls). Linux VirtualBox can't run inside WSL (no kernel
  modules), so this is the intended pattern.

### Use `vagrant`, never `vagrant.exe`

Ansible lives in WSL, and `vagrant.exe` can't use it (provisioning fails
with "The Ansible software could not be found"). Both binaries are on PATH
here, so be explicit. Mixing them also makes `.vagrant/` record conflicting
machine paths — the "machine used to live in …" warning — which is noisy
but harmless.

## How provisioning is structured

`playbook.yml` has four plays. The old `[loadbalancers]` group is now
**`[controlplane]`** — the machine is the control plane (`cp`), not an
nginx LB.

1. **All machines** — apt cache.
2. **dbservers** — PostgreSQL 15 listening on all interfaces, `pg_hba`
   rules admitting the app role from `192.168.56.0/24` (pod traffic to db
   arrives SNAT'd to node IPs) and `10.0.2.2/32` (WSL via the NAT
   forward), plus the `tiket` role and `tiketdb` database.
3. **controlplane (`cp`)** — dnsmasq config (+ `argocd.tiket.lab` record)
   and resolv.conf at the host-only IP (**not** 127.0.0.1: k3s bakes this
   file into CoreDNS's upstream, and CoreDNS may run on any node — the
   host-only address is reachable cluster-wide); HAProxy config +
   `systemd enable --now` (the VM-level entry point); k3s server install
   (`--node-ip`/`--flannel-iface` pinned to the host-only interface,
   `CriticalAddonsOnly` taint, kubeconfig mode 644 for the CI deploy user,
   `--disable=traefik` because HAProxy owns port 80 now); then the app
   Secret (only Ansible-managed workload object, from the vault); then
   ArgoCD: pinned-version `install.yaml` downloaded to `/opt/argocd`,
   `argocd` namespace, server-side apply, `server.insecure=true` via the
   `argocd-cmd-params-cm` ConfigMap (official knob, read into
   `ARGOCD_SERVER_INSECURE`), tolerate+pin patches on every
   Deployment/StatefulSet (looped over `kubectl get deploy,statefulset -o
   name`, so it survives ArgoCD version changes), `argocd-server` patched
   to NodePort `:30081/:30443`, Availability wait (~1 GB of quay.io images
   on first run), and finally the Application pointing at the manifests
   repo + a wait for `status.sync.status == Synced`. Exports the agent
   join token to the next play.
4. **webservers (workers)** — resolv.conf at cp's dnsmasq with the NAT
   resolver as fallback, same dhclient enter-hook, same registry config
   and interface pinning, then the k3s agent join.

Shared values (`lab_domain`, PG version, db name/user, NodePorts,
HAProxy/ArgoCD settings) live in `group_vars/all/vars.yml` because
play-level vars don't cross plays; the db password is vault-encrypted in
the same directory (see Secrets) and stitched in as
`tiket_db.password: "{{ vault_tiket_db_password }}"`.

Two ordering details that matter:

- The **control-plane play runs before the workers** (`vagrant provision`
  drives each machine with `--limit`): the agent install consumes the join
  token read off cp, and the Application's pods sit Pending until the
  workers join — which is why the sync wait tolerates app pods not
  running yet.
- cp's dnsmasq config uses `no-resolv` + `server=10.0.2.3`, because cp's
  own resolv.conf points at dnsmasq (via the host-only IP) — without
  `no-resolv` it would loop trying to read its own forwarder config.

## Files

| File | Purpose |
| ---- | ------- |
| `Vagrantfile` | VM definitions, port forwards, WSL-aware provisioning |
| `playbook.yml` | 4 plays: common, db (PostgreSQL), control plane (dnsmasq + HAProxy + k3s server + Secret + ArgoCD), workers (k3s agents) |
| `ansible_hosts` | static inventory (WSL only): hosts at `127.0.0.1:221x`, keys at `~/.ssh/vagrant-lab/`, plus `private_ip` vars |
| `ansible.cfg` | host key checking off (VMs are rebuilt often) |
| `group_vars/all/vars.yml` | shared values: `lab_domain`, PG version, db name/user, registry vars, `node_ports`, `haproxy`, `argocd` settings |
| `group_vars/all/vault.yml` | ansible-vault-encrypted db + registry passwords |
| `templates/dnsmasq.conf.j2` | lab DNS zone + upstream forwarding (+ `argocd.tiket.lab` record) |
| `templates/registries.yaml.j2` | containerd registry config (mirror + auth) written to every node |
| `templates/haproxy.cfg.j2` | HAProxy entry point: `:80` → app NodePort on the workers, `:8081` → ArgoCD UI, `:8404` stats |
| `templates/argocd-application.yaml.j2` | the ArgoCD Application (auto-sync/prune/self-heal → the manifests repo) |
| `templates/tiket-k8s/secret.yaml.j2` | app Secret (vault values) — the only workload object rendered here |
| `registry/compose.yaml`, `registry/up.sh` | lab image registry (+ cloudflared tunnel profile) and its bootstrap |
| `requirements.yml` | Ansible collections (`community.postgresql`) |
| `sync-keys.sh` | copies Vagrant keys from `/mnt/c` to WSL fs so chmod 600 works |

The app **Deployment/Service no longer live in this repo** — they are
`../tiket-k8s` (pushed to `github.com/Raditsoic/tiket-k8s`), deployed by
ArgoCD. The app **Jenkinsfile** lives in the app repo.

Note: every cross-node reference (agent→server join URL, CoreDNS's DNS
upstream, resolv.conf entries, HAProxy backends) is built from each host's
`private_ip` inventory var — **not** `ansible_host`, which is `127.0.0.1`
here (and also in Vagrant's auto-generated inventory) and only means
something through the WSL NAT forwards.

## CI/CD (Jenkins)

- App repo: `github.com/Raditsoic/tiket-app` (moved out of this repo; this
  repo's playbook owns the cluster, the manifests repo owns the workload).
- Every push: GitHub webhook → Jenkins (`jenkins` container on host 8085,
  fronted by the `jenkins-tunnel` cloudflared container) builds and pushes
  `localhost:5000/tiket-app:<branch>-<build>`; on `main` it also pushes
  `latest`.
- On `main` the pipeline **deploys by GitOps**: it clones
  `Raditsoic/tiket-k8s` over SSH with the Jenkins credential
  **`tiket-manifests-deploy-key`** (the private key `~/.ssh/tiket-manifests-ci`,
  registered on GitHub as the `tiket-ci` **deploy key with write access**),
  seds the new tag into `tiket/deployment.yaml`, commits
  `roll tiket-app to <tag>` and pushes — **that commit is the deploy**.
  ArgoCD then syncs (~3 min poll).
- Verification is **read-only** SSH to cp (port 2210, the existing
  `tiket-deploy-key` credential): poll until the live Deployment carries
  the tag, `kubectl rollout status`, then a health curl of
  `http://127.0.0.1/version` on cp through the real entry point.
- Rollback: `git revert` the tag-bump commit in `tiket-k8s` and push.
- A cp rebuild needs the plays re-run plus the deploy pubkey
  (`~/.ssh/tiket-deploy-jenkins.pub`) re-installed into root's
  `authorized_keys` (plain `kubectl` works for it because the server is
  installed with `--write-kubeconfig-mode 644`).
- UI: http://127.0.0.1:8085 (host) / https://jenkins.spacetrek.xyz (tunnel).

## Troubleshooting

- **`Permission denied (publickey)` from Ansible** — a new machine was
  created (new keypair) since the last sync. Re-run `./sync-keys.sh`.
  Keys under `/mnt/c` can't hold Linux permissions, hence the WSL copies.
- **Ansible times out on all hosts** — if WSL is switched back to NAT
  networking, `127.0.0.1` no longer reaches Windows' port forwards and this
  whole layout needs the host-only IPs instead.
- **`UNPROTECTED PRIVATE KEY FILE` for `.vagrant/machines/.../private_key`**
  — same /mnt/c permissions issue; the fix is the same `sync-keys.sh`.
- **Port 221x/808x/8090 already in use** — something else on Windows
  grabbed it; the `auto: false` forwards will error rather than silently
  move.
- **HAProxy 503s on `:8080`** — the app backends are down, usually because
  the workers haven't joined the cluster yet (`vagrant provision` does cp
  first, webs after). Check the backends on the stats page:
  `vagrant ssh cp -c 'curl -s http://127.0.0.1:8404/stats'`, and
  `sudo k3s kubectl get nodes`.
- **ArgoCD Application stuck OutOfSync / pods ImagePullBackOff** — the
  repo is unreachable (was it deleted/made private? ArgoCD reads it
  anonymously) or the `argocd-*` pods are still pulling images on first
  provision: `vagrant ssh cp -c 'sudo k3s kubectl -n argocd get pods'`, then
- **Re-provisions show the ArgoCD pin patches as `changed`** — expected:
  the SSA install pass and the pin patches chase each other (k3s here
  keeps no managedFields for kubectl to diff against), so each run
  re-applies the tolerations/nodeSelector and the argocd pods roll.
  Convergence is still correct; nothing to fix.
- **CI deploy didn't land** — the `tiket-manifests-deploy-key` Jenkins
  credential is missing, or the `tiket-ci` deploy key on GitHub lost write
  access. The pipeline fails at `git push` with `Permission denied
  (publickey)`.
- **Pod not serving / app 502s** — `vagrant ssh cp -c 'sudo k3s kubectl
  get pods -o wide'`, then `sudo k3s kubectl logs deploy/tiket-app`: the
  logs show the psycopg2 error (DNS? pg_hba? password?). `kubectl
  describe pod` shows scheduling/pull problems.
- **`pull access denied` / 401 from the registry** — the vault's registry
  password and the registry's htpasswd disagree; re-run `./registry/up.sh`
  (regenerates the hash) then `vagrant provision`.
- **`http: server gave HTTP response to HTTPS client`** — pulling the
  plain-HTTP registry without the containerd mirror: `registry_insecure_addresses`
  in `group_vars/all/vars.yml` must list it (offline/NAT mode), or front
  the registry with the tunnel for real TLS.
- **Webs can't resolve names while cp is halted** — their resolv.conf
  lists the NAT resolver as fallback, so apt still works, but `*.tiket.lab`
  names only exist while cp's dnsmasq is running.
- **App returns 500s** — a pod can't reach or authenticate to the
  database. Check in order: `dig db.tiket.lab` from a web (dnsmasq up?),
  `systemctl status postgresql` on db, and the `pg_hba` rules in
  `/etc/postgresql/15/main/pg_hba.conf` (the app's IP must match a `host
  tiketdb tiket` line).
- **App 500s "out of nowhere" after hours of uptime** — DHCP lease renewal
  rewrites the webs' resolv.conf with the NAT resolver, dropping the lab
  nameservers. The playbook installs a no-op hook at
  `/etc/dhcp/dhclient-enter-hooks.d/tiket-dns` (`make_resolv_conf() { :; }`)
  on cp and the webs so resolv.conf stays exactly as Ansible wrote it.
- **`Attempting to decrypt but no vault password found` / provision
  aborts on `group_vars/all/vault.yml`** — `~/.vault-tiket-lab` is missing
  (fresh clone, new machine). Recreate it with the same content, or
  re-encrypt the vault file with a new password (see Secrets). A
  vault-password file under `/mnt/c` will never work — see Secrets for why.
- **RAM** — cp runs at 3 GB (k3s server + ArgoCD + HAProxy + CoreDNS),
  the webs at 1 GB each; lower `vb.memory` in the Vagrantfile if the host
  is tight (the db VM is the other candidate, then trim ArgoCD's
  non-essential controllers).

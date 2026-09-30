Vagrant.configure("2") do |config|
  config.vm.box = "generic/debian12"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 1024
    vb.cpus = 1
  end

  # The private network is guest-to-guest only (cp's HAProxy fronts the app NodePort on the webs).
  # Host-to-guest SSH goes over fixed NAT forwards on 127.0.0.1: WSL runs in
  # mirrored networking mode, where localhost is shared with Windows but
  # VirtualBox's 192.168.56.x host-only subnet has no route from WSL. The
  # fixed ports also keep the addresses stable for the static Ansible
  # inventory (Vagrant's default 2222/2200 forwards shift on collisions).
  wsl = Vagrant::Util::Platform.wsl?

  # k3s server + HAProxy + CoreDNS + argoCD
  config.vm.define "cp" do |cp|
    cp.vm.network "private_network", ip: "192.168.56.10"
    cp.vm.hostname = "cp"
    cp.vm.provider "virtualbox" do |vb|
      vb.memory = 3072
    end
    cp.vm.network "forwarded_port", guest: 22, host: 2210, host_ip: "127.0.0.1", auto: false
    cp.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1", auto: false
    # dnsmasq — queryable from WSL with: dig @127.0.0.1 -p 5533 web1.tiket.lab
    # (5533, NOT 5353: Windows mDNS squats UDP 5353 and swallows the packets)
    cp.vm.network "forwarded_port", guest: 53, host: 5533, host_ip: "127.0.0.1", protocol: "udp", auto: false, id: "dns-udp"
    cp.vm.network "forwarded_port", guest: 53, host: 5533, host_ip: "127.0.0.1", protocol: "tcp", auto: false, id: "dns-tcp"
    # ArgoCD UI — HAProxy :8081 frontend → argocd-server NodePort (plain HTTP:
    # argocd-server runs with server.insecure=true, see playbook)
    cp.vm.network "forwarded_port", guest: 8081, host: 8090, host_ip: "127.0.0.1", auto: false
  end

  config.vm.define "web1" do |web1|
    web1.vm.network "private_network", ip: "192.168.56.11"
    web1.vm.hostname = "web1"
    web1.vm.network "forwarded_port", guest: 22, host: 2211, host_ip: "127.0.0.1", auto: false
  end

  config.vm.define "web2" do |web2|
    web2.vm.network "private_network", ip: "192.168.56.12"
    web2.vm.hostname = "web2"
    web2.vm.network "forwarded_port", guest: 22, host: 2212, host_ip: "127.0.0.1", auto: false
  end

  config.vm.define "db" do |db|
    db.vm.network "private_network", ip: "192.168.56.20"
    db.vm.hostname = "db"
    db.vm.network "forwarded_port", guest: 22, host: 2213, host_ip: "127.0.0.1", auto: false
    # psql straight from WSL/Windows through the NAT forward — the password
    # is vault-sealed now; see README "Secrets" for how to read it.
  end

  config.vm.provision "ansible" do |ansible|
    ansible.playbook = "playbook.yml"
    # group_vars/all/vault.yml is ansible-vault encrypted; the vault password
    # lives outside the repo at ~/.vault-tiket-lab (files on /mnt/c are always
    # "+x", which ansible-vault would execute as a password *script*).
    ansible.vault_password_file = File.expand_path("~/.vault-tiket-lab")
    if wsl
      # Vagrant's auto-generated inventory points at keys on /mnt/c, which
      ansible.inventory_path = "ansible_hosts"
    else
      ansible.groups = {
        "controlplane"  => ["cp"],
        "webservers"    => ["web1", "web2"],
        "dbservers"     => ["db"],
      }
    end
  end
end
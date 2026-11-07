# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Dual-stack (IPv4 + IPv6) kubeadm cluster on VirtualBox, Ubuntu 24.04 nodes,
# 1 control plane + N workers, Calico CNI.
#
# Every VM gets a STATIC IPv4 + IPv6 address on a host-only network and ALL
# Kubernetes traffic (API server, kubelet, Calico) is pinned to it. The first
# NIC (VirtualBox NAT, always 10.0.2.15 on every VM) is only used for Vagrant
# SSH and internet access, never for cluster traffic.
#
# Requirements: Vagrant >= 2.4.2 (VirtualBox 7.1) / >= 2.4.9 (VirtualBox 7.2).

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
NUM_WORKER_NODES = Integer(ENV.fetch("NUM_WORKER_NODES", "3"))

# Host-only network for cluster traffic (IPv4).
# 192.168.56.0/21 is allowed for host-only networks unless /etc/vbox/networks.conf says otherwise.
IP_NW           = "192.168.56"
IP_PREFIX       = 24
CONTROLPLANE_IP = "#{IP_NW}.10"
WORKER_IP_START = 20

# IPv6 ULA prefix for the SAME host-only NIC (a /64). Vagrant's VirtualBox
# provider cannot put two address families on one private_network, so the
# IPv6 address is added inside the guest by ubuntu/setup-hosts.sh (netplan).
# Must NOT overlap the IPv6 pod or service ranges below.
IPV6_NW         = "fd00:192:168:56"
IPV6_PREFIX     = 64

# Optional extra bridged NIC so NodePorts are reachable from OTHER machines on
# your LAN. Not needed from this host: the host-only IPs above are reachable.
ENABLE_BRIDGE  = false
BRIDGE_ADAPTER = ENV["BRIDGE_ADAPTER"] # e.g. "eth0" or "en0: Wi-Fi"; unset = auto/ask

KUBE_VERSION   = ""                    # e.g. "v1.35"; empty = latest stable minor (must be >= v1.31)
CALICO_VERSION = "v3.32.2"
METRICS_SERVER_VERSION = ""            # e.g. "v0.9.0"; empty = latest metrics-server release
HELM_VERSION   = ""                    # e.g. "v4.3.0"; empty = latest Helm release
# Optional chart repos added for the vagrant user on kplane: "name=url,name=url"
# e.g. "metrics-server=https://kubernetes-sigs.github.io/metrics-server/,ingress-nginx=https://kubernetes.github.io/ingress-nginx"
HELM_REPOS     = ""

# --- Add-ons installed with Helm once the LAST worker has joined -------------
# MetalLB (L2 mode) hands out LoadBalancer IPs from the host-only network, so
# they are reachable from this host. Keep the pools clear of the node IPs
# (.10, .21+) and of any VirtualBox DHCP range you use on this network.
METALLB_VERSION = ""                   # chart version, e.g. "0.15.2"; empty = latest
METALLB_POOL_V4 = "#{IP_NW}.200-#{IP_NW}.220"
METALLB_POOL_V6 = "#{IPV6_NW}::200-#{IPV6_NW}::220"

# Traefik ingress controller, exposed as a dual-stack LoadBalancer on fixed IPs
# taken from the MetalLB pool above (http://192.168.56.200 from the host).
TRAEFIK_VERSION = ""                   # chart version; empty = latest
TRAEFIK_LB_IPS  = "#{IP_NW}.200,#{IPV6_NW}::200"

# Observability: Prometheus + Grafana (metrics), Loki + Alloy (logs from pods,
# node journals and Kubernetes events), on a local-path default StorageClass.
# Turn off for a smaller cluster: ENABLE_OBSERVABILITY=false vagrant up
ENABLE_OBSERVABILITY = !%w[0 false no].include?(ENV.fetch("ENABLE_OBSERVABILITY", "true").downcase)
LOCAL_PATH_VERSION   = "v0.0.35"       # rancher/local-path-provisioner release
# Grafana/Prometheus hostnames: grafana.<OBS_DOMAIN>, prometheus.<OBS_DOMAIN>.
# nip.io resolves "<anything>.192.168.56.200.nip.io" to 192.168.56.200 (Traefik).
OBS_DOMAIN     = "#{TRAEFIK_LB_IPS.split(',').first}.nip.io"
KPS_VERSION    = ""                    # kube-prometheus-stack chart version; empty = latest
LOKI_VERSION   = ""                    # loki chart version; empty = latest
ALLOY_VERSION  = ""                    # alloy chart version; empty = latest
PROM_RETENTION = "3d"
LOKI_RETENTION = "72h"

# Dual-stack ranges: "<IPv4>,<IPv6>" (IPv4 first = primary family).
POD_CIDR       = "10.244.0.0/16,fd00:10:244::/56"
SERVICE_CIDR   = "10.96.0.0/16,fd00:10:96::/112"

# Total = CP + NUM_WORKER_NODES x WORKER. Defaults: 11 GB RAM with the
# observability stack (3 GB workers), 8 GB without it (2 GB workers). Leave the
# host at least ~2-4 GB free: if it runs out, the last VM to boot hangs at
# "Waiting for machine to boot". Override without editing, e.g.:
#   NUM_WORKER_NODES=2 WORKER_MEMORY=3072 vagrant up
CP_CPUS       = Integer(ENV.fetch("CP_CPUS",       "4"))
CP_MEMORY     = Integer(ENV.fetch("CP_MEMORY",     "4096"))
WORKER_CPUS   = Integer(ENV.fetch("WORKER_CPUS",   "4"))
WORKER_MEMORY = Integer(ENV.fetch("WORKER_MEMORY", ENABLE_OBSERVABILITY ? "4096" : "3072"))

# VB_GUI=1 vagrant up kwn03   -> open the VM console window to see where boot stops
VB_GUI = %w[1 true yes].include?(ENV.fetch("VB_GUI", "").downcase)

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------
NODES = [
  { 
    name: "kplane", 
    ip: CONTROLPLANE_IP, 
    cpus: CP_CPUS, 
    memory: CP_MEMORY, 
    controlplane: true 
  }
] + (1..NUM_WORKER_NODES).map do |i|
  { 
    name: format("kwn%02d", i), 
    ip: "#{IP_NW}.#{WORKER_IP_START + i}",
    cpus: WORKER_CPUS, 
    memory: WORKER_MEMORY,
    controlplane: false
  }
end

# fd00:192:168:56::<last IPv4 octet>, e.g. 192.168.56.21 -> fd00:192:168:56::21
NODES.each { |n| n[:ipv6] = "#{IPV6_NW}::#{n[:ip].split('.').last}" }

# "ip:name,ip:name,..." -> written to /etc/hosts on every node at provision time
CLUSTER_HOSTS = NODES.map { |n| "#{n[:ip]}:#{n[:name]}" }.join(",")

# ---------------------------------------------------------------------------
# Host memory check (only on `vagrant up` / `vagrant reload`)
# ---------------------------------------------------------------------------
# The VMs boot one after another. When the host runs out of RAM, the next VM
# never finishes booting and Vagrant fails after boot_timeout with "Timed out
# while waiting for the machine to boot". Stop before booting anything instead.
# Skip the check with: SKIP_MEMORY_CHECK=1 vagrant up
HOST_RESERVE_MB = 2048   # kept free for the host OS, VirtualBox and your other apps

def host_memory_mb
  case RUBY_PLATFORM
  when /linux/
    File.read("/proc/meminfo")[/^MemTotal:\s+(\d+)/, 1].to_i / 1024
  when /darwin/
    %x{sysctl -n hw.memsize 2>/dev/null}.to_i / 1024 / 1024
  when /mswin|mingw|cygwin/
    %x{powershell -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"}.to_i / 1024 / 1024
  end
rescue StandardError
  nil
end

if (ARGV & %w[up reload]).any? && ENV["SKIP_MEMORY_CHECK"].to_s.empty?
  host_mb = host_memory_mb.to_i
  vm_mb   = NODES.sum { |n| n[:memory] }
  if host_mb > 0
    headroom = host_mb - vm_mb
    summary  = "the #{NODES.length} VMs need #{vm_mb} MB (control plane #{CP_MEMORY} MB + " \
               "#{NUM_WORKER_NODES} x #{WORKER_MEMORY} MB workers), this host has #{host_mb} MB"
    if headroom < HOST_RESERVE_MB
      abort <<~MSG
        [memory] Not enough RAM: #{summary}.
        [memory] The last VMs would hang at "Waiting for machine to boot". Shrink the cluster, e.g.:
        [memory]   NUM_WORKER_NODES=2 vagrant up
        [memory]   WORKER_MEMORY=2048 ENABLE_OBSERVABILITY=false vagrant up
        [memory] (or change the defaults at the top of this Vagrantfile so every command uses them)
        [memory] To ignore this check: SKIP_MEMORY_CHECK=1 vagrant up
      MSG
    elsif headroom < HOST_RESERVE_MB * 2
      warn "[memory] Tight: #{summary}. Close other apps; if a VM hangs while booting, shrink the cluster."
    end
  end
end

def bridge_adapter
  return BRIDGE_ADAPTER if BRIDGE_ADAPTER && !BRIDGE_ADAPTER.empty?
  if RUBY_PLATFORM =~ /linux/
    iface = %x{ip route show default 2>/dev/null | awk 'NR==1 { print $5 }'}.chomp
    return iface unless iface.empty?
  end
  nil # Vagrant will prompt for the adapter
end

Vagrant.configure("2") do |config|
  # Canonical no longer publishes Vagrant boxes for 24.04; bento is the standard.
  config.vm.box              = "bento/ubuntu-24.04"
  config.vm.box_check_update = false
  config.vm.boot_timeout     = 900

  # bento boxes already ship VirtualBox Guest Additions. If the vagrant-vbguest
  # plugin is installed it tries to rebuild them, which needs linux-headers for
  # the box's exact kernel and fails ("has no installation candidate").
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    config.vbguest.no_remote   = true
  end

  # VirtualBox brings machines up one at a time in the order defined below,
  # so the control plane is fully initialised before any worker joins.
  NODES.each_with_index do |n, idx|
    config.vm.define n[:name], primary: n[:controlplane] do |node|
      node.vm.hostname = n[:name]

      # Host-only NIC: Vagrant configures the IPv4 address; IPv6 is added by setup-hosts.sh
      node.vm.network :private_network, ip: n[:ip]

      if ENABLE_BRIDGE
        opts = {}
        adapter = bridge_adapter
        opts[:bridge] = adapter if adapter
        node.vm.network :public_network, **opts
      end

      # node.vm.network "forwarded_port", guest: 30088, host: 30088

      node.vm.provider "virtualbox" do |vb|
        vb.name         = n[:name]
        vb.cpus         = n[:cpus]
        vb.memory       = n[:memory]
        vb.linked_clone = true
        vb.gui          = VB_GUI
        vb.customize ["modifyvm", :id, "--groups", "/klab-cluster"]

        # Make sure the NAT NIC (Vagrant SSH) and host-only NIC are "plugged in".
        # A disconnected virtual cable leaves Vagrant waiting for SSH forever.
        vb.customize ["modifyvm", :id, "--cable-connected1", "on"]
        vb.customize ["modifyvm", :id, "--cable-connected2", "on"]

        # Faster, more reliable NAT DNS and no audio device (avoids boot stalls
        # on hosts without a usable sound backend).
        vb.customize ["modifyvm", :id, "--nat-dns-host-resolver1", "on"]
        vb.customize ["modifyvm", :id, "--audio-enabled", "off"]
    
        # needed later for MetalLB L2 (ARP) to work on the host-only NIC
        vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]
      end

      # --- common provisioning (all nodes) --------------------------------
      node.vm.provision "setup-hosts", type: "shell", path: "ubuntu/setup-hosts.sh",
        env: {
          "NODE_IP"       => n[:ip],
          "NODE_IPV6"     => n[:ipv6],
          "IPV6_PREFIX"   => IPV6_PREFIX.to_s,
          "CLUSTER_HOSTS" => CLUSTER_HOSTS
        }
      node.vm.provision "setup-dns", type: "shell", path: "ubuntu/update-dns.sh"
      node.vm.provision "setup-ssh", type: "shell", path: "ubuntu/ssh.sh"
      node.vm.provision "setup-k8s-node", type: "shell", path: "ubuntu/containerd.sh",
        env: {
          "NODE_IP"      => n[:ip],
          "NODE_IPV6"    => n[:ipv6],
          "KUBE_VERSION" => KUBE_VERSION
        }

      # --- role-specific provisioning -------------------------------------
      if n[:controlplane]
        # Opinionated vim/tmux configs (CKA exam style)
        node.vm.provision "tmux", type: "file", source: "ubuntu/tmux.conf", destination: "/home/vagrant/.tmux.conf"
        node.vm.provision "vim",  type: "file", source: "ubuntu/vimrc",     destination: "/home/vagrant/.vimrc"

        node.vm.provision "kubeadm-init", type: "shell", path: "ubuntu/controlplane.sh",
          env: {
            "NODE_IP"           => n[:ip],
            "NODE_IPV6"         => n[:ipv6],
            "NODE_NETWORK"      => "#{IP_NW}.0/#{IP_PREFIX}",
            "NODE_NETWORK_IPV6" => "#{IPV6_NW}::/#{IPV6_PREFIX}",
            "POD_CIDR"          => POD_CIDR,
            "SERVICE_CIDR"      => SERVICE_CIDR,
            "CALICO_VERSION"    => CALICO_VERSION,
            "METRICS_SERVER_VERSION" => METRICS_SERVER_VERSION
          }

        # Helm CLI on the control plane (re-run alone: vagrant provision kplane --provision-with helm)
        node.vm.provision "setup-helm", type: "shell", path: "ubuntu/helm.sh",
          env: {
            "HELM_VERSION" => HELM_VERSION,
            "HELM_REPOS"   => HELM_REPOS
          }

      else
        node.vm.provision "kubeadm-join", type: "shell", path: "ubuntu/workernode.sh",
          env: {
            "CONTROLPLANE_IP" => CONTROLPLANE_IP,
            # The last worker waits for the Metrics API and runs `kubectl top nodes`
            "LAST_WORKER"     => (idx == NODES.length - 1).to_s
          }

        # Cluster add-ons: only on the LAST worker, i.e. once every node has
        # joined (the control plane is tainted, so these pods need workers).
        # They talk to the API server with the admin kubeconfig in /vagrant.
        # Re-run alone: vagrant provision <last worker> --provision-with install-metallb,install-traefik
        if idx == NODES.length - 1
          # Helm CLI on this worker too (no repos, no smoke test needed here)
          node.vm.provision "setup-helm", type: "shell", path: "ubuntu/helm.sh",
            env: { "HELM_VERSION" => HELM_VERSION, "KUBECONFIG" => "/vagrant/admin.conf" }

          # Install MetalLB using Helm, then its dual-stack address pool
          node.vm.provision "install-metallb", type: "shell", path: "ubuntu/metallb.sh",
            env: {
              "KUBECONFIG"      => "/vagrant/admin.conf",
              "METALLB_VERSION" => METALLB_VERSION,
              "METALLB_POOL_V4" => METALLB_POOL_V4,
              "METALLB_POOL_V6" => METALLB_POOL_V6
            }

          # Install Traefik with Helm (needs MetalLB for its LoadBalancer IPs)
          node.vm.provision "install-traefik", type: "shell", path: "ubuntu/traefik.sh",
            env: {
              "KUBECONFIG"      => "/vagrant/admin.conf",
              "TRAEFIK_VERSION" => TRAEFIK_VERSION,
              "TRAEFIK_LB_IPS"  => TRAEFIK_LB_IPS
            }

          if ENABLE_OBSERVABILITY
            # Default StorageClass for Prometheus / Loki volumes
            node.vm.provision "install-storage", type: "shell", path: "ubuntu/storage.sh",
              env: {
                "KUBECONFIG"         => "/vagrant/admin.conf",
                "LOCAL_PATH_VERSION" => LOCAL_PATH_VERSION
              }

            # Prometheus + Grafana + Loki + Alloy (re-run alone:
            # vagrant provision <last worker> --provision-with install-observability)
            node.vm.provision "install-observability", type: "shell", path: "ubuntu/observability.sh",
              env: {
                "KUBECONFIG"     => "/vagrant/admin.conf",
                "OBS_DOMAIN"     => OBS_DOMAIN,
                "KPS_VERSION"    => KPS_VERSION,
                "LOKI_VERSION"   => LOKI_VERSION,
                "ALLOY_VERSION"  => ALLOY_VERSION,
                "PROM_RETENTION" => PROM_RETENTION,
                "LOKI_RETENTION" => LOKI_RETENTION
              }
          end
        end
      end

      # Final hint once the last node is up
      if idx == NODES.length - 1
        node.trigger.after :up do |t|
          t.info = "Cluster is up. Try: vagrant ssh kplane -c 'kubectl get nodes -o wide; kubectl top nodes'  " \
                   "(or from the host: kubectl --kubeconfig ./admin.conf get nodes). " \
                   "Traefik: http://#{TRAEFIK_LB_IPS.split(',').first}/ (404 until you add an Ingress)" +
                   (ENABLE_OBSERVABILITY ? ". Grafana: http://grafana.#{OBS_DOMAIN}/" : "")
        end
      end
    end
  end
end

# SGX Prover Setup
# Deploys: Intel SGX drivers, PCCS service, Raiko (SGX mode)

locals {
  # Determine actual SGX server IP/user (fall back to main server if not specified)
  sgx_server_ip = var.sgx_server_ip != "" ? var.sgx_server_ip : var.server_ip
  sgx_ssh_user  = var.sgx_ssh_user != "" ? var.sgx_ssh_user : var.ssh_user
  sgx_is_local  = local.sgx_server_ip == var.server_ip
  sgx_home_dir  = local.sgx_ssh_user == "root" ? "/root" : "/home/${local.sgx_ssh_user}"
  sgx_sudo      = local.sgx_ssh_user != "root" ? "sudo " : ""

  sgx_common_infra_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # Verify passwordless sudo for non-root users
    if [ "$(whoami)" != "root" ]; then
      if ! sudo -n true 2>/dev/null; then
        echo "Error: User $(whoami) requires passwordless sudo access."
        exit 1
      fi
    fi

    # OS check
    if [ ! -f /etc/os-release ] || ! grep -q "^ID=ubuntu" /etc/os-release; then
      echo "Error: This script requires Ubuntu."
      exit 1
    fi

    # Architecture check
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
      echo "Error: Requires x86_64 architecture. Detected: $ARCH"
      exit 1
    fi

    wait_for_docker() {
      local max_attempts=30
      local attempt=1
      while [ $attempt -le $max_attempts ]; do
        if ${local.sgx_sudo}docker info > /dev/null 2>&1; then
          return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
      done
      echo "Docker failed to start"
      return 1
    }

    apt_get() {
      while ${local.sgx_sudo}fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
        echo "Waiting for apt lock..."
        sleep 5
      done
      ${local.sgx_sudo}apt-get "$@"
    }

    has_systemd() {
      [ -d /run/systemd/system ]
    }

    service_cmd() {
      local action=$1
      local service=$2
      if has_systemd; then
        ${local.sgx_sudo}systemctl $action $service
      else
        ${local.sgx_sudo}service $service $action 2>/dev/null || true
      fi
    }

    # Install dependencies
    apt_get update
    apt_get install -y -f curl jq git wget net-tools build-essential openssl

    # Docker installation
    if ! ${local.sgx_sudo}docker compose version > /dev/null 2>&1; then
      if dpkg -l | grep -qE "docker-ce|docker\.io|docker-engine"; then
        echo "Docker is installed but not working. Removing..."
        service_cmd stop docker.socket 2>/dev/null || true
        service_cmd stop docker 2>/dev/null || true
        apt_get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt_get purge -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        ${local.sgx_sudo}rm -rf /var/lib/docker /var/lib/containerd
      fi
      apt_get install -y ca-certificates curl
      ${local.sgx_sudo}install -m 0755 -d /etc/apt/keyrings
      ${local.sgx_sudo}curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      ${local.sgx_sudo}chmod a+r /etc/apt/keyrings/docker.asc
      echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | ${local.sgx_sudo}tee /etc/apt/sources.list.d/docker.sources > /dev/null
      apt_get update
      apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      if has_systemd; then
        ${local.sgx_sudo}systemctl enable docker
      fi
      service_cmd start docker
      if [ "$(whoami)" != "root" ]; then
        ${local.sgx_sudo}usermod -aG docker $(whoami)
      fi
      wait_for_docker
    fi

    # Configure Docker daemon
    if [ -f /etc/docker/daemon.json ]; then
      ${local.sgx_sudo}cat /etc/docker/daemon.json | jq '. + {"default-address-pools": [{"base": "10.10.0.0/16", "size": 24}], "bip": "10.20.0.1/16"}' | ${local.sgx_sudo}tee /etc/docker/daemon.json.tmp > /dev/null
      ${local.sgx_sudo}mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    else
      echo '{"default-address-pools": [{"base": "10.10.0.0/16", "size": 24}], "bip": "10.20.0.1/16"}' | ${local.sgx_sudo}tee /etc/docker/daemon.json > /dev/null
    fi

    service_cmd restart docker
    wait_for_docker
    echo "Docker ready on SGX prover server"
  EOT

  sgx_pccs_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    echo "Setting up Intel SGX PCCS..."

    # Create PCCS config directory
    mkdir -p ${local.sgx_home_dir}/.config/sgx-pccs
    cd ${local.sgx_home_dir}/.config/sgx-pccs

    # Fetch Intel collateral (TCB info and QE identity)
    FMSPC="00906ED50000"
    echo "Fetching Intel collateral for FMSPC: $FMSPC"

    curl -s "https://api.trustedservices.intel.com/sgx/certification/v4/tcb?fmspc=$FMSPC" | \
      jq '.fmspc = (.fmspc | ascii_downcase)' > tcb_info.json
    curl -s "https://api.trustedservices.intel.com/sgx/certification/v4/qe/identity" > qe_identity.json

    echo "TCB info and QE identity fetched"

    # Generate PCCS SSL certificates
    if [ ! -f private.pem ]; then
      echo "Generating PCCS SSL certificates..."
      openssl genrsa -out private.pem 2048
      openssl req -new -key private.pem -out csr.pem -subj "/CN=PCCS"
      openssl x509 -req -days 365 -in csr.pem -signkey private.pem -out file.crt
      rm -f csr.pem
      chmod 644 private.pem file.crt
      echo "PCCS certificates generated"
    fi

    # Download default.json configuration from Raiko repository
    if [ ! -f default.json ]; then
      curl -s "https://raw.githubusercontent.com/NethermindEth/raiko/main/docker/config/sgx-pccs/default.json" -o default.json
    fi

    # Configure PCCS with API key if provided
    if [ -n "${var.intel_pccs_api_key}" ]; then
      jq --arg key "${var.intel_pccs_api_key}" '.ApiKey = $key' default.json > default.json.tmp
      mv default.json.tmp default.json
    fi

    echo "Intel SGX PCCS setup complete"
  EOT

  sgx_raiko_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    cd ${local.sgx_home_dir}/raiko

    # Create config.json for SGX mode
    cat > host/config/devnet/config.json <<'SGXCONFIG'
{
  "address": "0.0.0.0:8080",
  "network": "devnet",
  "l1_network": "devnet",
  "concurrency_limit": 4,
  "max_cache_size": 1000,
  "config_path": "/etc/raiko/devnet"
}
SGXCONFIG

    # Setup raiko docker environment for SGX
    cp docker/.env.sample docker/.env

    # Configure environment variables
    sed -i "s|^RAIKO_CONF_DIR=.*|RAIKO_CONF_DIR=${local.sgx_home_dir}/raiko/host/config|" docker/.env
    sed -i "s|^BASE_CONFIG_FILE=.*|BASE_CONFIG_FILE=config.json|" docker/.env
    sed -i "s|^BASE_CHAINSPEC_FILE=.*|BASE_CHAINSPEC_FILE=chain_spec_list.json|" docker/.env
    sed -i "s|^RUST_LOG=.*|RUST_LOG=info|" docker/.env

    # Add config path variables if they don't exist
    grep -q "^RAIKO_CONF_DIR=" docker/.env || echo "RAIKO_CONF_DIR=${local.sgx_home_dir}/raiko/host/config" >> docker/.env
    grep -q "^BASE_CONFIG_FILE=" docker/.env || echo "BASE_CONFIG_FILE=config.json" >> docker/.env
    grep -q "^BASE_CHAINSPEC_FILE=" docker/.env || echo "BASE_CHAINSPEC_FILE=chain_spec_list.json" >> docker/.env
    grep -q "^PCCS_HOST=" docker/.env || echo "PCCS_HOST=${local.sgx_home_dir}/.config/sgx-pccs" >> docker/.env

    # Set SGX instance IDs
    grep -q "^SGX_INSTANCE_ID=" docker/.env || echo "SGX_INSTANCE_ID=1" >> docker/.env
    grep -q "^SGXGETH_INSTANCE_ID=" docker/.env || echo "SGXGETH_INSTANCE_ID=1" >> docker/.env

    echo "Raiko SGX configuration complete"

    # Initialize and start Raiko in SGX mode
    cd docker
    ${local.sgx_sudo}docker compose up init || true
    ${local.sgx_sudo}docker compose up raiko -d --force-recreate

    echo "Raiko SGX containers started on port 8080"
  EOT
}

# Common infrastructure setup (only for remote SGX prover server)
resource "null_resource" "sgx_prover_infra" {
  count = local.sgx_is_local ? 0 : 1

  triggers = {
    sgx_server_ip = local.sgx_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.sgx_ssh_user
    host        = local.sgx_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.sgx_common_infra_script]
  }
}

# Intel PCCS setup
resource "null_resource" "sgx_prover_pccs" {
  depends_on = [null_resource.sgx_prover_infra]

  triggers = {
    sgx_server_ip = local.sgx_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.sgx_ssh_user
    host        = local.sgx_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.sgx_pccs_script]
  }
}

# Clone raiko and prepare directory for config uploads
resource "null_resource" "sgx_prover_raiko_clone" {
  depends_on = [null_resource.sgx_prover_pccs]

  triggers = {
    sgx_server_ip = local.sgx_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.sgx_ssh_user
    host        = local.sgx_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      RAIKO_TAG="v25.1.0-surge"
      cd ${local.sgx_home_dir}
      if [ ! -d raiko ]; then
        git clone https://github.com/NethermindEth/raiko.git
      fi
      cd raiko
      git fetch origin
      git checkout $RAIKO_TAG
      mkdir -p host/config/devnet
      echo "Raiko cloned and ready for config upload"
    EOT
    ]
  }
}

# Upload config files (depends on extract_config_files from main.tf)
resource "null_resource" "sgx_prover_raiko_config" {
  depends_on = [
    null_resource.sgx_prover_raiko_clone,
    null_resource.extract_config_files
  ]

  triggers = {
    sgx_server_ip = local.sgx_server_ip
    config_hash   = fileexists("${path.module}/files/chain_spec_list.json") ? filesha256("${path.module}/files/chain_spec_list.json") : "pending"
  }

  connection {
    type        = "ssh"
    user        = local.sgx_ssh_user
    host        = local.sgx_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  # Upload chain_spec_list.json to correct location
  provisioner "file" {
    source      = "${path.module}/files/chain_spec_list.json"
    destination = "${local.sgx_home_dir}/raiko/host/config/devnet/chain_spec_list.json"
  }

  # Upload deploy_l1.json for reference
  provisioner "file" {
    source      = "${path.module}/files/deploy_l1.json"
    destination = "${local.sgx_home_dir}/raiko/host/config/devnet/deploy_l1.json"
  }
}

# Start Raiko SGX mode
resource "null_resource" "sgx_prover_raiko" {
  depends_on = [null_resource.sgx_prover_raiko_config]

  triggers = {
    sgx_server_ip = local.sgx_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.sgx_ssh_user
    host        = local.sgx_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.sgx_raiko_script]
  }
}

output "sgx_prover_endpoint" {
  description = "SGX prover Raiko API endpoint"
  value       = "http://${local.sgx_server_ip}:8080"
}

# RISC/ZK Prover Setup
# Deploys: CUDA 13.0.1, NVIDIA Container Toolkit, Bonsai Bento, Raiko (ZK mode)

locals {
  # Determine actual RISC server IP/user (fall back to main server if not specified)
  risc_server_ip = var.risc_server_ip != "" ? var.risc_server_ip : var.server_ip
  risc_ssh_user  = var.risc_ssh_user != "" ? var.risc_ssh_user : var.ssh_user
  risc_is_local  = local.risc_server_ip == var.server_ip
  risc_home_dir  = local.risc_ssh_user == "root" ? "/root" : "/home/${local.risc_ssh_user}"
  risc_sudo      = local.risc_ssh_user != "root" ? "sudo " : ""

  risc_common_infra_script = <<-EOT
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
        if ${local.risc_sudo}docker info > /dev/null 2>&1; then
          return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
      done
      echo "Docker failed to start"
      return 1
    }

    apt_get() {
      while ${local.risc_sudo}fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
        echo "Waiting for apt lock..."
        sleep 5
      done
      ${local.risc_sudo}apt-get "$@"
    }

    has_systemd() {
      [ -d /run/systemd/system ]
    }

    service_cmd() {
      local action=$1
      local service=$2
      if has_systemd; then
        ${local.risc_sudo}systemctl $action $service
      else
        ${local.risc_sudo}service $service $action 2>/dev/null || true
      fi
    }

    # Install dependencies
    apt_get update
    apt_get install -y -f curl jq git wget net-tools build-essential

    # Docker installation (with cleanup of broken installations)
    if ! ${local.risc_sudo}docker compose version > /dev/null 2>&1; then
      if dpkg -l | grep -qE "docker-ce|docker\.io|docker-engine"; then
        echo "Docker is installed but not working. Removing..."
        service_cmd stop docker.socket 2>/dev/null || true
        service_cmd stop docker 2>/dev/null || true
        apt_get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt_get purge -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        ${local.risc_sudo}rm -rf /var/lib/docker /var/lib/containerd
      fi
      apt_get install -y ca-certificates curl
      ${local.risc_sudo}install -m 0755 -d /etc/apt/keyrings
      ${local.risc_sudo}curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      ${local.risc_sudo}chmod a+r /etc/apt/keyrings/docker.asc
      echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | ${local.risc_sudo}tee /etc/apt/sources.list.d/docker.sources > /dev/null
      apt_get update
      apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      if has_systemd; then
        ${local.risc_sudo}systemctl enable docker
      fi
      service_cmd start docker
      if [ "$(whoami)" != "root" ]; then
        ${local.risc_sudo}usermod -aG docker $(whoami)
      fi
      wait_for_docker
    fi

    service_cmd start docker
    wait_for_docker
    echo "Docker ready on RISC prover server"
  EOT

  risc_cuda_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    apt_get() {
      while ${local.risc_sudo}fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
        sleep 5
      done
      ${local.risc_sudo}apt-get "$@"
    }

    has_systemd() {
      [ -d /run/systemd/system ]
    }

    service_cmd() {
      local action=$1
      local service=$2
      if has_systemd; then
        ${local.risc_sudo}systemctl $action $service
      else
        ${local.risc_sudo}service $service $action 2>/dev/null || true
      fi
    }

    wait_for_docker() {
      local max_attempts=30
      local attempt=1
      while [ $attempt -le $max_attempts ]; do
        if ${local.risc_sudo}docker info > /dev/null 2>&1; then
          return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
      done
      return 1
    }

    # CUDA 13.0.1 installation
    if [ ! -x /usr/local/cuda/bin/nvcc ]; then
      echo "Installing CUDA 13.0.1..."
      rm -rf /tmp/cuda
      mkdir -p /tmp/cuda
      cd /tmp/cuda
      wget --progress=dot:giga https://developer.download.nvidia.com/compute/cuda/13.0.1/local_installers/cuda_13.0.1_580.82.07_linux.run
      ${local.risc_sudo}sh cuda_13.0.1_580.82.07_linux.run --silent --toolkit
      rm -rf /tmp/cuda
      echo "CUDA 13.0.1 installed!"
    else
      echo "CUDA already installed, skipping..."
    fi

    grep -qxF 'export PATH="/usr/local/cuda/bin:$PATH"' ${local.risc_home_dir}/.profile || echo 'export PATH="/usr/local/cuda/bin:$PATH"' >> ${local.risc_home_dir}/.profile
    grep -qxF 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' ${local.risc_home_dir}/.profile || echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' >> ${local.risc_home_dir}/.profile
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

    # NVIDIA Container Toolkit
    if ! dpkg -l | grep -q nvidia-container-toolkit; then
      echo "Installing NVIDIA Container Toolkit..."
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | ${local.risc_sudo}gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        ${local.risc_sudo}tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt_get update
      apt_get install -y nvidia-container-toolkit
      echo "NVIDIA Container Toolkit installed!"
    fi
    ${local.risc_sudo}nvidia-ctk runtime configure --runtime=docker

    # Configure Docker daemon for GPU support
    if [ -f /etc/docker/daemon.json ]; then
      ${local.risc_sudo}cat /etc/docker/daemon.json | jq '. + {"default-address-pools": [{"base": "10.10.0.0/16", "size": 24}], "bip": "10.20.0.1/16"}' | ${local.risc_sudo}tee /etc/docker/daemon.json.tmp > /dev/null
      ${local.risc_sudo}mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    else
      echo '{"default-address-pools": [{"base": "10.10.0.0/16", "size": 24}], "bip": "10.20.0.1/16"}' | ${local.risc_sudo}tee /etc/docker/daemon.json > /dev/null
    fi

    service_cmd restart docker
    wait_for_docker
    echo "CUDA and NVIDIA Container Toolkit ready"
  EOT

  risc_bento_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    cd ${local.risc_home_dir}
    echo "Setting up Bonsai Bento..."
    if [ ! -d risc0-bento ]; then
      git clone https://github.com/NethermindEth/risc0-bento.git
    fi
    cd risc0-bento
    git fetch origin
    git checkout main
    cp bento/dockerfiles/sample.env ./sample.env
    sed -i 's/[0-9]*8081:8081/58081:8081/g' compose.yml
    ${local.risc_sudo}fuser -k 58081/tcp 2>/dev/null || true
    ${local.risc_sudo}docker compose --file compose.yml --env-file sample.env up -d --build
    echo "Bonsai Bento started on port 58081"
  EOT

  risc_raiko_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # Read verifier addresses from uploaded deploy_l1.json
    RISC0_GROTH16_VERIFIER=$(cat ${local.risc_home_dir}/raiko/host/config/devnet/deploy_l1.json | jq -r '.risc0_groth16_verifier')
    SP1_RETH_VERIFIER=$(cat ${local.risc_home_dir}/raiko/host/config/devnet/deploy_l1.json | jq -r '.sp1_reth_verifier')
    echo "Extracted RISC0_GROTH16_VERIFIER: $RISC0_GROTH16_VERIFIER"
    echo "Extracted SP1_RETH_VERIFIER: $SP1_RETH_VERIFIER"

    cd ${local.risc_home_dir}/raiko

    # Setup raiko docker environment
    cp docker/.env.sample.zk docker/.env

    # Configure environment variables in raiko's .env
    sed -i "s|^BONSAI_API_URL=.*|BONSAI_API_URL=http://localhost:58081|" docker/.env
    sed -i "s|^SP1_VERIFIER_ADDRESS=.*|SP1_VERIFIER_ADDRESS=$SP1_RETH_VERIFIER|" docker/.env
    sed -i "s|^GROTH16_VERIFIER_ADDRESS=.*|GROTH16_VERIFIER_ADDRESS=$RISC0_GROTH16_VERIFIER|" docker/.env

    # Add variables if they don't exist
    grep -q "^BONSAI_API_URL=" docker/.env || echo "BONSAI_API_URL=http://localhost:58081" >> docker/.env
    grep -q "^SP1_VERIFIER_ADDRESS=" docker/.env || echo "SP1_VERIFIER_ADDRESS=$SP1_RETH_VERIFIER" >> docker/.env
    grep -q "^GROTH16_VERIFIER_ADDRESS=" docker/.env || echo "GROTH16_VERIFIER_ADDRESS=$RISC0_GROTH16_VERIFIER" >> docker/.env

    # Update raiko docker image tag
    RAIKO_TAG="v25.1.0-surge"
    sed -i "s/:latest/:$RAIKO_TAG/g" docker/docker-compose-zk.yml

    # Start raiko docker containers
    cd docker
    ${local.risc_sudo}docker compose -f docker-compose-zk.yml up -d --force-recreate

    echo "Raiko ZK containers started on port 8080"
  EOT
}

# Common infrastructure setup (only for remote RISC prover server)
resource "null_resource" "risc_prover_infra" {
  count = local.risc_is_local ? 0 : 1

  triggers = {
    risc_server_ip = local.risc_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.risc_ssh_user
    host        = local.risc_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.risc_common_infra_script]
  }
}

# CUDA and NVIDIA Container Toolkit setup
resource "null_resource" "risc_prover_cuda" {
  depends_on = [null_resource.risc_prover_infra]

  triggers = {
    risc_server_ip = local.risc_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.risc_ssh_user
    host        = local.risc_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.risc_cuda_script]
  }
}

# Bonsai Bento setup
resource "null_resource" "risc_prover_bento" {
  depends_on = [null_resource.risc_prover_cuda]

  triggers = {
    risc_server_ip = local.risc_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.risc_ssh_user
    host        = local.risc_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.risc_bento_script]
  }
}

# Clone raiko and prepare directory for config uploads
resource "null_resource" "risc_prover_raiko_clone" {
  depends_on = [null_resource.risc_prover_bento]

  triggers = {
    risc_server_ip = local.risc_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.risc_ssh_user
    host        = local.risc_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      RAIKO_TAG="v25.1.0-surge"
      cd ${local.risc_home_dir}
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
resource "null_resource" "risc_prover_raiko_config" {
  depends_on = [
    null_resource.risc_prover_raiko_clone,
    null_resource.extract_config_files
  ]

  triggers = {
    risc_server_ip = local.risc_server_ip
    config_hash    = fileexists("${path.module}/files/chain_spec_list.json") ? filesha256("${path.module}/files/chain_spec_list.json") : "pending"
  }

  connection {
    type        = "ssh"
    user        = local.risc_ssh_user
    host        = local.risc_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  # Upload chain_spec_list.json to correct location
  provisioner "file" {
    source      = "${path.module}/files/chain_spec_list.json"
    destination = "${local.risc_home_dir}/raiko/host/config/devnet/chain_spec_list.json"
  }

  # Upload deploy_l1.json for verifier address extraction
  provisioner "file" {
    source      = "${path.module}/files/deploy_l1.json"
    destination = "${local.risc_home_dir}/raiko/host/config/devnet/deploy_l1.json"
  }
}

# Start Raiko ZK mode
resource "null_resource" "risc_prover_raiko" {
  depends_on = [null_resource.risc_prover_raiko_config]

  triggers = {
    risc_server_ip = local.risc_server_ip
  }

  connection {
    type        = "ssh"
    user        = local.risc_ssh_user
    host        = local.risc_server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.risc_raiko_script]
  }
}

output "risc_prover_endpoint" {
  description = "RISC prover Raiko API endpoint"
  value       = "http://${local.risc_server_ip}:8080"
}

output "risc_prover_bonsai_endpoint" {
  description = "RISC prover Bonsai API endpoint"
  value       = "http://${local.risc_server_ip}:58081"
}

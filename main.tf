terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

variable "server_ip" {
  description = "Target server IP address"
  type        = string
}

variable "ssh_user" {
  description = "SSH username"
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "redeploy_devnet" {
  description = "If true, remove and redeploy existing surge-devnet"
  type        = bool
  default     = false
}

locals {
  sudo     = var.ssh_user != "root" ? "sudo " : ""
  home_dir = var.ssh_user == "root" ? "/root" : "/home/${var.ssh_user}"

  setup_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # OS check
    if [ ! -f /etc/os-release ] || ! grep -q "^ID=ubuntu" /etc/os-release; then
      echo "Error: This script requires Ubuntu. Detected: $(cat /etc/os-release 2>/dev/null | grep ^ID= || echo 'unknown')"
      exit 1
    fi
    echo "OS check passed: Ubuntu"

    # Architecture check
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
      echo "Error: Requires x86_64 architecture. Detected: $ARCH"
      exit 1
    fi
    echo "Architecture check passed: $ARCH"

    # Install dependencies
    ${local.sudo}apt-get update
    ${local.sudo}apt-get install -y curl jq git wget

    # Docker installation (idempotent)
    if ! command -v docker > /dev/null 2>&1; then
      ${local.sudo}apt-get install -y ca-certificates curl
      ${local.sudo}install -m 0755 -d /etc/apt/keyrings
      ${local.sudo}curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      ${local.sudo}chmod a+r /etc/apt/keyrings/docker.asc
      echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | ${local.sudo}tee /etc/apt/sources.list.d/docker.sources > /dev/null
      ${local.sudo}apt-get update
      ${local.sudo}apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    ${local.sudo}systemctl enable docker
    ${local.sudo}systemctl start docker

    # CUDA 13.0.1 installation (conditional)
    if ! command -v nvcc > /dev/null 2>&1; then
      cd /tmp
      wget -q https://developer.download.nvidia.com/compute/cuda/13.0.1/local_installers/cuda_13.0.1_580.82.07_linux.run
      ${local.sudo}sh cuda_13.0.1_580.82.07_linux.run --silent --toolkit
      rm cuda_13.0.1_580.82.07_linux.run
    fi
    grep -qxF 'export PATH="/usr/local/cuda/bin:$PATH"' ${local.home_dir}/.bashrc || echo 'export PATH="/usr/local/cuda/bin:$PATH"' >> ${local.home_dir}/.bashrc
    grep -qxF 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' ${local.home_dir}/.bashrc || echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' >> ${local.home_dir}/.bashrc
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

    # NVIDIA Container Toolkit (for Docker GPU support)
    if ! dpkg -l | grep -q nvidia-container-toolkit; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | ${local.sudo}gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        ${local.sudo}tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      ${local.sudo}apt-get update
      ${local.sudo}apt-get install -y nvidia-container-toolkit
      ${local.sudo}nvidia-ctk runtime configure --runtime=docker
      ${local.sudo}systemctl restart docker
    fi

    # Kurtosis installation (idempotent)
    if ! command -v kurtosis > /dev/null 2>&1; then
      echo 'deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /' | ${local.sudo}tee /etc/apt/sources.list.d/kurtosis.list
      ${local.sudo}apt-get update
      ${local.sudo}apt-get install -y kurtosis-cli
    fi
    kurtosis analytics disable || true
    echo "" | kurtosis engine start || true

    # UFW firewall setup
    ${local.sudo}apt-get install -y ufw
    ${local.sudo}ufw default deny incoming
    ${local.sudo}ufw default allow outgoing
    ${local.sudo}ufw allow ssh
    echo "y" | ${local.sudo}ufw enable

    # Clone Surge repo
    cd ${local.home_dir}
    if [ ! -d surge-ethereum-package ]; then
      git clone https://github.com/NethermindEth/surge-ethereum-package.git
    fi
    cd surge-ethereum-package
    git pull

    # Check if devnet already exists
    if kurtosis enclave ls 2>/dev/null | grep -q "surge-devnet"; then
      if [ "${var.redeploy_devnet}" = "true" ]; then
        echo "Removing existing surge-devnet..."
        ./remove-surge-devnet-l1.sh --force
      else
        echo "Surge devnet already exists. Skipping deployment."
        echo "Set redeploy_devnet=true to redeploy."
        echo "Surge devnet L1 deployment complete!"
        exit 0
      fi
    fi

    # Deploy Surge L1
    ./deploy-surge-devnet-l1.sh --environment remote --mode silence

    echo "Surge devnet L1 deployment complete!"
  EOT
}

resource "null_resource" "surge_devnet_l1" {
  triggers = {
    server_ip = var.server_ip
  }

  connection {
    type        = "ssh"
    user        = var.ssh_user
    host        = var.server_ip
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.setup_script]
  }
}

resource "local_file" "setup_tunnel" {
  filename        = "${path.module}/setup-tunnel.sh"
  file_permission = "0755"
  content         = <<-EOT
    #!/bin/bash
    # SSH tunnel for Surge devnet endpoints
    # Generated by OpenTofu - Run this to access devnet from your local machine

    echo "Starting SSH tunnel to ${var.server_ip}..."
    echo "Forwarding ports: 32003, 32004, 33001, 36005, 36000"
    echo "Press Ctrl+C to stop"
    echo ""

    ssh -N \
      -L 32003:localhost:32003 \
      -L 32004:localhost:32004 \
      -L 33001:localhost:33001 \
      -L 36005:localhost:36005 \
      -L 36000:localhost:36000 \
      -i ${var.ssh_private_key_path} \
      ${var.ssh_user}@${var.server_ip}
  EOT
}

output "surge_endpoints" {
  description = "Surge devnet L1 service endpoints (access via SSH tunnel)"
  value = {
    execution_rpc       = "http://localhost:32003"
    execution_ws        = "ws://localhost:32004"
    consensus_api       = "http://localhost:33001"
    block_explorer      = "http://localhost:36005"
    transaction_spammer = "http://localhost:36000"
  }
}

output "tunnel_script" {
  description = "Run this script to create SSH tunnel for local access"
  value       = "./setup-tunnel.sh"
}

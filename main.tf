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

variable "ssh_port" {
  description = "SSH port"
  type        = number
  default     = 22
}

variable "redeploy_devnet" {
  description = "If true, remove and redeploy existing surge-devnet"
  type        = bool
  default     = false
}

locals {
  sudo     = var.ssh_user != "root" ? "sudo " : ""
  home_dir = var.ssh_user == "root" ? "/root" : "/home/${var.ssh_user}"

  # Smart contract verifier solidity compiler URLs
  solidity_list_url     = "https://binaries.soliditylang.org/linux-amd64/list.json"
  era_solidity_list_url = "https://raw.githubusercontent.com/blockscout/solc-bin/main/era-solidity.linux-amd64.list.json"
  zksolc_list_url       = "https://raw.githubusercontent.com/blockscout/solc-bin/main/zksolc.linux-amd64.list.json"

  setup_script = <<-EOT
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # Verify passwordless sudo for non-root users
    if [ "$(whoami)" != "root" ]; then
      if ! sudo -n true 2>/dev/null; then
        echo "Error: User $(whoami) requires passwordless sudo access."
        echo "Run on the remote server:"
        echo "  echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$(whoami)"
        echo "  sudo chmod 440 /etc/sudoers.d/$(whoami)"
        exit 1
      fi
      echo "Passwordless sudo check passed"
    fi

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

    wait_for_docker() {
      local max_attempts=30
      local attempt=1
      while [ $attempt -le $max_attempts ]; do
        if ${local.sudo}docker info > /dev/null 2>&1; then
          return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
      done
      echo "Docker failed to start"
      return 1
    }

    apt_get() {
      while ${local.sudo}fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
        echo "Waiting for apt lock..."
        sleep 5
      done
      ${local.sudo}apt-get "$@"
    }

    has_systemd() {
      [ -d /run/systemd/system ]
    }

    service_cmd() {
      local action=$1
      local service=$2
      if has_systemd; then
        ${local.sudo}systemctl $action $service
      else
        ${local.sudo}service $service $action 2>/dev/null || true
      fi
    }

    remove_existing_docker() {
      service_cmd stop docker.socket 2>/dev/null || true
      service_cmd stop docker 2>/dev/null || true
      service_cmd stop containerd 2>/dev/null || true
      apt_get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker docker-engine docker.io containerd runc 2>/dev/null || true
      apt_get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker docker-engine docker.io containerd runc 2>/dev/null || true
      apt_get autoremove -y 2>/dev/null || true
      ${local.sudo}rm -rf /var/lib/docker /var/lib/containerd
      ${local.sudo}rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/docker.list
      ${local.sudo}rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
      apt_get update
    }

    # Install dependencies
    apt_get update
    apt_get install -y -f curl jq git wget net-tools build-essential

    # Docker installation (with cleanup of broken installations)
    if ! ${local.sudo}docker compose version > /dev/null 2>&1; then
      if dpkg -l | grep -qE "docker-ce|docker\.io|docker-engine"; then
        echo "Docker is installed but not working. Removing existing installation..."
        remove_existing_docker
      fi
      apt_get install -y ca-certificates curl
      ${local.sudo}install -m 0755 -d /etc/apt/keyrings
      ${local.sudo}curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      ${local.sudo}chmod a+r /etc/apt/keyrings/docker.asc
      echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | ${local.sudo}tee /etc/apt/sources.list.d/docker.sources > /dev/null
      apt_get update
      apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      if has_systemd; then
        ${local.sudo}systemctl enable docker
      fi
      service_cmd start docker
      if [ "$(whoami)" != "root" ]; then
        ${local.sudo}usermod -aG docker $(whoami)
      fi
      wait_for_docker
    fi


    # Ensure Docker daemon is running
    echo "Starting Docker daemon..."
    service_cmd start docker
    echo "Waiting for Docker daemon to start..."
    wait_for_docker
    echo "Docker daemon started!"

    # CUDA 13.0.1 installation (conditional)
    if [ ! -x /usr/local/cuda/bin/nvcc ]; then
      echo "Installing CUDA 13.0.1..."
      rm -rf /tmp/cuda
      mkdir -p /tmp/cuda
      cd /tmp/cuda
      wget -q https://developer.download.nvidia.com/compute/cuda/13.0.1/local_installers/cuda_13.0.1_580.82.07_linux.run
      ${local.sudo}sh cuda_13.0.1_580.82.07_linux.run --silent --toolkit
      rm -rf /tmp/cuda
      echo "CUDA 13.0.1 installed!"
    fi
    grep -qxF 'export PATH="/usr/local/cuda/bin:$PATH"' ${local.home_dir}/.profile || echo 'export PATH="/usr/local/cuda/bin:$PATH"' >> ${local.home_dir}/.profile
    grep -qxF 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' ${local.home_dir}/.profile || echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' >> ${local.home_dir}/.profile
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

    # NVIDIA Container Toolkit (for Docker GPU support)
    if ! dpkg -l | grep -q nvidia-container-toolkit; then\
      echo "Installing NVIDIA Container Toolkit..."
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | ${local.sudo}gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        ${local.sudo}tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt_get update
      apt_get install -y nvidia-container-toolkit
      echo "NVIDIA Container Toolkit installed!"
    fi
    ${local.sudo}nvidia-ctk runtime configure --runtime=docker

    echo "Restarting Docker daemon..."  
    service_cmd restart docker
    echo "Waiting for Docker daemon to restart..."
    wait_for_docker
    echo "Docker daemon restarted!"

    # Kurtosis installation (idempotent)
    if ! command -v kurtosis > /dev/null 2>&1; then
      echo 'deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /' | ${local.sudo}tee /etc/apt/sources.list.d/kurtosis.list
      apt_get update
      apt_get install -y kurtosis-cli
    fi
    ${local.sudo}kurtosis analytics disable || true
    if ! ${local.sudo}kurtosis engine status 2>/dev/null | grep -q "RUNNING"; then
      echo "Starting Kurtosis engine..."
      sleep 5
      echo "" | ${local.sudo}kurtosis engine start || true
      echo "Kurtosis engine started!"
    fi

    # UFW firewall setup
    echo "Installing UFW..."
    apt_get install -y ufw
    ${local.sudo}ufw default deny incoming
    ${local.sudo}ufw default allow outgoing
    ${local.sudo}ufw allow ssh
    echo "y" | ${local.sudo}ufw enable
    echo "UFW enabled!"

    # Configure SSH for extensive port forwarding
    if ! grep -q "^MaxSessions 100" /etc/ssh/sshd_config; then
      echo "Configuring SSH for extensive port forwarding..."
      echo "MaxSessions 100" | ${local.sudo}tee -a /etc/ssh/sshd_config
      echo "Restarting SSH daemon..."
      service_cmd restart sshd
      echo "SSH daemon restarted!"
    fi

    # Clone Surge repo
    cd ${local.home_dir}
    if [ ! -d surge-ethereum-package ]; then
      git clone https://github.com/ensdomains/surge-ethereum-package.git
    fi
    cd surge-ethereum-package
    git fetch origin
    git checkout 94043d085b3365a1fd0f3dd73246bcb826dc9dad

    # Add smart contract verifier env vars to L1 blockscout
    sed -i '/HTTP_PORT_NUMBER_VERIF/{n;s/)$/),/}' src/blockscout/blockscout_launcher.star
    sed -i '/^        },/i\            "SMART_CONTRACT_VERIFIER__SOLIDITY__FETCHER__LIST__LIST_URL": "${local.solidity_list_url}",\n            "SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__EVM_FETCHER__LIST__LIST_URL": "${local.solidity_list_url}",\n            "SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__ERA_EVM_FETCHER__LIST__LIST_URL": "${local.era_solidity_list_url}",\n            "SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__ZK_FETCHER__LIST__LIST_URL": "${local.zksolc_list_url}"' src/blockscout/blockscout_launcher.star

    # Check if devnet already exists
    if ${local.sudo}kurtosis enclave ls 2>/dev/null | grep -q "surge-devnet"; then
      echo "Surge devnet already exists."
      if [ "${var.redeploy_devnet}" = "true" ]; then
        echo "Removing existing surge-devnet..."
        ${local.sudo}./remove-surge-devnet-l1.sh --force
        echo "Surge devnet removed!"
      else
        echo "Surge devnet already exists. Skipping deployment."
        echo "Set redeploy_devnet=true to redeploy."
        echo "Surge devnet L1 deployment complete!"
        exit 0
      fi
    fi

    # Deploy Surge L1
    echo "Deploying Surge L1..."
    ${local.sudo}./deploy-surge-devnet-l1.sh --environment remote --mode silence  
    echo "Surge devnet L1 deployment complete!"

    # Setup Bonsai Bento
    cd ${local.home_dir}
    echo "Setting up Bonsai Bento..."
    if [ ! -d risc0-bento ]; then
      git clone https://github.com/NethermindEth/risc0-bento.git
    fi
    cd risc0-bento
    git fetch origin
    git checkout main
    cp bento/dockerfiles/sample.env ./sample.env
    sed -i 's/[0-9]*8081:8081/58081:8081/g' compose.yml
    ${local.sudo}fuser -k 58081/tcp 2>/dev/null || true
    ${local.sudo}docker compose --file compose.yml --env-file sample.env up -d --build

    # Clone simple-surge-node repo for L2 deployment
    cd ${local.home_dir}
    if [ ! -d simple-surge-node ]; then
      git clone https://github.com/ensdomains/simple-surge-node.git
    fi
    cd simple-surge-node
    git fetch origin
    git checkout 5171c3b6528ef686667ad088c90be3a6c8a2a871

    # Add smart contract verifier env vars to L2 blockscout
    sed -i '/SMART_CONTRACT_VERIFIER__SERVER__HTTP__ADDR/a\      SMART_CONTRACT_VERIFIER__SOLIDITY__FETCHER__LIST__LIST_URL: ${local.solidity_list_url}\n      SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__EVM_FETCHER__LIST__LIST_URL: ${local.solidity_list_url}\n      SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__ERA_EVM_FETCHER__LIST__LIST_URL: ${local.era_solidity_list_url}\n      SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__ZK_FETCHER__LIST__LIST_URL: ${local.zksolc_list_url}' docker-compose.yml

    # Clean up any existing L2 deployment
    ${local.sudo}./surge-remover.sh || true

    # Setup environment configuration
    cp .env.devnet .env
    sed -i 's/^POSTGRES_PORT=.*/POSTGRES_PORT=55432/' .env

    # Deploy L2 protocol
    DEPLOYER_OUTPUT=$(printf '\n\n\ntrue\n\n\n\ntrue\n' | ${local.sudo}./surge-protocol-deployer.sh 2>&1) || true
    echo "$DEPLOYER_OUTPUT"

    # Verify expected output
    if echo "$DEPLOYER_OUTPUT" | grep -q "RISC0_BLOCK_PROVING_IMAGE_ID is not set"; then
      echo "L2 protocol deployer completed with expected output"
    else
      echo "ERROR: L2 protocol deployer did not produce expected output"
      exit 1
    fi

    # Extract verifier addresses from L2 deployment
    RISC0_GROTH16_VERIFIER=$(cat ${local.home_dir}/simple-surge-node/deployment/deploy_l1.json | jq -r '.risc0_groth16_verifier')
    SP1_RETH_VERIFIER=$(cat ${local.home_dir}/simple-surge-node/deployment/deploy_l1.json | jq -r '.sp1_reth_verifier')
    echo "Extracted RISC0_GROTH16_VERIFIER: $RISC0_GROTH16_VERIFIER"
    echo "Extracted SP1_RETH_VERIFIER: $SP1_RETH_VERIFIER"

    # Clone raiko repository
    RAIKO_TAG="v25.1.0-surge"
    cd ${local.home_dir}
    if [ ! -d raiko ]; then
      git clone https://github.com/NethermindEth/raiko.git
    fi
    cd raiko
    git fetch origin
    git checkout $RAIKO_TAG

    # Copy chain spec config from simple-surge-node to raiko
    mkdir -p host/config/devnet
    cp ${local.home_dir}/simple-surge-node/configs/chain_spec_list_default.json host/config/devnet/chain_spec_list.json

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

    echo "Raiko setup complete!"

    # Update raiko docker image tag (still in raiko directory from previous steps)
    sed -i "s/:latest/:$RAIKO_TAG/g" docker/docker-compose-zk.yml

    # Start raiko docker containers
    cd docker
    ${local.sudo}docker compose -f docker-compose-zk.yml up -d --force-recreate

    echo "Raiko containers started!"

    # Re-run surge-protocol-deployer with raiko endpoints
    cd ${local.home_dir}/simple-surge-node
    DEPLOYER_OUTPUT2=$(printf '\n\n\ntrue\n\n\nhttp://127.0.0.1:8080\nhttp://127.0.0.1:8080\n\n\n' | ${local.sudo}./surge-protocol-deployer.sh 2>&1) || true
    echo "$DEPLOYER_OUTPUT2"

    # Deploy L2 stack
    printf '\n\n5\n\n' | ${local.sudo}./surge-stack-deployer.sh

    echo "L2 stack deployment complete!"

    # Mark stack deployment as complete for chain data extraction
    touch ${local.home_dir}/.surge-stack-complete
  EOT
}

resource "null_resource" "surge_devnet_l1" {
  depends_on = [local_file.ssh]

  triggers = {
    server_ip = var.server_ip
  }

  connection {
    type        = "ssh"
    user        = var.ssh_user
    host        = var.server_ip
    port        = var.ssh_port
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [local.setup_script]
  }
}

resource "null_resource" "extract_chain_data" {
  depends_on = [null_resource.surge_devnet_l1]

  triggers = {
    server_ip = var.server_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p ${var.ssh_port} \
        -i ${var.ssh_private_key_path} \
        ${var.ssh_user}@${var.server_ip} \
        'if [ -f ${local.home_dir}/.surge-stack-complete ]; then source ${local.home_dir}/simple-surge-node/.env && echo "{\"l1Bridge\": \"$BRIDGE\", \"l2Bridge\": \"$L2_BRIDGE\", \"privateKey\": \"$PRIVATE_KEY\"}"; else echo "{}"; fi' \
        > ${path.module}/chaindata.json
    EOT
  }
}

resource "local_file" "ssh" {
  filename        = "${path.module}/ssh.sh"
  file_permission = "0755"
  content         = <<-EOT
    #!/bin/bash
    if [ "$1" = "--tunnel" ]; then
      echo "Starting SSH tunnel to ${var.server_ip}..."
      echo "Forwarding ports: 32003, 32004, 33001, 36005, 36000, 3001, 3002, 4102, 4103"
      echo "Press Ctrl+C to stop"
      ssh -N \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p ${var.ssh_port} \
        -L 8547:localhost:8547 \
        -L 32003:localhost:32003 \
        -L 32004:localhost:32004 \
        -L 33001:localhost:33001 \
        -L 36005:localhost:36005 \
        -L 36000:localhost:36000 \
        -L 3001:localhost:3001 \
        -L 3002:localhost:3002 \
        -L 4000:localhost:4000 \
        -L 4102:localhost:4102 \
        -L 4103:localhost:4103 \
        -i ${var.ssh_private_key_path} \
        ${var.ssh_user}@${var.server_ip}
    else
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p ${var.ssh_port} \
        -i ${var.ssh_private_key_path} \
        ${var.ssh_user}@${var.server_ip}
    fi
  EOT
}

output "surge_endpoints" {
  description = "Surge devnet L1 service endpoints (access via SSH tunnel)"
  value = {
    l1_rpc              = "http://localhost:8547"
    execution_rpc       = "http://localhost:32003"
    execution_ws        = "ws://localhost:32004"
    consensus_api       = "http://localhost:33001"
    l1_block_explorer   = "http://localhost:36005"
    l2_block_explorer   = "http://localhost:3001"
    bridge_ui           = "http://localhost:3002"
    l1_relayer          = "http://localhost:4102"
    l2_relayer          = "http://localhost:4103"
    transaction_spammer = "http://localhost:36000"
  }
}

output "ssh_script" {
  description = "SSH to server (use --tunnel for port forwarding)"
  value       = "./ssh.sh"
}

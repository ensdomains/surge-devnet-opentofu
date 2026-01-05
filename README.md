# surge-devnet-opentofu

[OpenTofu](https://opentofu.org/) recipes for getting [Surge devnet](https://docs.surge.wtf/docs/guides/running-surge) (including RISC/SP0 provers) up and running on a machine.

## Pre-requisites:

* [Node.js](https://nodejs.org) 24+
* [Bun](https://bun.com/) 1.3+
* [Install OpenTofu](https://opentofu.org/docs/intro/install/)
* An Ubuntu GPU cloud server (or you can use your local machine - `127.0.0.1`) with `root` user access and SSH authentication already setup.
  * _Example: [Create DigitalOcean GPU Droplet](https://cloud.digitalocean.com/gpus/new?size=gpu-h200x1-141gb)_

**Note: Your server must be of x86_64 architecture with GPUs and CUDA support.**

## Getting started

### Get Intel Provisioning certificate
https://api.portal.trustedservices.intel.com/provisioning-certification
* Goto  and _Subscribe_ to a PCK Certificate
  * _You will need to sign-in/sign-up to Intel_
* You should see the _Intel® Software Guard Extensions Provisioning Certification Service_ page - click "Subscribe" at the bottom.
* Goto _Manage Subscriptions_ (top-right) and copy the primary API key
  * The active subscription should be for _"Intel® Software Guard Extensions Provisioning Certification Service (Intel SGX PCS)"_.

### Provisioning Azure server

1. Ensure you have a [local SSH keypair](https://www.ssh.com/academy/ssh/keygen) created.
1. Sign up for and/or log into Azure
1. Goto `Quotas` and request the following limit increases:
  * _Networking > Public IPv4 Addresses - Basic_ - `20` limit in `Canada Central` region
  * _Compute > Standard DCSv3 Family vCPUs_ - `4` limit in `Canada Central` region
1. Create new virtual network (search for _"Virtual Networks"_)
  * Resource group: `surge` (create new one if it doesn't exist)
  * Virtual network name: `surge`
  * Region: `Canada Central`
  * IP addresses address space: `10.0.0.0/16` with default subnet `10.0.0.0/24`
1. Create a new VM resource 
  * Marketplace  item: `Virtual Machines with Confidential App Enclaves`
  * Subtype: `Create Azure Confidential Computing (Intel SGX VMs)`
  * Resource group: Create new one
  * Region: `Canada Central`
  * Image: `Ubuntu Server 20.04 (Gen 2)`
  * Virtual Machine name: `accvm`
  * Username: `surge`
  * Authentication type: `SSH Public Key`
  * SSH public key source: `Use existing public key`
  * SSH public key: _<paste in your local SSH key .pub file contents here>_
  * Virtual Machine Size: `DC4s_v3`
  * OS Disk Type: `Premium SSD`
  * Virtual network: `(New) ...`
  * **VERY IMPORTANT:** Edit the virtual network and do the following in order to avoid kurtosis issues later on:
    1. Set address space to `10.0.0.0/24`
    1. Delete existing subnet and then add a new one (address range should look like `10.0.0.0 - 10.0.0.255`)
  * Subnet: `(New) default`
    * **VERY IMPORTANT:** _The range shown should be `10.0.0.0 - 10.0.0.255` if you edited the virtual network correctly._
  * Public Inbound Ports: `SSH/RDP`
1. We need to ensure there is enough disk space for Docker image builds (base OS disk only has 32 GB):
  * So go to _Azure Portal → your VM → Disks (left sidebar)_:
    1. Click + Create and attach a new disk
    1. Configure:
      * Name: `surge-docker-data`
      * Storage type: `Premium SSD`
      * Size: `256 GB`
      * Host caching: `Read/write`
    1. Click Save
  * _Note: Our tofu script will auto-detect any 256 GB disk and mount it for Docker_.
  

### Running the script

In repo folder:

```bash
tofu init
```

Execute:

```bash
tofu apply -var="server_ip=<ip address of your server>" -auto-approve
````

_Note: For debugging set `TF_LOG` env var to `DEBUG` prior to running the script._

When you run this a `ssh.sh` script (bash/zsh) will have been generated. You can use to connect to the server as `root`:

```bash
./ssh.sh
```

To connect and setup a port-forwarding tunnel to all the endpoints of the devnet use `--tunnel`:

```bash
./ssh.sh --tunnel
```

Now you can access the Surge devnet L1 and L2 endpoints, see [devnet docs](https://docs.surge.wtf/docs/guides/running-surge).

### CLI Variables

#### Main server settings

| Variable | Description | Default |
|----------|-------------|---------|
| `server_ip` | Main server IP address (L1/L2 deployment) | **Required** |
| `ssh_user` | SSH username for main server | `root` |
| `ssh_private_key_path` | Path to SSH private key (shared across all servers) | `~/.ssh/id_rsa` |
| `ssh_port` | SSH port | `22` |
| `redeploy_devnet` | Force remove and redeploy existing devnet | `false` |

#### Prover server settings

Provers can run on separate servers. If not specified, they default to the main server.

| Variable | Description | Default |
|----------|-------------|---------|
| `risc_server_ip` | RISC/ZK prover server IP (requires GPU) | Uses `server_ip` |
| `risc_ssh_user` | SSH username for RISC prover server | Uses `ssh_user` |
| `sgx_server_ip` | SGX prover server IP (requires Intel SGX) | Uses `server_ip` |
| `sgx_ssh_user` | SSH username for SGX prover server | Uses `ssh_user` |
| `intel_pccs_api_key` | Intel PCCS API key for SGX provisioning | `""` |

### Deployment Examples

#### Single server (all components on one machine)

```bash
tofu apply -var="server_ip=1.2.3.4" -auto-approve
```

#### Separate RISC prover server

Deploy L1/L2 on main server, RISC/ZK prover (Bonsai Bento + Raiko) on a GPU server:

```bash
tofu apply \
  -var="server_ip=1.2.3.4" \
  -var="risc_server_ip=5.6.7.8" \
  -var="risc_ssh_user=surge" \
  -auto-approve
```

#### Separate SGX prover server

Deploy L1/L2 on main server, SGX prover on an Azure confidential compute VM:

```bash
tofu apply \
  -var="server_ip=1.2.3.4" \
  -var="sgx_server_ip=9.10.11.12" \
  -var="sgx_ssh_user=surge" \
  -var="intel_pccs_api_key=YOUR_INTEL_API_KEY" \
  -auto-approve
```

#### All separate servers

Deploy each component on dedicated infrastructure:

```bash
tofu apply \
  -var="server_ip=1.2.3.4" \
  -var="ssh_user=surge" \
  -var="risc_server_ip=5.6.7.8" \
  -var="risc_ssh_user=surge" \
  -var="sgx_server_ip=9.10.11.12" \
  -var="sgx_ssh_user=surge" \
  -var="intel_pccs_api_key=YOUR_INTEL_API_KEY" \
  -auto-approve
```

#### Force redeploy with custom SSH key

```bash
tofu apply \
  -var="server_ip=1.2.3.4" \
  -var="ssh_user=surge" \
  -var="ssh_private_key_path=/path/to/ssh/key" \
  -var="redeploy_devnet=true" \
  -auto-approve
```

#### Debug logging

```bash
export TF_LOG=DEBUG
tofu apply -var="server_ip=1.2.3.4" -auto-approve
```

### Architecture

The deployment is split into modular Terraform files:

| File | Description |
|------|-------------|
| `main.tf` | L1 devnet, L2 protocol/stack deployment, orchestration |
| `risc-prover.tf` | CUDA, NVIDIA Container Toolkit, Bonsai Bento, Raiko ZK mode |
| `sgx-prover.tf` | Intel PCCS setup, Raiko SGX mode |
| `variables.tf` | All variable definitions |

**Execution flow:**
1. Main server deploys L1 devnet via Kurtosis
2. L2 protocol first pass (generates config files)
3. Config files are downloaded to localhost
4. RISC and SGX provers are set up (can be on separate servers)
5. L2 deployment finalized with prover endpoints

## Developer guide

[Conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) are enforced using [husky](https://www.npmjs.com/package/husky). Use `bun i` to set this up.

## License 

MIT - see [LICENSE.md](LICENSE.md)

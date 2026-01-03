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

### Additonal CLI settings

You can override other settings during `tofu apply`:

* SSH username
  * default is `root`
  * use `-var="ssh_user=..."`
* SSH private key path
  * default is `~/.ssh/id_rsa`
  * use `-var="ssh_private_key_path=..."`
* Force-redeploy devnet
  * default is no
  * use `-var="redeploy_devnet=true"`


For example, if we're using all of the above options:

```bash
tofu apply \
  -var="server_ip=<ip address of your server>"  \
  -var="ssh_user=<username on server>"  \
  -var="ssh_private_key_path=/path/to/ssh/key"  \
  -var="redeploy_devnet=true"  \
  -auto-approve
```

For debug logging:

```bash
export TF_LOG=DEBUG
tofu apply \
-var="server_ip=<ip address of your server>"  \
-var="ssh_user=<username on server>"  \
-var="ssh_private_key_path=/path/to/ssh/key"  \
-var="redeploy_devnet=true"  \
-auto-approve
```

## Developer guide

[Conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) are enforced using [husky](https://www.npmjs.com/package/husky). Use `bun i` to set this up.

## License 

MIT - see [LICENSE.md](LICENSE.md)

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

In repo folder:

```bash
tofu init
```

Execute:

```bash
tofu apply -var="server_ip=<ip address of your server>" -auto-approve
````

Once done a `setup-tunnel.ssh` script (bash/zsh) will have been generated. You can run this to setup an SSH tunnel to all of the devnet endpoints on the server from your local machine:

```bash
./setup-tunnel.ssh
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

## Developer guide

[Conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) are enforced using [husky](https://www.npmjs.com/package/husky). Use `bun i` to set this up.

## License 

MIT - see [LICENSE.md](LICENSE.md)

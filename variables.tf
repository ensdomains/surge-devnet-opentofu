# Main server variables
variable "server_ip" {
  description = "Main server IP address (L1/L2 deployment)"
  type        = string
}

variable "ssh_user" {
  description = "SSH username for main server"
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key (shared across all servers)"
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

# RISC prover server variables
variable "risc_server_ip" {
  description = "RISC prover server IP address (empty = use server_ip for same-machine deployment)"
  type        = string
  default     = ""
}

variable "risc_ssh_user" {
  description = "SSH username for RISC prover server (empty = use ssh_user)"
  type        = string
  default     = ""
}

# SGX prover server variables
variable "sgx_server_ip" {
  description = "SGX prover server IP address (empty = use server_ip for same-machine deployment)"
  type        = string
  default     = ""
}

variable "sgx_ssh_user" {
  description = "SSH username for SGX prover server (empty = use ssh_user)"
  type        = string
  default     = ""
}

# SGX-specific configuration
variable "intel_pccs_api_key" {
  description = "Intel PCCS API key for SGX provisioning"
  type        = string
  sensitive   = true
  default     = ""
}

* ~~split script into two:~~
  * ~~one to setup devnet with SGX prover on Azure confidential compute VM~~
  * ~~one to setup Bento + Risc + SP1 provers on DigitalOcean GPU server~~
  * ~~and then let the two servers talk to each other so that the devnet appears to be on the same machine~~
  * **DONE**: Split into main.tf, risc-prover.tf, sgx-prover.tf with separate server support

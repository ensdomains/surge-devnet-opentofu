import { formatEther } from "viem";
import {
  CURRENT_CHAIN,
  getAccount,
  getPublicClient,
  getExplorerUrl,
} from "./common.js";

async function balance() {
  const account = getAccount();
  const client = getPublicClient();
  const explorerUrl = getExplorerUrl();

  const bal = await client.getBalance({ address: account.address });
  const ethBalance = formatEther(bal);

  console.log(`Address: ${account.address}`);
  console.log(`Chain:   ${CURRENT_CHAIN.toUpperCase()}`);
  console.log(`Balance: ${ethBalance} ETH`);
  console.log(`Explorer: ${explorerUrl}/address/${account.address}`);
}

balance();

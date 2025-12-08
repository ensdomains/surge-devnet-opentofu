import {
  CURRENT_CHAIN,
  getExplorerUrl,
  getWalletClient,
  sendBridgeMessage,
  createL1PublicClient,
  createL2PublicClient,
} from "./common.js";
import { formatEther, parseEther } from "viem";

async function bridgeEth() {
  const walletClient = getWalletClient();
  const [ownerAddress] = await walletClient.getAddresses();

  const destChain = CURRENT_CHAIN === "l1" ? "L2" : "L1";
  const destPublicClient = CURRENT_CHAIN === "l1" ? createL2PublicClient() : createL1PublicClient();
  const bridgeAmount = parseEther("0.001");

  const initialBalance = await destPublicClient.getBalance({ address: ownerAddress });

  console.log(`Bridging ETH from ${CURRENT_CHAIN.toUpperCase()} to ${destChain}...`);
  console.log("From:", ownerAddress);
  console.log("To:", ownerAddress);
  console.log("Amount:", "0.001 ETH");
  console.log(`Current ${destChain} balance:`, formatEther(initialBalance), "ETH");
  console.log("");

  try {
    console.log("Sending bridge transaction...");
    const txHash = await sendBridgeMessage({
      to: ownerAddress,
      value: bridgeAmount,
    });

    console.log("Transaction sent!");
    console.log("Transaction hash:", txHash);
    console.log(`View on explorer: ${getExplorerUrl()}/tx/${txHash}`);
    console.log("");

    console.log(`Waiting for balance update on ${destChain}...`);
    let newBalance = initialBalance;
    while (newBalance <= initialBalance) {
      await new Promise(resolve => setTimeout(resolve, 2000));
      newBalance = await destPublicClient.getBalance({ address: ownerAddress });
    }

    console.log("");
    console.log("Bridge complete!");
    console.log("Previous balance:", formatEther(initialBalance), "ETH");
    console.log("New balance:", formatEther(newBalance), "ETH");
    console.log("Received:", formatEther(newBalance - initialBalance), "ETH");
  } catch (error) {
    console.error("Error bridging ETH:", error);
    process.exit(1);
  }
}

bridgeEth();

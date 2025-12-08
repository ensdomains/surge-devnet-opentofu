import {
  L1_EXPLORER_URL,
  createL1WalletClient,
  sendBridgeMessage,
} from "./common.js";
import { parseEther } from "viem";

async function bridgeL1ToL2() {
  const walletClient = createL1WalletClient();
  const [ownerAddress] = await walletClient.getAddresses();

  const bridgeAmount = parseEther("0.001");

  console.log("Bridging ETH from L1 to L2...");
  console.log("From:", ownerAddress);
  console.log("To:", ownerAddress);
  console.log("Amount:", "0.001 ETH");
  console.log("");

  try {
    console.log("Sending bridge transaction...");
    const txHash = await sendBridgeMessage({
      to: ownerAddress,
      value: bridgeAmount,
    });

    console.log("Transaction sent!");
    console.log("Transaction hash:", txHash);
    console.log("");
    console.log("ETH will be available on L2 after the message is processed.");
    console.log("");
    console.log(`View on L1 explorer: ${L1_EXPLORER_URL}/tx/${txHash}`);
  } catch (error) {
    console.error("Error bridging ETH:", error);
    process.exit(1);
  }
}

bridgeL1ToL2();

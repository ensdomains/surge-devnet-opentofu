import {
  L1_BRIDGE_ADDRESS,
  L2_BRIDGE_ADDRESS,
  L1_CHAIN,
  L2_CHAIN,
  CURRENT_CHAIN,
  getPublicClient,
  BridgeABI,
} from "./common.js";

async function queryBridge() {
  const isL1 = CURRENT_CHAIN === "l1";
  const bridgeAddress = isL1 ? L1_BRIDGE_ADDRESS : L2_BRIDGE_ADDRESS;
  const destChain = isL1 ? L2_CHAIN : L1_CHAIN;

  const publicClient = getPublicClient();

  console.log(`Querying ${CURRENT_CHAIN.toUpperCase()} Bridge contract...`);
  console.log("Bridge address:", bridgeAddress);
  console.log("Destination chain ID:", destChain.id);
  console.log("");

  try {
    const result = await publicClient.readContract({
      address: bridgeAddress,
      abi: BridgeABI.abi,
      functionName: "isDestChainEnabled",
      args: [BigInt(destChain.id)],
    });

    const [enabled, destBridge] = result as [boolean, `0x${string}`];

    console.log("Results:");
    console.log("  Chain enabled:", enabled);
    console.log("  Destination bridge address:", destBridge);
  } catch (error) {
    console.error("Error querying bridge:", error);
    process.exit(1);
  }
}

queryBridge();

import {
  L1_BRIDGE_ADDRESS,
  L2_CHAIN,
  createL1PublicClient,
  BridgeABI,
} from "./common.js";

async function queryBridge() {
  const publicClient = createL1PublicClient();

  console.log("Querying Bridge contract...");
  console.log("Bridge address:", L1_BRIDGE_ADDRESS);
  console.log("Chain ID to check:", L2_CHAIN.id);
  console.log("");

  try {
    const result = await publicClient.readContract({
      address: L1_BRIDGE_ADDRESS,
      abi: BridgeABI.abi,
      functionName: "isDestChainEnabled",
      args: [BigInt(L2_CHAIN.id)],
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

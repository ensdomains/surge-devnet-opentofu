import { L2_BRIDGE_ADDRESS, createL2PublicClient, BridgeABI } from "./common.js";

const messageHash = process.argv[2];

async function queryMessageStatus(msgHash: string) {
  if (!msgHash || !msgHash.match(/^0x[0-9a-fA-F]{64}$/)) {
    console.error("Usage: bun scripts/queryMessageStatus.ts <messageHash>");
    console.error("Expected: 0x followed by 64 hexadecimal characters");
    if (msgHash) console.error(`Received: ${msgHash}`);
    process.exit(1);
  }

  const msgHashTyped = msgHash as `0x${string}`;

  console.log(`\n${"=".repeat(70)}`);
  console.log("Query Message Status on L2 Bridge");
  console.log(`${"=".repeat(70)}`);
  console.log("L2 Bridge Address:", L2_BRIDGE_ADDRESS);
  console.log("Message Hash:", msgHashTyped);
  console.log(`${"=".repeat(70)}\n`);

  const l2PublicClient = createL2PublicClient();

  try {
    console.log("Querying bridge contract...");
    const status = (await l2PublicClient.readContract({
      address: L2_BRIDGE_ADDRESS,
      abi: BridgeABI.abi,
      functionName: "messageStatus",
      args: [msgHashTyped],
    })) as number;

    const statusText = ["NEW", "RETRIABLE", "DONE", "FAILED", "RECALLED"][
      status
    ];
    const statusDescriptions = [
      "Message sent but not yet processed",
      "Processing failed, can be retried",
      "Successfully processed",
      "Processing failed permanently",
      "Message recalled on source chain",
    ];

    console.log("");
    console.log("Results:");
    console.log("  Status Code:", status);
    console.log("  Status:", statusText);
    console.log("  Description:", statusDescriptions[status]);
    console.log("");

    if (status === 0) {
      console.log(
        "The message has not been processed yet. It may still be pending."
      );
    } else if (status === 1) {
      console.log(
        "The message processing failed but can be retried manually."
      );
    } else if (status === 2) {
      console.log("The message was successfully processed!");
    } else if (status === 3) {
      console.log("The message processing failed permanently.");
    } else if (status === 4) {
      console.log("The message was recalled on the source chain.");
    }
    console.log("");
  } catch (error) {
    console.error("\nError querying bridge:", error);
    process.exit(1);
  }
}

queryMessageStatus(messageHash);

import {
  L1_BRIDGE_ADDRESS,
  L2_BRIDGE_ADDRESS,
  L1_EXPLORER_URL,
  L2_EXPLORER_URL,
  L2_CHAIN,
  createL2PublicClient,
  createL2WalletClient,
  sendBridgeMessage,
  waitForBridgeMessageHash,
  waitForMessageProcessedOnL2,
} from "./common.js";
import { encodeFunctionData, parseAbi } from "viem";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const VALUE_STORE_ABI = parseAbi([
  "constructor(address _bridge)",
  "function onMessageInvocation(bytes calldata _data) external payable",
  "function setValue(uint256 _value) external",
  "function value() external view returns (uint256)",
  "function bridge() external view returns (address)",
  "event ValueChanged(uint256 newValue, address caller)",
]);

async function deployValueStoreToL2() {
  console.log("=== Step 1: Deploying ValueStore Contract to L2 ===\n");

  const contractPath = path.join(__dirname, "./contracts/ValueStore.sol");
  const outDir = path.join(__dirname, "./out");

  console.log("Compiling contract with forge...");
  execSync(`forge build --contracts ${contractPath} --out ${outDir}`, {
    stdio: "inherit",
  });

  const artifactPath = path.join(outDir, "ValueStore.sol/ValueStore.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const bytecode = artifact.bytecode.object as `0x${string}`;

  const l2WalletClient = createL2WalletClient();
  const l2PublicClient = createL2PublicClient();
  const [deployerAddress] = await l2WalletClient.getAddresses();

  console.log("Deploying to L2...");
  console.log("Deployer:", deployerAddress);
  console.log("L2 Chain ID:", L2_CHAIN.id);
  console.log("");

  const deployHash = await l2WalletClient.deployContract({
    abi: VALUE_STORE_ABI,
    bytecode,
    args: [L2_BRIDGE_ADDRESS] as const,
    account: l2WalletClient.account!,
    chain: undefined,
  });

  console.log("Deployment transaction sent:", deployHash);
  console.log(`View on L2 explorer: ${L2_EXPLORER_URL}/tx/${deployHash}`);
  console.log("");

  console.log("Waiting for deployment confirmation...");
  const deployReceipt = await l2PublicClient.waitForTransactionReceipt({
    hash: deployHash,
  });

  if (!deployReceipt.contractAddress) {
    throw new Error(
      "Contract deployment failed - no contract address in receipt"
    );
  }

  const contractAddress = deployReceipt.contractAddress;
  console.log("Contract deployed successfully!");
  console.log("Contract address:", contractAddress);
  console.log("");

  return contractAddress;
}

async function bridgeMessageToCallContract(contractAddress: `0x${string}`) {
  console.log(
    "=== Step 2: Sending Bridge Message from L1 to Call Contract ===\n"
  );

  const innerData = encodeFunctionData({
    abi: VALUE_STORE_ABI,
    functionName: "setValue",
    args: [100n],
  });

  const callData = encodeFunctionData({
    abi: VALUE_STORE_ABI,
    functionName: "onMessageInvocation",
    args: [innerData],
  });

  console.log("Bridge configuration:");
  console.log("L2 Contract address:", contractAddress);
  console.log("Calling onMessageInvocation -> setValue(100)");
  console.log("Inner data (encoded setValue call):", innerData);
  console.log("Outer calldata (onMessageInvocation):", callData);
  console.log("Calldata length:", callData.length);
  console.log("");

  console.log("Sending bridge message...");
  const txHash = await sendBridgeMessage({
    to: contractAddress,
    value: 0n,
    data: callData,
  });

  console.log("Transaction sent!");
  console.log("Transaction hash:", txHash);
  console.log(`View on L1 explorer: ${L1_EXPLORER_URL}/tx/${txHash}`);
  console.log("");

  return txHash;
}

async function waitForBridgeTransaction(txHash: `0x${string}`) {
  console.log("=== Step 3: Waiting for Bridge Transaction Confirmation ===\n");

  console.log(
    "Waiting for transaction confirmation and extracting message hash..."
  );
  const msgHash = await waitForBridgeMessageHash(txHash);

  console.log("Transaction confirmed on L1!");
  console.log("Message hash:", msgHash);
  console.log("");

  return msgHash;
}

async function waitForL2Processing(msgHash: `0x${string}`) {
  console.log("=== Step 4: Waiting for Message to be Processed on L2 ===\n");

  console.log("Polling L2 bridge for message status...");
  console.log("Message hash:", msgHash);
  console.log("Status codes: 0=NEW, 1=RETRIABLE, 2=DONE, 3=FAILED, 4=RECALLED");
  console.log("");

  await waitForMessageProcessedOnL2(msgHash);

  console.log("");
  console.log("Message processed successfully on L2!");
  console.log("");
}

async function verifyContractCall(contractAddress: `0x${string}`) {
  console.log("=== Step 5: Verifying Contract State ===\n");

  const l2PublicClient = createL2PublicClient();

  console.log("Reading value from contract...");
  const storedValue = (await l2PublicClient.readContract({
    address: contractAddress,
    abi: VALUE_STORE_ABI,
    functionName: "value",
  })) as bigint;

  console.log("Stored value:", storedValue.toString());
  console.log("");

  if (storedValue === 100n) {
    console.log(
      "Success! Contract was called via bridge and value is set to 100"
    );
  } else {
    throw new Error(
      `Expected value to be 100, but got: ${storedValue.toString()}`
    );
  }
  console.log("");
}

async function main() {
  console.log(`\n${"=".repeat(70)}`);
  console.log("Bridge Message to Call L2 Smart Contract");
  console.log(`${"=".repeat(70)}`);
  console.log("L1 Bridge Address:", L1_BRIDGE_ADDRESS);
  console.log("L2 Bridge Address:", L2_BRIDGE_ADDRESS);
  console.log(`${"=".repeat(70)}\n`);

  try {
    const contractAddress = await deployValueStoreToL2();

    const txHash = await bridgeMessageToCallContract(contractAddress);

    const msgHash = await waitForBridgeTransaction(txHash);

    await waitForL2Processing(msgHash);

    await verifyContractCall(contractAddress);

    console.log(`${"=".repeat(70)}`);
    console.log("All steps completed successfully!");
    console.log(`${"=".repeat(70)}\n`);
    console.log("Summary:");
    console.log("- Contract deployed to L2:", contractAddress);
    console.log("- Bridge message sent from L1");
    console.log("- Message processed on L2");
    console.log("- Contract method setValue(100) called successfully");
    console.log("");
  } catch (error) {
    console.error("\nError:", error);
    process.exit(1);
  }
}

main();

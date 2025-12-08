import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { config } from "dotenv";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { Command } from "commander";
import BridgeABI from "./abi/Bridge.json" with { type: "json" };
import chaindata from "../chaindata.json" with { type: "json" };

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const program = new Command();

program
  .option("-c, --chain <chain>", "chain to use (l1 or l2)", "l1")
  .allowUnknownOption()
  .parse(process.argv);

const options = program.opts();

export const CLI_OPTIONS = options;
export const CURRENT_CHAIN = options.chain as "l1" | "l2";

const DEFAULT_PRIVATE_KEY = chaindata.privateKey as `0x${string}`;

config({ path: join(__dirname, "../.env") });

export const OWNER_PRIVATE_KEY = (process.env.PRIVATE_KEY ||
  DEFAULT_PRIVATE_KEY) as `0x${string}`;

export const L1_BRIDGE_ADDRESS = (process.env.BRIDGE || chaindata.l1Bridge) as Address;
export const L2_BRIDGE_ADDRESS = (process.env.L2_BRIDGE || chaindata.l2Bridge) as Address;

const NETWORK_CONFIG = {
  devnet: {
    l1Rpc: "http://localhost:32003",
    l2Rpc: "http://localhost:8547",
    l1Explorer: "http://localhost:36005",
    l2Explorer: "http://localhost:3001",
    l1ChainId: 3151908,
    l2ChainId: 763374,
  },
} as const;

const networkConfig = NETWORK_CONFIG.devnet;

export const L1_RPC_URL = networkConfig.l1Rpc;
export const L2_RPC_URL = networkConfig.l2Rpc;
export const L1_EXPLORER_URL = networkConfig.l1Explorer;
export const L2_EXPLORER_URL = networkConfig.l2Explorer;

export const L1_CHAIN = {
  id: networkConfig.l1ChainId,
  name: "Surge L1 Chain - devnet",
  nativeCurrency: {
    decimals: 18,
    name: "Ether",
    symbol: "ETH",
  },
  rpcUrls: {
    default: { http: [L1_RPC_URL] },
    public: { http: [L1_RPC_URL] },
  },
} as const;

export const L2_CHAIN = {
  id: networkConfig.l2ChainId,
  name: "Surge L2 Chain - devnet",
  nativeCurrency: {
    decimals: 18,
    name: "Ether",
    symbol: "ETH",
  },
  rpcUrls: {
    default: { http: [L2_RPC_URL] },
    public: { http: [L2_RPC_URL] },
  },
} as const;

export function createL1PublicClient(): PublicClient {
  return createPublicClient({
    chain: L1_CHAIN,
    transport: http(L1_RPC_URL),
  });
}

export function createL1WalletClient(
  privateKey: `0x${string}` = OWNER_PRIVATE_KEY
): WalletClient {
  const account = privateKeyToAccount(privateKey);
  return createWalletClient({
    account,
    chain: L1_CHAIN,
    transport: http(L1_RPC_URL),
  });
}

export function createL2PublicClient(): PublicClient {
  return createPublicClient({
    chain: L2_CHAIN,
    transport: http(L2_RPC_URL),
  });
}

export function createL2WalletClient(
  privateKey: `0x${string}` = OWNER_PRIVATE_KEY
): WalletClient {
  const account = privateKeyToAccount(privateKey);
  return createWalletClient({
    account,
    chain: L2_CHAIN,
    transport: http(L2_RPC_URL),
  });
}

export function getAccount(privateKey: `0x${string}` = OWNER_PRIVATE_KEY) {
  return privateKeyToAccount(privateKey);
}

export type ChainOption = "l1" | "l2";

export function getPublicClient(chain: ChainOption = CURRENT_CHAIN): PublicClient {
  return chain === "l1" ? createL1PublicClient() : createL2PublicClient();
}

export function getWalletClient(
  chain: ChainOption = CURRENT_CHAIN,
  privateKey: `0x${string}` = OWNER_PRIVATE_KEY
): WalletClient {
  return chain === "l1"
    ? createL1WalletClient(privateKey)
    : createL2WalletClient(privateKey);
}

export function getExplorerUrl(chain: ChainOption = CURRENT_CHAIN): string {
  return chain === "l1" ? L1_EXPLORER_URL : L2_EXPLORER_URL;
}

export interface SendBridgeMessageOptions {
  to: Address;
  value?: bigint;
  data?: `0x${string}`;
  destChainId?: bigint;
  srcOwner?: Address;
  destOwner?: Address;
}

export async function sendBridgeMessage(
  options: SendBridgeMessageOptions
): Promise<`0x${string}`> {
  const l1PublicClient = createL1PublicClient();
  const l1WalletClient = createL1WalletClient();
  const [ownerAddress] = await l1WalletClient.getAddresses();

  const {
    to,
    value = 0n,
    data = "0x" as `0x${string}`,
    destChainId = BigInt(L2_CHAIN.id),
    srcOwner = ownerAddress,
    destOwner = ownerAddress,
  } = options;

  const dataLength = data.length;

  const minGasLimit = (await l1PublicClient.readContract({
    address: L1_BRIDGE_ADDRESS,
    abi: BridgeABI.abi,
    functionName: "getMessageMinGasLimit",
    args: [BigInt(dataLength)],
  })) as bigint;

  const minGasLimitWithBuffer = BigInt(minGasLimit);

  const message = {
    id: 0n,
    fee: 0n,
    gasLimit: minGasLimitWithBuffer,
    from: ownerAddress,
    srcChainId: BigInt(L1_CHAIN.id),
    srcOwner,
    destChainId,
    destOwner,
    to,
    value,
    data,
  };

  const totalValue = value + message.fee;

  const estimatedGas = await l1PublicClient.estimateContractGas({
    address: L1_BRIDGE_ADDRESS,
    abi: BridgeABI.abi,
    functionName: "sendMessage",
    args: [message],
    value: totalValue,
    account: ownerAddress,
  });

  const txHash = await l1WalletClient.writeContract({
    address: L1_BRIDGE_ADDRESS,
    abi: BridgeABI.abi,
    functionName: "sendMessage",
    args: [message],
    value: totalValue,
    gas: estimatedGas + minGasLimitWithBuffer,
    chain: undefined,
    account: l1WalletClient.account!,
  });

  return txHash;
}

export async function waitForBridgeMessageHash(
  txHash: `0x${string}`
): Promise<`0x${string}`> {
  const l1PublicClient = createL1PublicClient();

  const receipt = await l1PublicClient.waitForTransactionReceipt({
    hash: txHash,
  });

  const logs = await l1PublicClient.getContractEvents({
    address: L1_BRIDGE_ADDRESS,
    abi: BridgeABI.abi,
    eventName: "MessageSent",
    fromBlock: receipt.blockNumber,
    toBlock: receipt.blockNumber,
  });

  if (logs.length === 0) {
    throw new Error("No MessageSent event found in transaction");
  }

  const messageSentEvent = logs.find((log) => log.transactionHash === txHash);
  if (!messageSentEvent) {
    throw new Error("MessageSent event not found for this transaction");
  }

  const msgHash = (messageSentEvent as any).args.msgHash as `0x${string}`;
  return msgHash;
}

export interface WaitForMessageOptions {
  maxAttempts?: number;
  pollInterval?: number;
}

export async function waitForMessageProcessedOnL2(
  msgHash: `0x${string}`,
  options?: WaitForMessageOptions
): Promise<void> {
  const l2PublicClient = createL2PublicClient();

  const { maxAttempts = 120, pollInterval = 5000 } = options || {};

  let status = 0;
  let attempts = 0;

  while (status === 0 && attempts < maxAttempts) {
    attempts++;

    status = (await l2PublicClient.readContract({
      address: L2_BRIDGE_ADDRESS,
      abi: BridgeABI.abi,
      functionName: "messageStatus",
      args: [msgHash],
    })) as number;

    if (status === 0) {
      await new Promise((resolve) => setTimeout(resolve, pollInterval));
    }
  }

  if (attempts >= maxAttempts) {
    throw new Error("Timeout waiting for message to be processed");
  }

  const statusText = ["NEW", "RETRIABLE", "DONE", "FAILED", "RECALLED"][status];

  if (status !== 2) {
    throw new Error(`Message processing failed with status: ${statusText}`);
  }
}

export { BridgeABI };

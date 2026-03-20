# End-to-End Deployment Guide

Deploy **everything** from scratch: Teleporter infra, ERC20 tokens, ICTT bridge (TokenHome + TokenRemote), EscrowFactory, and token whitelisting.

**Chains:** **Chain A** = home (token origin), **Chain B** = remote (bridged token). Both must be ICM/Warp-enabled Avalanche EVM chains.

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- `jq` (for Teleporter/Registry deploy scripts)
- Deployer wallet funded with native gas on all target chains
- (Optional) Block explorer API keys for contract verification

---

## Repository Setup

```bash
git clone <repo-url>
cd evm_escrow
forge install
# Init icm-services submodule (ICTT contracts + Teleporter deploy scripts)
git submodule update --init --recursive
```

The repo has two Foundry profiles:

| Profile | Solc | What it compiles |
|---------|------|-----------------|
| `default` | 0.8.28 | `src/` — EscrowFactory, EscrowVault |
| `ictt` | 0.8.30 | `ictt/` — BridgeableERC20, ICTT deploy scripts |

```bash
# Build escrow contracts
forge build

# Build ICTT scripts
FOUNDRY_PROFILE=ictt forge build
```

---

## Environment Setup

```bash
cp .env.example .env
# Edit .env with your values — never commit .env
```

Set these once in your shell (or in `.env`):

```bash
export PRIVATE_KEY=0x...
export OWNER_ADDRESS=0x...

# Chain RPCs
export RPC_URL_HOME=https://api.avax-test.network/ext/bc/C/rpc       # e.g. Fuji C-chain
export RPC_URL_REMOTE=https://subnets.avax.network/echo/testnet/rpc  # e.g. your L1

# Teleporter manager (your EOA or multisig — NOT the TeleporterMessenger contract)
export TELEPORTER_MANAGER=$OWNER_ADDRESS
export TELEPORTER_VERSION=v0.2.0
```

---

## Phase 1 — Teleporter Infrastructure (both chains)

Teleporter must exist on both chains before any ICTT deployment. Run from **repo root**.

### 1.1 Deploy TeleporterMessenger

```bash
# Chain A (home)
./lib/icm-services/scripts/deploy_teleporter.sh \
  --version $TELEPORTER_VERSION \
  --rpc-url $RPC_URL_HOME \
  --private-key $PRIVATE_KEY

# Chain B (remote) — same command, different RPC
./lib/icm-services/scripts/deploy_teleporter.sh \
  --version $TELEPORTER_VERSION \
  --rpc-url $RPC_URL_REMOTE \
  --private-key $PRIVATE_KEY
```

Save the printed **TeleporterMessenger address** (same on both chains when using the same version).

> **Note:** The deploy uses Nick's method and requires ~10 native tokens on the deployer address for the keyless deploy tx. If you see "insufficient funds", fund the deployer with more native gas.

### 1.2 Deploy TeleporterRegistry

```bash
# Chain A
./lib/icm-services/scripts/deploy_registry.sh \
  --version $TELEPORTER_VERSION \
  --rpc-url $RPC_URL_HOME \
  --private-key $PRIVATE_KEY

# Chain B
./lib/icm-services/scripts/deploy_registry.sh \
  --version $TELEPORTER_VERSION \
  --rpc-url $RPC_URL_REMOTE \
  --private-key $PRIVATE_KEY
```

Save the addresses:

```bash
export REGISTRY_HOME=0x...    # from Chain A output
export REGISTRY_REMOTE=0x...  # from Chain B output
```

---

## Phase 2 — ICTT Token Bridge (per token)

Repeat this phase for **each token** you want to bridge. Just change the env vars.

### 2.1 Deploy BridgeableERC20 on Chain A (home)

```bash
export TOKEN_NAME="USD Coin"
export TOKEN_SYMBOL="USDC"
export TOKEN_DECIMALS=6
export INITIAL_SUPPLY=1000000000000    # 1M USDC (1e6 * 1e6)

FOUNDRY_PROFILE=ictt forge script ictt/script/DeployBridgeableERC20.s.sol \
  --rpc-url $RPC_URL_HOME --broadcast --private-key $PRIVATE_KEY
```

Save the address:

```bash
export TOKEN_ADDRESS=0x...  # from output
```

> **Skip this step** if you're bridging an existing ERC20 — just set `TOKEN_ADDRESS` to the existing token's address.

### 2.2 Deploy ERC20TokenHome on Chain A

```bash
export TELEPORTER_REGISTRY_ADDRESS=$REGISTRY_HOME
export TELEPORTER_MANAGER_ADDRESS=$TELEPORTER_MANAGER
# TOKEN_ADDRESS already set from 2.1
# TOKEN_DECIMALS already set from 2.1

FOUNDRY_PROFILE=ictt forge script ictt/script/DeployERC20TokenHome.s.sol \
  --rpc-url $RPC_URL_HOME --broadcast --private-key $PRIVATE_KEY
```

Save the address and get the blockchain ID:

```bash
export TOKEN_HOME_ADDRESS=0x...  # from output

# Get Chain A blockchain ID (bytes32)
cast call $TOKEN_HOME_ADDRESS "getBlockchainID()" --rpc-url $RPC_URL_HOME
export HOME_BLOCKCHAIN_ID=0x...  # 0x + 64 hex chars
```

### 2.3 Deploy ERC20TokenRemote on Chain B

```bash
export TELEPORTER_REGISTRY_ADDRESS=$REGISTRY_REMOTE
export TELEPORTER_MANAGER_ADDRESS=$TELEPORTER_MANAGER
export TOKEN_HOME_BLOCKCHAIN_ID=$HOME_BLOCKCHAIN_ID
export TOKEN_HOME_ADDRESS=$TOKEN_HOME_ADDRESS
export TOKEN_HOME_DECIMALS=$TOKEN_DECIMALS
export REMOTE_TOKEN_NAME="Bridged USDC"
export REMOTE_TOKEN_SYMBOL="bUSDC"
export REMOTE_TOKEN_DECIMALS=$TOKEN_DECIMALS

FOUNDRY_PROFILE=ictt forge script ictt/script/DeployERC20TokenRemote.s.sol \
  --rpc-url $RPC_URL_REMOTE --broadcast --private-key $PRIVATE_KEY
```

Save the address:

```bash
export TOKEN_REMOTE_ADDRESS=0x...  # from output
```

### 2.4 Register Remote with Home

Run on **Chain B** (remote):

```bash
export TOKEN_REMOTE_ADDRESS=$TOKEN_REMOTE_ADDRESS

FOUNDRY_PROFILE=ictt forge script ictt/script/RegisterRemoteWithHome.s.sol \
  --rpc-url $RPC_URL_REMOTE --broadcast --private-key $PRIVATE_KEY
```

Then **run the ICM relayer** to deliver the registration message from Chain B to Chain A. See [Relayer Setup](#relayer-setup) below.

### 2.5 Repeat for more tokens

To bridge another token (e.g. WBTC), re-export the env vars and repeat steps 2.1–2.4:

```bash
export TOKEN_NAME="Wrapped Bitcoin"
export TOKEN_SYMBOL="WBTC"
export TOKEN_DECIMALS=8
export INITIAL_SUPPLY=2100000000000000  # 21M WBTC
export REMOTE_TOKEN_NAME="Bridged WBTC"
export REMOTE_TOKEN_SYMBOL="bWBTC"
export REMOTE_TOKEN_DECIMALS=8
# ... then run 2.1 through 2.4 again
```

---

## Phase 3 — Escrow System

### 3.1 Deploy EscrowFactory

```bash
forge script script/DeployRegistry.s.sol --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $RPC_URL_HOME --broadcast --verify
```

Save the address:

```bash
export ESCROW_FACTORY=0x...  # from output
```

Deploy on each chain where you need escrows (repeat with different `--rpc-url`).

### 3.2 Whitelist tokens

Run **once per token** on each chain. The tx must be sent by the factory owner.

```bash
# Whitelist USDC
forge script script/WhitelistTokens.s.sol \
  --sig "run(address,address)" $ESCROW_FACTORY <USDC_ADDRESS> \
  --rpc-url $RPC_URL_HOME --broadcast --private-key $PRIVATE_KEY

# Whitelist WBTC
forge script script/WhitelistTokens.s.sol \
  --sig "run(address,address)" $ESCROW_FACTORY <WBTC_ADDRESS> \
  --rpc-url $RPC_URL_HOME --broadcast --private-key $PRIVATE_KEY
```

On remote chains, whitelist the **bridged** token addresses (from Step 2.3).

### 3.3 (Optional) Deploy test ERC20 tokens

If you need USDC/WBTC test tokens on a non-Avalanche chain (e.g. Sepolia, Base Sepolia):

```bash
forge script script/DeployErc20Tokens.s.sol --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url <RPC_URL> --broadcast --private-key $PRIVATE_KEY
```

---

## Relayer Setup

The ICM relayer delivers cross-chain messages (registration, token transfers). There are **no public relayers** for custom chain pairs — you must run your own.

### Quick start

1. Download the relayer binary from [icm-services releases](https://github.com/ava-labs/icm-services/releases)

2. Create a relayer config (start from `lib/icm-services/sample-relayer-config.json`):

   ```json
   {
     "p-chain-api": { "base-url": "https://api.avax-test.network" },
     "info-api": { "base-url": "https://api.avax-test.network" },
     "source-blockchains": [
       {
         "subnet-id": "<HOME_SUBNET_ID>",
         "blockchain-id": "<HOME_BLOCKCHAIN_ID>",
         "rpc-endpoint": { "base-url": "<RPC_URL_HOME>" },
         "ws-endpoint": { "base-url": "<WS_URL_HOME>" },
         "message-contracts": {
           "<TELEPORTER_MESSENGER>": {
             "message-format": "teleporter",
             "settings": { "reward-address": "<RELAYER_ADDRESS>" }
           }
         },
         "supported-destinations": [{ "blockchain-id": "<REMOTE_BLOCKCHAIN_ID>" }]
       },
       {
         "subnet-id": "<REMOTE_SUBNET_ID>",
         "blockchain-id": "<REMOTE_BLOCKCHAIN_ID>",
         "rpc-endpoint": { "base-url": "<RPC_URL_REMOTE>" },
         "ws-endpoint": { "base-url": "<WS_URL_REMOTE>" },
         "message-contracts": {
           "<TELEPORTER_MESSENGER>": {
             "message-format": "teleporter",
             "settings": { "reward-address": "<RELAYER_ADDRESS>" }
           }
         },
         "supported-destinations": [{ "blockchain-id": "<HOME_BLOCKCHAIN_ID>" }]
       }
     ],
     "destination-blockchains": [
       {
         "subnet-id": "<HOME_SUBNET_ID>",
         "blockchain-id": "<HOME_BLOCKCHAIN_ID>",
         "rpc-endpoint": { "base-url": "<RPC_URL_HOME>" },
         "account-private-key": "0x..."
       },
       {
         "subnet-id": "<REMOTE_SUBNET_ID>",
         "blockchain-id": "<REMOTE_BLOCKCHAIN_ID>",
         "rpc-endpoint": { "base-url": "<RPC_URL_REMOTE>" },
         "account-private-key": "0x..."
       }
     ]
   }
   ```

3. Fund the relayer address with native gas on **both** chains

4. Run: `icm-relayer --config-file relayer-config.json`

> Use a dedicated EOA for the relayer (not your deployer key) to avoid nonce conflicts.

---

## Sending Tokens Cross-Chain

After registration is complete (relayer delivered the message):

### Approve + Send (Chain A → Chain B)

```bash
# 1. Approve TokenHome to spend your tokens
cast send $TOKEN_ADDRESS "approve(address,uint256)" $TOKEN_HOME_ADDRESS <AMOUNT> \
  --rpc-url $RPC_URL_HOME --private-key $PRIVATE_KEY

# 2. Send tokens to Chain B
# Get Chain B blockchain ID
export REMOTE_BLOCKCHAIN_ID=0x...

cast send $TOKEN_HOME_ADDRESS \
  "send((bytes32,address,address,address,uint256,uint256,uint256,address),uint256)" \
  "($REMOTE_BLOCKCHAIN_ID,$TOKEN_REMOTE_ADDRESS,$RECIPIENT,0x0000000000000000000000000000000000000000,0,0,300000,0x0000000000000000000000000000000000000000)" \
  "<AMOUNT>" \
  --rpc-url $RPC_URL_HOME --private-key $PRIVATE_KEY
```

Then run the relayer to deliver the message. Your recipient on Chain B receives minted bridged tokens.

---

## Deployment Summary

| Step | What | Chain | Profile | Output |
|------|------|-------|---------|--------|
| 1.1 | TeleporterMessenger | A + B | — (shell script) | Teleporter address |
| 1.2 | TeleporterRegistry | A + B | — (shell script) | Registry per chain |
| 2.1 | BridgeableERC20 | A | `ictt` | `TOKEN_ADDRESS` |
| 2.2 | ERC20TokenHome | A | `ictt` | `TOKEN_HOME_ADDRESS` |
| 2.3 | ERC20TokenRemote | B | `ictt` | `TOKEN_REMOTE_ADDRESS` |
| 2.4 | registerWithHome | B→A | `ictt` | — (relayer delivers) |
| 3.1 | EscrowFactory | any | `default` | `ESCROW_FACTORY` |
| 3.2 | Whitelist tokens | any | `default` | — |

> Repeat Phase 2 (steps 2.1–2.4) for each token. Repeat Phase 3 for each chain that needs escrows.

---

## Project Structure

```
evm_escrow/
├── src/                           # Escrow contracts (solc 0.8.28)
│   ├── EscrowFactory.sol
│   └── EscrowVault.sol
├── script/                        # Escrow deploy scripts
│   ├── DeployRegistry.s.sol
│   ├── DeployErc20Tokens.s.sol
│   ├── WhitelistTokens.s.sol
│   └── TestFullFlow.s.sol
├── test/
│   └── Escrow.t.sol
├── ictt/                          # ICTT contracts & scripts (solc 0.8.30)
│   ├── src/
│   │   └── BridgeableERC20.sol
│   └── script/
│       ├── DeployBridgeableERC20.s.sol
│       ├── DeployERC20TokenHome.s.sol
│       ├── DeployERC20TokenRemote.s.sol
│       └── RegisterRemoteWithHome.s.sol
├── lib/
│   ├── forge-std/
│   ├── openzeppelin-contracts/
│   ├── openzeppelin-contracts-upgradeable/
│   └── icm-services/              # Submodule — ICTT core + Teleporter + deploy scripts
│       ├── icm-contracts/avalanche/ictt/
│       ├── scripts/deploy_teleporter.sh
│       └── scripts/deploy_registry.sh
└── foundry.toml                   # Two profiles: default + ictt
```

---

## Network Reference

| Network | Chain ID | RPC URL |
|---------|----------|---------|
| Avalanche Fuji (C-chain) | 43113 | `https://api.avax-test.network/ext/bc/C/rpc` |
| Ethereum Sepolia | 11155111 | `https://rpc.sepolia.org` |
| Base Sepolia | 84532 | `https://sepolia.base.org` |
| Arbitrum Sepolia | 421614 | `https://sepolia-rollup.arbitrum.io/rpc` |
| Moonbase Alpha | 1287 | `https://rpc.api.moonbase.moonbeam.network` |

> More chains: [Chainlist](https://chainlist.org)

---

## Verification

If `--verify` fails during deployment, verify manually:

```bash
# Escrow contracts
forge verify-contract <FACTORY_ADDRESS> src/EscrowFactory.sol:EscrowFactory \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>

# ICTT contracts
FOUNDRY_PROFILE=ictt forge verify-contract <TOKEN_HOME_ADDRESS> \
  lib/icm-services/icm-contracts/avalanche/ictt/TokenHome/ERC20TokenHome.sol:ERC20TokenHome \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>
```

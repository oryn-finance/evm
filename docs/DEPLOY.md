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
| `default` | 0.8.28 | `src/` — EscrowFactory, EscrowVault, AvalancheEscrowFactory, AvalancheEscrowVault, ICMBridgeFactory |
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

## Phase 3 — Escrow System (non-Avalanche chains)

Deploy the **standard** EscrowFactory on chains that do **not** need ICTT bridging (e.g. Ethereum, Arbitrum, Base). For Avalanche C-chain and L1s, skip to [Phase 4](#phase-4--avalanche-escrow--ictt-bridge).

### 3.1 Deploy EscrowFactory

```bash
forge script script/DeployRegistry.s.sol --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $RPC_URL_HOME --broadcast --verify
```

Save the address:

```bash
export ESCROW_FACTORY=0x...  # from output
```

Deploy on each non-Avalanche chain where you need escrows (repeat with different `--rpc-url`).

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

### 3.3 (Optional) Deploy test ERC20 tokens

If you need USDC/WBTC test tokens on a non-Avalanche chain (e.g. Sepolia, Base Sepolia):

```bash
forge script script/DeployErc20Tokens.s.sol --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url <RPC_URL> --broadcast --private-key $PRIVATE_KEY
```

---

## Phase 4 — Avalanche Escrow + ICTT Bridge

Deploy the **Avalanche-specific** escrow and bridge contracts on the C-chain and each L1. These enable cross-chain escrow settlement via ICTT — tokens are locked/minted (or burned/unlocked) atomically on claim.

> **Prerequisites:** Phase 1 (Teleporter) and Phase 2 (ICTT token bridge) must be complete before this phase. You need `TOKEN_HOME_ADDRESS`, `TOKEN_REMOTE_ADDRESS`, and the blockchain IDs for both chains.

### How it works

Two settlement flows enabled by the `l1Hop` flag:

| Direction | Source chain | Dest chain | What happens on claim |
|-----------|-------------|------------|----------------------|
| **Forward** (ETH → L1) | Any chain | C-chain (`l1Hop=true`) | `claimHop()` → TokenHome **locks** → TokenRemote **mints** on L1 |
| **Reverse** (L1 → ETH) | L1 (`l1Hop=true`) | Any chain | `claimHop()` → TokenRemote **burns** → TokenHome **unlocks** on C-chain |

Both directions use the **same contracts** — `AvalancheEscrowFactory`, `AvalancheEscrowVault`, and `ICMBridgeFactory`. The only difference is which chain they're deployed on and which ICTT transferrer the route points to.

### Environment variables

In addition to the base variables (`PRIVATE_KEY`, `OWNER_ADDRESS`), set these:

```bash
# ── Chain RPCs ──
export RPC_URL_CCHAIN=https://api.avax-test.network/ext/bc/C/rpc
export RPC_URL_L1=https://subnets.avax.network/echo/testnet/rpc

# ── From Phase 2 outputs ──
export TOKEN_ADDRESS=0x...          # ERC20 token on C-chain (e.g. WBTC)
export TOKEN_HOME_ADDRESS=0x...     # ERC20TokenHome on C-chain
export TOKEN_REMOTE_ADDRESS=0x...   # ERC20TokenRemote on L1 (wrapped token)

# ── Blockchain IDs (bytes32, 0x + 64 hex chars) ──
# Get C-chain blockchain ID:
#   cast call $TOKEN_HOME_ADDRESS "getBlockchainID()" --rpc-url $RPC_URL_CCHAIN
export CCHAIN_BLOCKCHAIN_ID=0x...

# Get L1 blockchain ID:
#   cast call $TOKEN_REMOTE_ADDRESS "getBlockchainID()" --rpc-url $RPC_URL_L1
export L1_BLOCKCHAIN_ID=0x...

# ── Gas limit for ICM relayer delivery (250k is a safe default) ──
export REQUIRED_GAS_LIMIT=250000
```

### 4.1 Deploy AvalancheEscrowFactory on C-chain

```bash
forge script script/DeployAvalancheEscrowFactory.s.sol \
  --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $RPC_URL_CCHAIN --broadcast --private-key $PRIVATE_KEY
```

Save the address:

```bash
export AVALANCHE_FACTORY_CCHAIN=0x...  # from output
```

### 4.2 Deploy ICMBridgeFactory on C-chain

```bash
forge script script/DeployICMBridgeFactory.s.sol \
  --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $RPC_URL_CCHAIN --broadcast --private-key $PRIVATE_KEY
```

Save the address:

```bash
export BRIDGE_FACTORY_CCHAIN=0x...  # from output
```

### 4.3 Register bridge route on C-chain (Forward: C-chain → L1)

This tells ICMBridgeFactory how to bridge a token from C-chain to the L1. The route maps `(token, destBlockchainId)` to the TokenHome/TokenRemote pair.

```bash
forge script script/RegisterBridgeRoute.s.sol \
  --sig "run(address,address,bytes32,address,address,uint256)" \
  $BRIDGE_FACTORY_CCHAIN \
  $TOKEN_ADDRESS \
  $L1_BLOCKCHAIN_ID \
  $TOKEN_HOME_ADDRESS \
  $TOKEN_REMOTE_ADDRESS \
  $REQUIRED_GAS_LIMIT \
  --rpc-url $RPC_URL_CCHAIN --broadcast --private-key $PRIVATE_KEY
```

> Register one route per token per destination L1. To bridge USDC and WBTC to the same L1, run this step twice with different `TOKEN_ADDRESS`, `TOKEN_HOME_ADDRESS`, and `TOKEN_REMOTE_ADDRESS` values.

### 4.4 Whitelist tokens on C-chain AvalancheEscrowFactory

```bash
cast send $AVALANCHE_FACTORY_CCHAIN "whitelistToken(address)" $TOKEN_ADDRESS \
  --rpc-url $RPC_URL_CCHAIN --private-key $PRIVATE_KEY
```

### 4.5 Deploy AvalancheEscrowFactory on L1

Same contract, deployed on the L1 — enables the **reverse flow** (L1 → C-chain burn & unlock).

```bash
forge script script/DeployAvalancheEscrowFactory.s.sol \
  --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $RPC_URL_L1 --broadcast --private-key $PRIVATE_KEY
```

Save the address:

```bash
export AVALANCHE_FACTORY_L1=0x...  # from output
```

### 4.6 Deploy ICMBridgeFactory on L1

```bash
forge script script/DeployICMBridgeFactory.s.sol \
  --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $RPC_URL_L1 --broadcast --private-key $PRIVATE_KEY
```

Save the address:

```bash
export BRIDGE_FACTORY_L1=0x...  # from output
```

### 4.7 Register bridge route on L1 (Reverse: L1 → C-chain)

Note the **swapped** transferrer addresses — on the L1, `tokenTransferrer` is the TokenRemote (it calls `send()` to burn), and `destTransferrer` is the TokenHome (it unlocks on C-chain).

```bash
forge script script/RegisterBridgeRoute.s.sol \
  --sig "run(address,address,bytes32,address,address,uint256)" \
  $BRIDGE_FACTORY_L1 \
  $TOKEN_REMOTE_ADDRESS \
  $CCHAIN_BLOCKCHAIN_ID \
  $TOKEN_REMOTE_ADDRESS \
  $TOKEN_HOME_ADDRESS \
  $REQUIRED_GAS_LIMIT \
  --rpc-url $RPC_URL_L1 --broadcast --private-key $PRIVATE_KEY
```

> **Key difference from 4.3:** The first `TOKEN_REMOTE_ADDRESS` is the **token** being bridged (the wrapped ERC20 on L1). The second `TOKEN_REMOTE_ADDRESS` is the **tokenTransferrer** (same contract — it implements `ITokenTransferrer.send()` which burns and sends an ICM message). `TOKEN_HOME_ADDRESS` is the **destTransferrer** on C-chain that will unlock the original tokens.

### 4.8 Whitelist wrapped token on L1 AvalancheEscrowFactory

```bash
cast send $AVALANCHE_FACTORY_L1 "whitelistToken(address)" $TOKEN_REMOTE_ADDRESS \
  --rpc-url $RPC_URL_L1 --private-key $PRIVATE_KEY
```

### 4.9 Repeat for additional tokens

To bridge another token (e.g. USDC in addition to WBTC), re-export the per-token env vars and repeat steps 4.3, 4.4, 4.7, and 4.8. The factories (4.1, 4.2, 4.5, 4.6) are deployed once per chain.

### 4.10 Repeat for additional L1s

To add another L1 (e.g. a second Avalanche L1):

1. Complete Phase 2 for the new L1 (TokenHome already exists on C-chain; deploy a new TokenRemote on the new L1 and register it)
2. Register a new route on C-chain ICMBridgeFactory (step 4.3) pointing to the new L1's blockchain ID and TokenRemote
3. Deploy AvalancheEscrowFactory + ICMBridgeFactory on the new L1 (steps 4.5–4.6)
4. Register the reverse route on the new L1's ICMBridgeFactory (step 4.7)
5. Whitelist tokens on both factories (steps 4.4, 4.8)

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
| 3.1 | EscrowFactory | non-Avalanche | `default` | `ESCROW_FACTORY` |
| 3.2 | Whitelist tokens | non-Avalanche | `default` | — |
| 4.1 | AvalancheEscrowFactory | C-chain | `default` | `AVALANCHE_FACTORY_CCHAIN` |
| 4.2 | ICMBridgeFactory | C-chain | `default` | `BRIDGE_FACTORY_CCHAIN` |
| 4.3 | Register route (forward) | C-chain | `default` | — |
| 4.4 | Whitelist token | C-chain | `default` | — |
| 4.5 | AvalancheEscrowFactory | L1 | `default` | `AVALANCHE_FACTORY_L1` |
| 4.6 | ICMBridgeFactory | L1 | `default` | `BRIDGE_FACTORY_L1` |
| 4.7 | Register route (reverse) | L1 | `default` | — |
| 4.8 | Whitelist wrapped token | L1 | `default` | — |

> - Repeat Phase 2 (steps 2.1–2.4) for each token.
> - Repeat Phase 3 for each non-Avalanche chain that needs escrows.
> - Repeat Phase 4 steps 4.3–4.4 and 4.7–4.8 for each token on Avalanche chains.
> - Repeat Phase 4 steps 4.5–4.8 for each additional L1.

---

## Project Structure

```
evm_escrow/
├── src/                           # Escrow contracts (solc 0.8.28)
│   ├── EscrowFactory.sol          # Standard HTLC escrow (non-Avalanche chains)
│   ├── EscrowVault.sol            # Standard escrow vault implementation
│   ├── AvalancheEscrows/          # Avalanche-specific escrow extensions
│   │   ├── AvalancheEscrowFactory.sol  # Escrow factory with l1Hop support
│   │   └── AvalancheEscrowVault.sol    # Vault with claimHop() for ICTT bridging
│   ├── ICMBridgeFactory.sol       # ICTT bridge route registry + dispatcher
│   └── interfaces/
│       ├── IICTT.sol              # ITokenTransferrer + SendTokensInput
│       └── IICMBridgeFactory.sol  # ICMBridgeFactory interface
├── script/                        # Deploy scripts
│   ├── DeployRegistry.s.sol                  # Phase 3: Standard EscrowFactory
│   ├── DeployAvalancheEscrowFactory.s.sol    # Phase 4: AvalancheEscrowFactory
│   ├── DeployICMBridgeFactory.s.sol          # Phase 4: ICMBridgeFactory
│   ├── RegisterBridgeRoute.s.sol             # Phase 4: Register ICTT route
│   ├── WhitelistTokens.s.sol                 # Phase 3/4: Whitelist token
│   ├── DeployErc20Tokens.s.sol               # Optional: test ERC20s
│   └── TestFullFlow.s.sol
├── test/
│   ├── Escrow.t.sol
│   ├── AvalancheEscrows.t.sol
│   └── ICMBridgeFactory.t.sol
├── ictt/                          # ICTT contracts & scripts (solc 0.8.30)
│   ├── src/
│   │   └── BridgeableERC20.sol
│   └── script/
│       ├── DeployBridgeableERC20.s.sol       # Phase 2.1
│       ├── DeployERC20TokenHome.s.sol        # Phase 2.2
│       ├── DeployERC20TokenRemote.s.sol      # Phase 2.3
│       └── RegisterRemoteWithHome.s.sol      # Phase 2.4
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
# Standard EscrowFactory
forge verify-contract <FACTORY_ADDRESS> src/EscrowFactory.sol:EscrowFactory \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>

# AvalancheEscrowFactory
forge verify-contract <FACTORY_ADDRESS> \
  src/AvalancheEscrows/AvalancheEscrowFactory.sol:AvalancheEscrowFactory \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>

# ICMBridgeFactory
forge verify-contract <FACTORY_ADDRESS> src/ICMBridgeFactory.sol:ICMBridgeFactory \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>

# ICTT contracts
FOUNDRY_PROFILE=ictt forge verify-contract <TOKEN_HOME_ADDRESS> \
  lib/icm-services/icm-contracts/avalanche/ictt/TokenHome/ERC20TokenHome.sol:ERC20TokenHome \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>
```

# Avalanche Interchain Token Architecture
### ICTT & ICM-Based Token Bridging Across Avalanche L1s
*March 2026 | Scope: C-Chain to L1 & L1-to-L1 Interchain*

---

> **Document Scope**
> This document covers Avalanche-internal interchain token transfers — moving tokens between Avalanche C-Chain and Avalanche L1s (and between L1s) using ICM and ICTT. External chain bridging (e.g. Ethereum to C-Chain) is out of scope and assumed to be handled by existing infrastructure. Multi-hop cross-ecosystem routing is flagged as a future phase.

---

## 1. The Interchain Stack — ICM & ICTT

### 1.1 Avalanche Interchain Messaging (ICM)

ICM is the low-level messaging primitive that connects any two Avalanche L1s. It is built on Avalanche Warp Messaging (AWM) — a protocol baked into AvalancheGo that lets validators BLS-sign outbound messages. The destination chain verifies those signatures against the validator set registered on the P-Chain. No external oracle, no multisig committee, no relayer trust.

Every validator running an Avalanche L1 registers a BLS public key on the P-Chain. When a message is sent, a configurable threshold of those validators must co-sign it. The destination chain independently verifies the aggregate BLS signature before processing the message. The relayer is only a delivery mechanism — it cannot forge or alter messages.

| ICM Property | Detail |
|---|---|
| Transport | BLS multi-signatures over stake weight, aggregated off-chain and verified on-chain via P-Chain |
| Trust Model | Source L1 validator set only — no multisig, no oracle, no centralized relay |
| Threshold | Configurable required signing weight per L1 pair (e.g. 67% of stake) |
| Relayer Role | Permissionless message delivery — cannot forge messages, only deliver them |
| Finality | Message is valid once source chain finalizes the originating transaction |
| Privacy | Messages between non-public L1s do not pass through the Primary Network |
| Upgrades | TeleporterMessenger is versioned; both chains must support the same version |

---

### 1.2 ICTT — Interchain Token Transfer

ICTT is the application-layer token bridge built on top of ICM. It provides a set of audited, open-source smart contracts that implement the **TokenHome / TokenRemote** pattern for any ERC-20 or native token across Avalanche L1s.

**Not limited to stablecoins.** Any standard ERC-20 — USDC, USDT, WAVAX, governance tokens, LSTs, RWA tokens, wrapped BTC — can be used as the home asset. Decimals are fully configurable and ICTT has built-in decimal scaling logic for cross-chain precision mismatches (e.g. 18-decimal token on home, 6-decimal representation on remote).

**Key design principle:** there is always exactly one canonical source of truth — the TokenHome. Every token in circulation on a remote L1 has a corresponding locked token in the TokenHome escrow. This is enforced by on-chain accounting, not by any off-chain custodian.

#### The TokenHome / TokenRemote Pattern

- **TokenHome** — deployed on the chain where the canonical asset lives (e.g. USDC on C-Chain). Holds collateral in escrow, tracks how many tokens are outstanding on each registered remote, and processes inbound ICM messages to release tokens.
- **TokenRemote** — deployed on each destination L1. Mints a wrapped representation when tokens arrive from the home chain, and burns that representation when tokens are sent back, triggering an ICM message to release the originals.
- The TokenHome's balance map is the **single on-chain source of truth** — it can never release more than it has locked.
- Registering a new remote is **permissionless** — any developer can deploy a TokenRemote and call `registerWithHome()` to activate the channel.

#### Deploying a TokenHome Against an Existing Token

You do not redeploy or modify the existing token. You simply pass its address into the `ERC20TokenHome` constructor:

```solidity
constructor(
  address teleporterRegistryAddress,  // TeleporterMessenger registry (same on all Avalanche chains)
  address teleporterManager,          // your admin address
  address tokenAddress,               // existing ERC-20 address — e.g. USDC on C-Chain
  uint8   tokenDecimals               // 6 for USDC, 18 for WAVAX, etc.
)
```

```javascript
// Example: USDC on C-Chain mainnet
const tokenHome = await ERC20TokenHome.deploy(
  "0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf", // TeleporterMessenger (mainnet)
  yourAdminWallet,
  "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", // USDC — already deployed, no changes needed
  6
);
```

The TokenHome calls `transferFrom` on the existing token when users bridge (standard ERC-20 approval flow). It never takes ownership of the token contract — it just holds tokens in its own escrow balance.

> **Fee-on-Transfer Warning:** Tokens with a fee-on-transfer mechanic can cause TokenHome accounting to desync, since it expects the full amount to arrive in escrow. Standard tokens like USDC, USDT, and WAVAX have no issue.

---

## 2. Transfer Flows

### 2.1 C-Chain → L1 (Outbound)

```
User
 │
 ├─ calls transfer(amount, destinationL1, recipient)
 │  on ERC20TokenHome (C-Chain)
 │
 ├─ TokenHome locks token in escrow
 │  balance[remoteL1] += amount
 │
 ├─ emits ICM message via TeleporterMessenger
 │
Off-chain ICM Relayer
 │
 ├─ watches source chain for TeleporterMessenger events
 ├─ requests BLS signatures from C-Chain validators
 ├─ aggregates signatures (meets threshold)
 │
 └─ submits signed message to TeleporterMessenger on L1
     │
     └─ TokenRemote (L1) receives message
         ├─ verifies source (TokenHome address + C-Chain ID)
         └─ mints wrapped token to recipient
```

---

### 2.2 L1 → C-Chain (Return)

```
User
 │
 ├─ calls transfer(amount, cChain, recipient)
 │  on ERC20TokenRemote (L1)
 │
 ├─ TokenRemote burns wrapped token
 │
 ├─ emits ICM message to TokenHome
 │
ICM Relayer delivers signed message to C-Chain
 │
 └─ TokenHome receives message
     ├─ balance[remoteL1] -= amount
     └─ releases token from escrow to recipient
```

---

### 2.3 L1 → L1 (Remote-to-Remote)

ICTT supports routing tokens between two remote L1s without requiring the user to manually route through C-Chain. Under the hood it is a two-hop ICM exchange, but abstracted into a single user transaction.

```
User calls transfer() on TokenRemote-A (L1-A)
 │
 ├─ TokenRemote-A burns wrapped token
 ├─ ICM message → TokenHome (C-Chain)
 │
TokenHome (C-Chain)
 ├─ balance[L1-A] -= amount
 ├─ balance[L1-B] += amount
 └─ ICM message → TokenRemote-B (L1-B)
     │
     └─ TokenRemote-B mints wrapped token to recipient

Note: No manual step for the user.
Both ICM hops are atomic from the user's perspective.
```

> **Future Phase — Direct L1-to-L1 Multi-Hop**
> The current remote-to-remote flow routes through the C-Chain TokenHome. A future upgrade path is native multi-hop routing where L1s forward ICM messages directly without touching C-Chain, reducing latency and relayer cost. This is not in scope for the current build.

---

### 2.4 sendAndCall — Atomic Transfer + Action

ICTT includes a `sendAndCall` method that bundles a token transfer with a smart contract call into a single ICM message. The token arrives at the destination L1 and immediately triggers an action — no second transaction needed from the user.

| Use Case | Description |
|---|---|
| Auto-deposit into DEX | Transfer token to L1 and deposit into a liquidity pool in one step |
| Auto-deposit into lending | Transfer token to L1 and supply to a lending market atomically |
| Fee payment | Transfer token and pay a contract-defined service fee on arrival |
| Liquidity rebalancing | Move tokens between L1s and redeploy into yield strategies instantly |
| Vault strategies | Move yield-bearing token positions across L1 vaults atomically |

---

## 3. Full Architecture

```
AVALANCHE INTERCHAIN TOKEN ARCHITECTURE

┌────────────────────────────────────────────────────────────────────┐
│                        Avalanche C-Chain                           │
│                                                                    │
│   ┌─────────────────────────────────────────────────────────┐     │
│   │                  ERC20TokenHome                         │     │
│   │  • Holds any ERC-20 token as escrow collateral          │     │
│   │  • balance map: { L1-A: x, L1-B: y, L1-C: z, ... }    │     │
│   │  • Registers remotes via ICM handshake                  │     │
│   │  • Releases tokens on verified ICM return messages      │     │
│   └───────────────────────┬─────────────────────────────────┘     │
│                           │                                        │
│   ┌───────────────────────▼─────────────────────────────────┐     │
│   │           TeleporterMessenger (ICM router)               │     │
│   └───────────────────────┬─────────────────────────────────┘     │
└───────────────────────────│────────────────────────────────────────┘
                            │
          Avalanche Warp Messaging (BLS multi-sig, P-Chain verified)
                            │
          ┌─────────────────┼────────────────────┐
          │                 │                    │
          ▼                 ▼                    ▼
    ┌──────────┐      ┌──────────┐         ┌──────────┐
    │   L1-A   │      │   L1-B   │  . . .  │   L1-N   │
    │          │      │          │         │          │
    │ ERC20    │      │ ERC20    │         │ Native   │
    │ Token    │      │ Token    │         │ Token    │
    │ Remote   │      │ Remote   │         │ Remote   │
    │          │      │          │         │ (gas)    │
    │ mints /  │      │ mints /  │         │ mints /  │
    │ burns    │      │ burns    │         │ burns    │
    └──────────┘      └──────────┘         └──────────┘

Each TokenRemote:
• Verifies ICM message source (TokenHome address + C-Chain ID)
• Mints on inbound, burns on outbound
• Supports sendAndCall for atomic DeFi actions
• Can represent the token as ERC-20 OR as the L1's native gas token
```

---

## 4. Deployment Guide

### 4.1 Prerequisites

- Avalanche L1 running AvalancheGo with ICM (Warp) enabled at the subnet level
- `TeleporterMessenger` deployed on both C-Chain and your L1 — same address on all chains: `0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf`
- ICM Relayer running and configured to watch both chains
- Existing ERC-20 token address on C-Chain (no modifications to the token contract required)

---

### 4.2 Step-by-Step Deployment

| Step | Action |
|---|---|
| 1 | Deploy `ERC20TokenHome` on C-Chain, passing the TeleporterMessenger address, your existing token contract address, and token decimals |
| 2 | Launch or configure your Avalanche L1. Enable the `NativeMinter` precompile if you want the bridged token as the native gas token |
| 3 | Deploy `ERC20TokenRemote` (or `NativeTokenRemote`) on your L1. Args: TeleporterMessenger address, home chain blockchain ID, TokenHome contract address, token decimals |
| 4 | Call `registerWithHome()` on the TokenRemote — sends an ICM registration message to the TokenHome |
| 5 | Verify: call `registeredRemotes(remoteBlockchainID)` on the TokenHome — should return `true` |
| 6 | Test: send a small amount through the bridge. Confirm wrapped token minted on L1. Test return path. |
| 7 | Configure relayer fee token if desired (ICTT supports ERC-20 fees paid to relayers) |
| 8 | For multi-L1: repeat steps 2–6 for each additional L1. All share the same TokenHome on C-Chain |

---

### 4.3 ICM Relayer Setup

The relayer aggregates BLS signatures and delivers ICM messages. It holds no custody and cannot tamper with messages.

```bash
# Download latest ICM relayer (Linux AMD64)
curl -sL -o icm-relayer.tar.gz \
  https://github.com/ava-labs/icm-services/releases/download/\
  icm-relayer-v1.7.4/icm-relayer_1.7.4_linux_amd64.tar.gz

tar -xzf icm-relayer.tar.gz
sudo install icm-relayer /usr/local/bin/icm-relayer
```

```json
{
  "source-blockchains": [
    {
      "subnet-id": "<C-Chain subnet ID>",
      "blockchain-id": "<C-Chain blockchain ID>",
      "vm": "evm",
      "rpc-endpoint": { "base-url": "https://api.avax.network/ext/bc/C/rpc" },
      "message-protocol-configs": {
        "0x253b2784...": { "message-format": "teleporter" }
      }
    },
    {
      "subnet-id": "<your L1 subnet ID>",
      "blockchain-id": "<your L1 blockchain ID>",
      "vm": "evm",
      "rpc-endpoint": { "base-url": "https://your-l1-rpc/rpc" },
      "message-protocol-configs": {
        "0x253b2784...": { "message-format": "teleporter" }
      }
    }
  ],
  "destination-blockchains": [ "...same entries as source..." ],
  "account-private-key": "<relayer wallet private key>"
}
```

> **Relayer Redundancy:** Run at least 2 independent relayers per channel. ICM messages do not expire instantly — if one relayer goes down, a backup can deliver the message later with no loss of funds.

---

## 5. Token Backing & Collateral

### 5.1 How Wrapped Token Backing Works

Within ICTT there is no custodian, no off-chain reserve, and no need for over-collateralization. The backing is enforced by the TokenHome smart contract:

- For every 1 wrapped token minted on any remote L1, exactly 1 canonical token is locked in the TokenHome escrow on C-Chain
- The TokenHome's balance map is the **on-chain proof of reserves** — publicly queryable at any time
- The home contract can never release more than it has locked — enforced in EVM bytecode
- The only trust assumption is that the C-Chain validator set has not colluded

> **1:1 backing is structural, not oracle-dependent.** Unlike CDP stablecoins or algorithmic models, the peg does not depend on any price feed or liquidation mechanism. 1 token in = 1 wrapped token out, enforced by the TokenHome contract.

---

### 5.2 Supported Token Types

| Token Type | Notes |
|---|---|
| Fiat-backed stablecoin (USDC, USDT) | Best for payments and DeFi. USDC recommended for new deployments — Circle reserve attestations, wide adoption. |
| Crypto-backed stablecoin (DAI, USDS) | Decentralized, no issuer counterparty risk. Exposed to liquidation and oracle risk. |
| Wrapped native (WAVAX, WETH, WBTC) | Common for cross-L1 liquidity. Decimals typically 18 for ETH-style, 8 for BTC-style. |
| Governance / utility tokens | Your own L1 token bridgeable to other L1s using the same ICTT infrastructure. |
| LSTs / yield-bearing tokens | Bridgeable as long as the token is a standard ERC-20. Rebasing tokens need special handling. |
| Custom / RWA tokens | Any ERC-20. You deploy TokenHome against your existing contract. Full decimal control. |

---

## 6. Adoption Strategy

### 6.1 Liquidity Bootstrapping Sequence

| Phase | Action & Target |
|---|---|
| 1 — Seed | Bridge initial token supply from C-Chain using protocol treasury. Deploy a DEX. Create token / native-token pool. Target: $500K TVL. |
| 2 — Incentivise | Run liquidity mining. Reward LPs with native token emissions. Target $2M+ TVL before external marketing. |
| 3 — Lending | Deploy a lending market. Enable bridged token as collateral and borrowable. Creates organic demand. |
| 4 — Native Gas | Use `NativeTokenRemote` to make the bridged token the L1 gas token. Users need no volatile native token to pay fees. |
| 5 — Integrations | Integrate `sendAndCall` with DeFi protocols. Users bridge and deploy capital in one transaction. |

---

### 6.2 Token-as-Gas-Token Setup

```
C-Chain                          Your L1
┌─────────────────┐              ┌──────────────────────────────────┐
│ NativeTokenHome │──── ICM ────▶│ NativeTokenRemote                │
│ (any ERC-20)    │              │ • mints token as native gas       │
│                 │◀─── ICM ─────│ • users pay gas in your token     │
└─────────────────┘              │ • no separate gas token needed    │
                                 └──────────────────────────────────┘

L1 config: NativeMinter precompile enabled
NativeTokenRemote has NativeMinter role
All gas fees denominated in your chosen token
```

---

### 6.3 Multi-L1 Topology

```
                     C-Chain
               ┌─── TokenHome ───┐
               │   (token escrow) │
               └──────┬──────────┘
                      │
        ┌─────────────┼──────────────────┐
        │             │                  │
        ▼             ▼                  ▼
   ┌─────────┐   ┌─────────┐       ┌─────────┐
   │ GameFi  │   │  DeFi   │       │Payments │
   │   L1    │   │   L1    │  ...  │   L1    │
   │ wrapped │   │ wrapped │       │ wrapped │
   │ (ERC20) │   │ (native │       │ (ERC20) │
   └─────────┘   │  gas)   │       └─────────┘
                 └─────────┘

Each L1 is independently sovereign.
All share the same token liquidity anchored on C-Chain.
Future: direct L1-to-L1 routing without C-Chain hop.
```

---

## 7. Security & Risk

| Risk | Mitigation |
|---|---|
| Smart Contract Risk | Use unmodified, audited ICTT contracts from Ava Labs. Any custom logic (sendAndCall receivers, fee modules) must be independently audited before mainnet. |
| Validator Collusion | ICM security = your L1 validator security. A supermajority colluding could forge messages. Mitigate with a large, distributed validator set and meaningful stake requirements. |
| Relayer Liveness | Downtime causes delays, not fund loss. Run 2+ relayers with automated restart and uptime monitoring. |
| TokenHome Contract Risk | Holds all collateral. Use non-upgradeable deployment. No admin key should be able to drain the escrow. Verify in audit. |
| Decimal Mismatch | Ensure TokenHome and TokenRemote are configured with matching decimals. Verify in staging before mainnet. |
| Re-entrancy (sendAndCall) | sendAndCall target contracts can be re-entered. Implement standard re-entrancy guards in all contracts that receive sendAndCall messages. |
| Fee-on-Transfer Tokens | Tokens that take a % cut on transfer will desync the TokenHome balance map. Do not use fee-on-transfer tokens as the home asset. |
| L1 Sunset Risk | If an L1 shuts down with outstanding wrapped tokens, those become unredeemable. Plan an emergency withdrawal process before any L1 is decommissioned. |

---

## 8. Implementation Roadmap

| Phase | Deliverables |
|---|---|
| Month 1–2 — Foundation | Deploy on Fuji testnet. Set up TokenHome on Fuji C-Chain using existing token address. Deploy TokenRemote on test L1. Run ICM relayer. Test full round-trip and sendAndCall. |
| Month 3–4 — Hardening | Independent audit of any custom code. Deploy DEX and lending protocol on L1. Seed liquidity. Load test the relayer. Set up monitoring and alerting. |
| Month 5–6 — Mainnet | Deploy to mainnet. Activate liquidity mining. Integrate Core App bridge UI. Establish 2+ independent relayer operators. Activate token-as-gas if applicable. |
| Month 7–9 — Growth | Add 2nd and 3rd L1 (same TokenHome). Enable sendAndCall integrations with partner DeFi protocols. Publish weekly on-chain reserve transparency reports. |
| Month 10–12 — Future Phase | Research direct L1-to-L1 multi-hop routing. Evaluate additional tokens. Assess multi-hop architecture and ICM roadmap updates from Ava Labs. |

---

## 9. References & Implementation Assets

This section consolidates GitHub repositories, deployed contracts, C-Chain token addresses, and tooling so that we can adopt ICTT instead of custom escrow for Avalanche L1s — reducing friction and enabling USDC, WBTC, and other assets across all chains.

### 9.1 GitHub Repositories

| Repository | Purpose | Notes |
|---|---|---|
| [ava-labs/icm-services](https://github.com/ava-labs/icm-services) | ICM Relayer, Signature Aggregator, ICM Contracts | Canonical repo. Relayer, signature aggregator, and contracts (incl. Teleporter, ICTT). |
| [ICTT contracts](https://github.com/ava-labs/icm-services/tree/main/icm-contracts/avalanche/ictt) | TokenHome, TokenRemote, interfaces | `ERC20TokenHome`, `ERC20TokenRemote`, `NativeTokenHome`, `NativeTokenRemote`, `WrappedNativeToken.sol` |

### 9.2 Deployed Contract Addresses

| Contract | Address | Chains |
|---|---|---|
| `TeleporterMessenger` | `0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf` | All Avalanche chains (mainnet, Fuji, L1s) — same address via Nick's method |
| `TeleporterRegistry` (Mainnet C-Chain) | `0x7C43605E14F391720e1b37E49C78C4b03A488d98` | Mainnet C-Chain |
| `TeleporterRegistry` (Fuji C-Chain) | `0xF86Cb19Ad8405AEFa7d09C778215D2Cb6eBfB228` | Fuji C-Chain |

**Versioning:** `TeleporterMessenger` address can change on major ICM releases. Both source and destination chains must use compatible versions. See [ICM Contract Deployment](https://github.com/ava-labs/teleporter/blob/main/utils/contract-deployment/README.md) for subnet deployment.

### 9.3 C-Chain Token Addresses (Mainnet)

Use these when deploying `ERC20TokenHome` on C-Chain. No contract changes — pass address + decimals to constructor.

| Token | Address | Decimals | Source |
|---|---|---|---|
| USDC | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | 6 | Circle, widely adopted |
| USDT | Verify on [Tether](https://tether.to/) or Snowtrace | 6 | Tether |
| WAVAX | `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` | 18 | Wrapped native AVAX |
| BTC.B | `0x152b9d0fdc40c096757f570a51e494bd4b943e50` | 8 | Avalanche Bridged BTC |
| WBTC.e | Verify on [BitGo](https://wbtc.network/) / Aavescan | 8 | Ethereum-bridged WBTC |
| DAI | Verify on Snowtrace | 18 | MakerDAO |

**Fuji testnet:** Use Fuji-specific token addresses from faucets and test deployments.

### 9.4 ICTT Contract Structure (From Docs)

| Contract | Role | Key Methods |
|---|---|---|
| `ERC20TokenHome` | Lock/release ERC-20 on home chain | `transfer`, `send`, `sendAndCall`, `addCollateral` (NativeRemote) |
| `ERC20TokenRemote` | Mint/burn ERC-20 on remote | `transfer`, `send`, `sendAndCall`, `registerWithHome` |
| `NativeTokenHome` | Lock/release native token | `send` (payable), `sendAndCall` |
| `NativeTokenRemote` | Mint native gas token on L1 | `send` (payable), `registerWithHome`, `reportBurnedTxFees` |

All implement `ITokenTransferrer` and `IERC20TokenTransferrer` / `INativeTokenTransferrer`. Both upgradeable and non-upgradeable variants exist.

### 9.5 ICM Relayer & Services

| Component | Repo | Latest | Purpose |
|---|---|---|---|
| ICM Relayer | [icm-services/releases](https://github.com/ava-labs/icm-services/releases) | v1.7.5 (Jan 2026) | Watches source chains, aggregates BLS sigs, delivers to destination |
| Signature Aggregator | icm-services | v0.5.4 | Lightweight API for self-delivery of signed messages |
| Docker | `avaplatform/icm-relayer:latest` | — | Pre-built relayer image |

Download example:

```bash
curl -sL -o icm-relayer.tar.gz \
  https://github.com/ava-labs/icm-services/releases/download/icm-relayer-v1.7.5/icm-relayer_1.7.5_linux_amd64.tar.gz
```

### 9.6 Documentation & Academy

| Resource | URL |
|---|---|
| ICTT overview | https://build.avax.network/docs/cross-chain/interchain-token-transfer/overview |
| ICM / Warp overview | https://build.avax.network/docs/cross-chain/avalanche-warp-messaging/overview |
| ICM contract addresses | https://build.avax.network/docs/cross-chain/icm-contracts/addresses |
| Deep dive (Teleporter) | https://build.avax.network/docs/cross-chain/teleporter/deep-dive |
| Deploy Home (ERC-20 → ERC-20) | https://build.avax.network/academy/interchain-token-transfer/06-erc-20-to-erc-20-bridge/03-deploy-home |
| Deploy Remote | https://build.avax.network/academy/interchain-token-transfer/06-erc-20-to-erc-20-bridge/04-deploy-remote |
| ICTT + Core / AvaCloud | https://build.avax.network/academy/interchain-token-transfer/06-erc-20-to-erc-20-bridge/07-avacloud-and-core-bridge |
| Native token bridge | https://build.avax.network/academy/avalanche-l1/native-token-bridge |
| Scaling decimals (e.g. USDC as native) | https://build.avax.network/academy/avalanche-l1/interchain-token-transfer/14-scaling-decimals/02-example |
| Run a Relayer | https://build.avax.network/docs/cross-chain/avalanche-warp-messaging/run-relayer |

### 9.7 Managed Deployment (AvaCloud)

AvaCloud provides managed ICTT for Avalanche L1s:

- **Portal:** https://avacloud.io — interoperability setup during or after L1 creation
- **Docs:** https://docs.avacloud.io/portal/interoperability/how-to-set-up-interoperability
- **USDC C-Chain ↔ L1:** https://docs.avacloud.io/portal/interoperability/how-to-set-up-an-interchain-transfer-for-usdc-between-avalanche-c-chain-and-an-l-1

Features: relayer allowlisting, initial funding, home/remote deployment and registration via dashboard.

### 9.8 ICTT vs Custom Escrow (Adoption Rationale)

| Aspect | Custom Escrow (Other EVM Chains) | ICTT (Avalanche L1s) |
|---|---|---|
| Trust model | Often multisig, oracles, relayers | BLS validator signatures, P-Chain verified |
| Relay | Third-party relayers with custody risk | Permissionless relayer, cannot forge messages |
| Contracts | Custom deployments per chain | Audited, open-source TokenHome/TokenRemote |
| Token support | Per-token setup | Any ERC-20 or native; same infra for USDC, WBTC, etc. |
| L1 coverage | Bridge per chain pair | Single TokenHome, many TokenRemotes; multi-hop built-in |
| Integration | Custom UI, monitoring | Core App bridge, AvaCloud, academy tutorials |

**Recommendation:** Use ICTT for all Avalanche L1 interchain flows. Reserve custom escrow for non-Avalanche chains where ICTT is not available.

---

## 10. Key Resources (Quick Links)

### Avalanche ICM & ICTT
- [icm-services](https://github.com/ava-labs/icm-services) — main repo
- [ICTT contracts](https://github.com/ava-labs/icm-services/tree/main/icm-contracts/avalanche/ictt) — TokenHome, TokenRemote, interfaces

### Tooling & Infrastructure
- AvaCloud (managed L1 + ICTT): https://avacloud.io
- Core App (native ICM bridge UI): https://core.app
- Avalanche CLI: https://build.avax.network/docs/tooling/avalanche-cli
- Fuji Testnet Faucet: https://faucet.avax.network

---

*Technical research document. Not financial or legal advice.*
*March 2026 | Scope: Avalanche-Internal Interchain | ICM v1.7.5 / ICTT*
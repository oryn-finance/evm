<p align="center">
  <strong>Oryn Finance</strong><br/>
  EVM Atomic Swap Escrow
</p>

<p align="center">
  <a href="https://book.getfoundry.sh/"><img src="https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg" alt="Built with Foundry"/></a>
  <img src="https://img.shields.io/badge/Solidity-0.8.28-363636.svg" alt="Solidity 0.8.28"/>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"/>
</p>

---

## Overview

Hash-locked atomic swap system for ERC20 tokens and native ETH on any EVM chain. A creator deposits funds into a deterministic minimal-proxy vault; the recipient withdraws by revealing a SHA-256 preimage, or the creator reclaims funds after a block-based expiry window.

## Architecture

```
                      ┌──────────────────────────────┐
                      │        SwapRegistry           │
                      │  (Factory / Entry Point)      │
                      │                               │
                      │  - Owner whitelists tokens    │
                      │  - Deploys deterministic      │
                      │    clones with immutable args  │
                      │  - Validates params & sigs    │
                      └──────────┬───────────────────┘
                                 │ cloneDeterministicWithImmutableArgs
                                 ▼
                      ┌──────────────────────────────┐
                      │     TokenDepositVault         │
                      │  (Minimal Proxy Clone)        │
                      │                               │
                      │  Immutable args:              │
                      │   token, creator, recipient,  │
                      │   expiryBlocks, commitmentHash│
                      │                               │
                      │  - withdraw(preimage)         │
                      │  - cancelSwap()               │
                      └──────────────────────────────┘
```

## Contracts

### SwapRegistry

> `src/SwapRegistry.sol` — Factory contract and primary entry point.

| Feature | Detail |
|---|---|
| **Ownership** | `Ownable` — owner whitelists/blacklists tokens |
| **Deterministic addresses** | Clone addresses derived from `(chainId, token, creator, recipient, expiryBlocks, commitmentHash)` |
| **Duplicate prevention** | `s_deployedVaults` mapping prevents reuse of vault addresses |
| **EIP-712 signatures** | Typed data signing with per-creator nonces for replay protection |
| **Fee-on-transfer guard** | Post-transfer balance check rejects deflationary tokens |

**Vault creation paths:**

| Method | Use Case | Approval |
|---|---|---|
| `createTokenSwapVault` | Pre-funded vault (ERC20 or native) | Creator transfers to predicted address beforehand |
| `createTokenSwapVaultNativeCall` | Native ETH in one transaction | `msg.value` forwarded to vault |
| `createTokenSwapVaultPermit` | ERC20 with EIP-2612 permit | Gasless approval via signature |
| `createTokenSwapVaultSigned` | Relayer-submitted ERC20 vault | EIP-712 signed params + prior `approve` |

### TokenDepositVault

> `src/TokenDepositVault.sol` — Minimal proxy clone deployed per swap.

| Feature | Detail |
|---|---|
| **Immutable args** | `token`, `creator`, `recipient`, `expiryBlocks`, `commitmentHash` — stored in clone bytecode |
| **Settlement guard** | `s_settled` flag prevents double-withdraw, double-cancel, or withdraw-after-cancel |
| **Hash-lock** | `sha256(preimage) == commitmentHash` required for withdrawal |
| **Time-lock** | `block.number > s_depositedAt + expiryBlocks` required for cancellation |
| **Dual asset** | Supports ERC20 (via `SafeERC20`) and native ETH (sentinel `0xEee...eE`) |

## Swap Lifecycle

```
 Creator                    SwapRegistry                  Vault                     Recipient
    │                            │                          │                           │
    │  1. getTokenVaultAddress() │                          │                           │
    │ ─────────────────────────► │                          │                           │
    │  ◄── predicted address ─── │                          │                           │
    │                            │                          │                           │
    │  2. Fund + Create          │                          │                           │
    │ ─────────────────────────► │ ── deploy clone ───────► │                           │
    │                            │                          │                           │
    │                            │                          │  3a. withdraw(preimage)   │
    │                            │                          │ ◄──────────────────────── │
    │                            │                          │ ── transfer to recipient ─┤
    │                            │                          │                           │
    │  3b. cancelSwap()          │                          │                           │
    │  (after expiry)            │                          │                           │
    │ ─────────────────────────────────────────────────────►│                           │
    │ ◄── refund to creator ─────────────────────────────── │                           │
```

| Step | Actor | Action |
|---|---|---|
| 1 | Owner | Whitelist token via `whitelistToken(token, true)` |
| 2 | Creator | Call `getTokenVaultAddress(...)` to get the predicted vault address |
| 3 | Creator / Relayer | Fund and create vault via one of the four creation methods |
| 4a | Recipient | Call `withdraw(preimage)` — funds transferred to recipient |
| 4b | Creator | Call `cancelSwap()` after expiry — funds returned to creator |

## Security Model

- **Hash-lock**: SHA-256 commitment scheme — only the preimage holder can withdraw
- **Time-lock**: Block-based expiry ensures creator can reclaim after deadline
- **Settlement guard**: `s_settled` flag makes vaults single-use (no re-entrancy or double-spend)
- **Signature replay protection**: Per-creator nonces for EIP-712 signed vault creation
- **Commitment validation**: `bytes32(0)` commitment hashes are rejected
- **Fee-on-transfer protection**: Post-transfer balance checks prevent under-funded vaults
- **Gas-limited native transfers**: 30,000 gas cap on ETH transfers (supports smart contract wallets)
- **SafeERC20**: All ERC20 interactions use OpenZeppelin's SafeERC20

## Test Coverage

```
╭──────────────────────┬──────────────┬──────────────┬──────────────┬──────────────╮
│ Contract             │ % Lines      │ % Statements │ % Branches   │ % Functions  │
╞══════════════════════╪══════════════╪══════════════╪══════════════╪══════════════╡
│ SwapRegistry.sol     │ 100.00%      │ 100.00%      │ 100.00%      │ 100.00%      │
├──────────────────────┼──────────────┼──────────────┼──────────────┼──────────────┤
│ TokenDepositVault.sol│ 100.00%      │ 100.00%      │ 100.00%      │ 100.00%      │
╰──────────────────────┴──────────────┴──────────────┴──────────────┴──────────────╯
```

**75 tests** — unit, integration, and fuzz:

| Category | Count | Covers |
|---|---|---|
| Vault creation (all 4 paths) | 20 | Happy path, parameter validation, duplicate prevention |
| Withdraw | 10 | Valid/invalid commitment, third-party caller, double-withdraw, events |
| Cancel | 8 | Before/after expiry, double-cancel, cancel-after-withdraw, events |
| Native ETH | 12 | Deposit, withdraw, cancel, contract recipient failures |
| Permit flow | 7 | Valid permit, expired, non-permit token, fee-on-transfer |
| Signed flow | 9 | Valid signature, invalid signer, nonce replay, vault reuse |
| Fuzz | 5 | Amounts, expiry bounds, commitment brute-force, boundary conditions |
| Access control | 4 | Owner-only whitelist, parameter validation across paths |

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install

```bash
git clone <repo-url>
cd evm_escrow
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Coverage

```bash
forge coverage
```

### Deploy

```bash
# Deploy to a network
forge script script/DeployRegistry.s.sol --sig "run(address)" <OWNER_ADDRESS> \
  --rpc-url <RPC_URL> --broadcast --verify
```

## Project Structure

```
├── src/
│   ├── SwapRegistry.sol          # Factory — vault creation, token whitelist, signature verification
│   └── TokenDepositVault.sol     # Vault — withdraw, cancel, immutable clone args
├── test/
│   └── Escrow.t.sol              # 75 tests (unit + fuzz)
├── script/
│   ├── DeployRegistry.s.sol      # Production deploy script
│   └── DeployMockTokens.s.sol    # Testnet token deployment
└── foundry.toml                  # Foundry configuration
```

## Dependencies

| Package | Version | Usage |
|---|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | 5.x | `Ownable`, `SafeERC20`, `ECDSA`, `EIP712`, `Clones` |
| [OpenZeppelin Contracts Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) | 5.x | `Initializable` (vault clone initialization guard) |
| [Forge Std](https://github.com/foundry-rs/forge-std) | Latest | Test framework |

## License

[MIT](LICENSE)

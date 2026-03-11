<p align="center">
  <strong>Oryn Finance</strong><br/>
  Oryn Escrow
</p>

<p align="center">
  <a href="https://book.getfoundry.sh/"><img src="https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg" alt="Built with Foundry"/></a>
  <img src="https://img.shields.io/badge/Solidity-0.8.28-363636.svg" alt="Solidity 0.8.28"/>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"/>
</p>

---

## Overview

HTLC-based escrow system for trustless cross-chain settlement on any EVM chain. Supports ERC20 tokens and native ETH. Funds are locked in deterministic minimal-proxy escrows — the recipient **claims** by revealing a SHA-256 preimage, or the creator **refunds** after a block-based expiry.

## Key Features

- **Deterministic escrow addresses** — predict the escrow address before funding, enabling pre-funded workflows
- **Four creation paths** — pre-fund, native ETH call, EIP-2612 permit, and EIP-712 signed (relayer-friendly)
- **Batch creation** — deploy multiple escrows atomically in a single transaction
- **Pausable** — owner can halt new escrow creation without affecting existing claims/refunds
- **Fee-on-transfer protection** — post-transfer balance checks reject deflationary tokens
- **100% test coverage** — 97 tests across unit, integration, and fuzz suites

## Contracts

| Contract | Path | Description |
|---|---|---|
| **EscrowFactory** | `src/EscrowFactory.sol` | Factory and entry point. Deploys deterministic escrow clones, manages token whitelist, validates EIP-712 signatures. |
| **EscrowVault** | `src/EscrowVault.sol` | Minimal proxy clone per escrow. Holds funds with hash-lock (`claim`) and time-lock (`refund`) settlement. |

## API Reference

### EscrowFactory

| Function | Description |
|---|---|
| `createEscrow(...)` | Create a pre-funded escrow (creator transfers tokens to predicted address first) |
| `createEscrowNative(...)` | Create a native ETH escrow in one transaction via `msg.value` |
| `createEscrowPermit(...)` | Create an ERC20 escrow using EIP-2612 permit (gasless approval) |
| `createEscrowSigned(...)` | Create an ERC20 escrow via EIP-712 signature (relayer can submit) |
| `createEscrowBatch(...)` | Create multiple pre-funded escrows atomically |
| `getEscrowAddress(...)` | Predict the deterministic escrow address before funding |
| `whitelistToken(address)` | Add a token to the allowed list (owner only) |
| `delistToken(address)` | Remove a token from the allowed list (owner only) |
| `pause()` / `unpause()` | Toggle escrow creation (owner only) |
| `incrementNonce()` | Invalidate all pending EIP-712 signatures |

### EscrowVault

| Function | Description |
|---|---|
| `claim(bytes preimage)` | Recipient claims funds by revealing the SHA-256 preimage |
| `refund()` | Creator reclaims funds after the expiry window has passed |
| `getEscrowParameters()` | Returns immutable escrow params: `token`, `creator`, `recipient`, `expiryBlocks`, `commitmentHash` |

## Security

| Mechanism | Detail |
|---|---|
| **Hash-lock** | SHA-256 commitment — only the preimage holder can claim |
| **Time-lock** | Block-based expiry window for creator refunds |
| **Settlement guard** | `s_settled` flag enforces single-use (no double-spend or re-entrancy) |
| **Replay protection** | Per-creator nonces for EIP-712 signed creation |
| **Commitment validation** | Zero-hash commitments rejected at creation |
| **Gas-limited transfers** | 30,000 gas cap on native ETH transfers (smart contract wallet compatible) |
| **SafeERC20** | All ERC20 interactions via OpenZeppelin's SafeERC20 |

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install

```bash
git clone <repo-url>
cd evm_escrow
forge install
```

### Build & Test

```bash
forge build
forge test
forge coverage
```

### Deploy

```bash
forge script script/DeployRegistry.s.sol --sig "run(address)" <OWNER_ADDRESS> \
  --rpc-url <RPC_URL> --broadcast --verify
```

## Project Structure

```
src/
  EscrowFactory.sol        Factory — escrow creation, token whitelist, signature verification
  EscrowVault.sol          Escrow — claim, refund, immutable clone args
test/
  Escrow.t.sol             97 tests (unit + integration + fuzz)
script/
  DeployRegistry.s.sol     Production deploy script
  DeployErc20Tokens.s.sol  ERC20 token deployment (USDC, WBTC)
```

## Dependencies

| Package | Version | Usage |
|---|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | 5.x | `Ownable`, `SafeERC20`, `ECDSA`, `EIP712`, `Clones` |
| [OpenZeppelin Contracts Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) | 5.x | `Initializable` |
| [Forge Std](https://github.com/foundry-rs/forge-std) | Latest | Test framework |

## License

[MIT](LICENSE)

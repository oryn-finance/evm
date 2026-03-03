# Changelog

All notable changes to the EVM Atomic Swap Escrow contracts are documented in this file.

## [Unreleased]

### Added

- **`createTokenSwapVaultBatch`** — Create multiple pre-funded vaults in a single transaction via `VaultParams[]` struct array. Supports both ERC20 and native ETH. Atomic — reverts entirely if any vault fails.
- **`incrementNonce()`** — Allows creators to bump their nonce, instantly invalidating all pending EIP-712 signed vault authorizations
- **`Pausable` circuit breaker** — Owner can `pause()` / `unpause()` all vault creation. Does not affect existing vault `withdraw()` or `cancelSwap()` operations.
- **Richer `VaultCreated` event** — Now includes `recipient`, `commitmentHash`, `expiryBlocks`, and `amount` alongside the 3 indexed fields (`vaultAddress`, `creator`, `token`)

### Security

- **Settlement guard** — Added `s_settled` flag to `TokenDepositVault` preventing double-withdraw, double-cancel, and withdraw-after-cancel attacks
- **Commitment hash validation** — `bytes32(0)` commitment hashes are now rejected at vault creation in `SwapRegistry._getVaultArgsAndSalt`
- **EIP-712 nonce replay protection** — Per-creator `s_nonces` mapping added to `SwapRegistry`; each signed vault creation increments the nonce
- **Native ETH gas limit** — Increased `.call` gas stipend from 5,000 to 30,000 to support smart contract wallets with non-trivial `receive()` logic

### Changed

- **`getSwapParameters()` visibility** — Changed from `internal` to `public` so off-chain tools can read vault parameters
- **Import paths normalised** — All imports now use `@openzeppelin/contracts/...` remappings instead of relative `../lib/...` paths
- **`safeParams` modifier refactored** — Extracted validation logic into `_safeParams` internal function
- **Function naming** — Renamed `_createERC20VaultFromCreator` → `_createErc20VaultFromCreator` for consistent casing
- **`CREATE_VAULT_TYPEHASH` updated** — Now includes `uint256 nonce` field
- **`foundry.toml` cleaned up** — Removed commented-out settings

### Tests

- Expanded test suite to **95 tests** (unit, integration, and fuzz)
- Added batch vault creation tests (success, empty array, atomicity, pause guard, withdraw, native ETH, events, invalid params)
- Added pause/unpause tests (owner-only, blocks all 4 creation paths, allows withdraw/cancel while paused)
- Added `incrementNonce` tests (nonce bump, signature invalidation)
- Added richer `VaultCreated` event emission test
- Added settlement guard tests (double-withdraw, double-cancel, withdraw-after-cancel)
- Added third-party caller tests for `withdraw`
- Added event emission tests for `Withdraw` and `Cancel`
- Added `safeParams` revert tests for permit and signed flows
- Added nonce replay protection tests
- Added `getSwapParameters` public getter test
- Added 5 fuzz tests (amounts, expiry bounds, commitment brute-force, boundary conditions)
- Achieved **100% coverage** on lines, statements, branches, and functions for both source contracts
- Eliminated all compiler warnings in test file

## [0.1.0] — Initial Release

### Added

- `SwapRegistry` factory contract with four vault creation paths:
  - `createTokenSwapVault` — pre-funded ERC20 / native ETH
  - `createTokenSwapVaultNativeCall` — native ETH in one transaction
  - `createTokenSwapVaultPermit` — ERC20 with EIP-2612 gasless approval
  - `createTokenSwapVaultSigned` — relayer-submitted ERC20 via EIP-712 signature
- `TokenDepositVault` minimal proxy clone with:
  - SHA-256 hash-locked withdrawal
  - Block-based expiry cancellation
  - Dual asset support (ERC20 + native ETH)
- Owner-controlled token whitelist
- Deterministic vault addresses via `cloneDeterministicWithImmutableArgs`
- Fee-on-transfer token protection
- Deploy scripts (`DeployRegistry.s.sol`, `DeployMockTokens.s.sol`)

# Changelog

All notable changes to the EVM Atomic Swap Escrow contracts are documented in this file.

## [Unreleased]

### Added

- **`createEscrowBatch`** — Create multiple pre-funded escrows in a single transaction via `EscrowParams[]` struct array. Supports both ERC20 and native ETH. Atomic — reverts entirely if any escrow fails.
- **`incrementNonce()`** — Allows creators to bump their nonce, instantly invalidating all pending EIP-712 signed escrow authorizations
- **`Pausable` circuit breaker** — Owner can `pause()` / `unpause()` all escrow creation. Does not affect existing escrow `claim()` or `refund()` operations.
- **Richer `EscrowCreated` event** — Now includes `recipient`, `commitmentHash`, `expiryBlocks`, and `amount` alongside the 3 indexed fields (`escrowAddress`, `creator`, `token`)
- **Separate whitelist/delist events** — `TokenWhitelisted` and `TokenDelisted` replace the single `WhitelistedToken` event for clear indexer differentiation

### Security

- **Settlement guard** — Added `s_settled` flag to `EscrowVault` preventing double-claim, double-refund, and claim-after-refund attacks
- **Commitment hash validation** — `bytes32(0)` commitment hashes are now rejected at escrow creation in `EscrowFactory._getEscrowArgsAndSalt`
- **EIP-712 nonce replay protection** — Per-creator `s_nonces` mapping added to `EscrowFactory`; each signed escrow creation increments the nonce
- **Native ETH gas limit** — Increased `.call` gas stipend from 5,000 to 30,000 to support smart contract wallets with non-trivial `receive()` logic

### Changed

- **Naming standardised to escrow/HTLC conventions** — `SwapRegistry` → `EscrowFactory`, `TokenDepositVault` → `EscrowVault`, `withdraw()` → `claim()`, `cancelSwap()` → `refund()`, `VaultCreated` → `EscrowCreated`, `Withdraw` → `Claimed`, `Cancel` → `Refunded`
- **`getEscrowParameters()` visibility** — Changed from `internal` to `public` so off-chain tools can read escrow parameters
- **Import paths normalised** — All imports now use `@openzeppelin/contracts/...` remappings instead of relative `../lib/...` paths
- **`safeParams` modifier refactored** — Extracted validation logic into `_safeParams` internal function
- **Function naming** — Renamed `_createERC20VaultFromCreator` → `_createErc20EscrowFromCreator` for consistent casing
- **`CREATE_ESCROW_TYPEHASH` updated** — Now includes `uint256 nonce` field
- **`whitelistToken(address, bool)` split** — Replaced with `whitelistToken(address)` and `delistToken(address)` for explicit intent
- **`NATIVE_TOKEN` constant in `EscrowVault`** — Extracted hard-coded sentinel address into a named constant, eliminating duplication with `EscrowFactory`
- **Variable naming** — Fixed `expiryblocks` → `expiryBlocks` in `EscrowVault.refund()` for consistent camelCase
- **Error selector comments** — Added missing `// 0x...` hex selectors for `EscrowFactory__InvalidCommitmentHash`, `EscrowFactory__EmptyBatch`, and `EscrowVault__EscrowAlreadySettled`
- **Test naming standardised** — All test functions now follow `test_<subject>_<Behavior>` pattern with consistent `Reverts` verb; fixed typos (`witdraw`, `depositinto`, `WIthOut`, `timelock`)
- **`minttoken()` → `mintToken()`** — Fixed camelCase in `DeployMockTokens.s.sol` mock token contracts
- **`foundry.toml` cleaned up** — Removed commented-out settings

### Tests

- Expanded test suite to **97 tests** (unit, integration, and fuzz)
- Added batch escrow creation tests (success, empty array, atomicity, pause guard, claim, native ETH, events, invalid params)
- Added pause/unpause tests (owner-only, blocks all 4 creation paths, allows claim/refund while paused)
- Added `incrementNonce` tests (nonce bump, signature invalidation)
- Added richer `EscrowCreated` event emission test
- Added `TokenWhitelisted` / `TokenDelisted` event emission tests
- Added `delistToken` owner-only access test
- Added settlement guard tests (double-claim, double-refund, claim-after-refund)
- Added third-party caller tests for `claim`
- Added event emission tests for `Claimed` and `Refunded`
- Added `safeParams` revert tests for permit and signed flows
- Added nonce replay protection tests
- Added `getEscrowParameters` public getter test
- Added 5 fuzz tests (amounts, expiry bounds, commitment brute-force, boundary conditions)
- Achieved **100% coverage** on lines, statements, branches, and functions for both source contracts
- Eliminated all compiler warnings in test file

## [0.1.0] — Initial Release

### Added

- `EscrowFactory` factory contract with four escrow creation paths:
  - `createEscrow` — pre-funded ERC20 / native ETH
  - `createEscrowNative` — native ETH in one transaction
  - `createEscrowPermit` — ERC20 with EIP-2612 gasless approval
  - `createEscrowSigned` — relayer-submitted ERC20 via EIP-712 signature
- `EscrowVault` minimal proxy clone with:
  - SHA-256 hash-locked claim
  - Block-based expiry refund
  - Dual asset support (ERC20 + native ETH)
- Owner-controlled token whitelist
- Deterministic escrow addresses via `cloneDeterministicWithImmutableArgs`
- Fee-on-transfer token protection
- Deploy scripts (`DeployRegistry.s.sol`, `DeployMockTokens.s.sol`)

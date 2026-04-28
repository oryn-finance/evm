# Security Review — Oryn EVM Contracts

**Date:** 2026-04-28
**Reviewer:** Manual audit using Trail of Bits methodology (token-integration-analyzer, entry-point-analyzer, code-maturity, building-secure-contracts checklists), plus automated pass with `slither 0.11.5` + `slitherin` community detectors against `solc 0.8.28`.
**Tooling note:** Two `slitherin` detectors (`pess-nft-approve-warning`, `pess-public-vs-external`) crashed under Python 3.14 — they were excluded. Re-running on Python 3.11 would cover those.

## Scope

~1,700 LoC across 6 contracts:

- `src/EscrowFactory.sol`
- `src/EscrowVault.sol`
- `src/ICMBridgeFactory.sol`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol`
- `ictt/src/BridgeableERC20.sol`

## Entry-point map

| Contract | External / Public state-changing | Access |
|---|---|---|
| EscrowFactory | `pause`, `unpause`, `whitelistToken`, `delistToken` | `onlyOwner` |
| EscrowFactory | `createEscrow`, `createEscrowBatch`, `createEscrowNative`, `createEscrowPermit`, `createEscrowSigned` | Public (whenNotPaused) |
| EscrowVault | `initialize` | initializer (factory only in practice) |
| EscrowVault | `claim`, `refund` | Public (gated by preimage / expiry) |
| AvalancheEscrowFactory | mirrors EscrowFactory (with `EscrowParams` calldata struct + `l1Hop` flag) | same as above |
| AvalancheEscrowVault | `initialize`, `claim`, `claimHop`, `refund` | initializer / public (gated) |
| ICMBridgeFactory | `pause`, `unpause`, `registerRoute`, `updateRoute`, `deregisterRoute` | `onlyOwner` |
| ICMBridgeFactory | `bridge` | Public (whenNotPaused) |
| BridgeableERC20 | none beyond standard ERC20 | — |

---

## Automated scan summary (slither + slitherin)

Detectors that fired on `src/`:

| Detector | Where | Triage |
|---|---|---|
| `arbitrary-send-erc20` | `_createErc20EscrowFromCreator` (both factories) | **By design** — relayer pattern; signature/permit verified before transferFrom. See *Non-finding A*. |
| `arbitrary-send-eth` | `createEscrowNative` (both factories) | **Bounded false positive** — destination is the deterministic CREATE2 clone address, no code at call time. See *L-1*. |
| `reentrancy-eth` | `createEscrowNative` | **False positive** — destination is a freshly-predicted CREATE2 address with no code; cannot reenter. |
| `pess-arbitrary-call` (slitherin) | `createEscrowNative` | Same as above; flags the gas-limited call. See *L-1*. |
| `reentrancy-benign` | `createEscrowPermit` (both factories) | **New finding M-5** below — token.permit() is an external call before state writes. |
| `reentrancy-events` | `claim`, `refund`, `claimHop`, `bridge`, `createEscrowNative`, `createEscrowPermit` | Events emitted after external calls; informational. |
| `calls-loop` | `createEscrowBatch` (both factories) | **New finding I-7** below — `balanceOf` per iteration; one bad token DoS's the whole batch. |
| `unused-return` | `_deployEscrow` ignoring `functionCall` result | **New finding I-8** below — switch to typed call. |
| `return-bomb` | `createEscrowNative` gas-limited call | Informational; with `gas:8000` callee can't return meaningful data. |

Crashes (Python 3.14 + slitherin incompatibility): `pess-nft-approve-warning`, `pess-public-vs-external` did not run.

---

## Findings

### HIGH

#### H-1 — Permit DoS / griefing in `createEscrowPermit`

**Files:** `EscrowFactory.sol:457`, `AvalancheEscrowFactory.sol:350`

`_executePermit` calls `IERC20Permit.permit(...)` unconditionally. Any third party who observes a creator's permit signature in the mempool can front-run by calling `permit(...)` directly on the token, consuming the nonce. The relayer's `createEscrowPermit` then reverts in the `catch`, surfacing `PermitFailed`. Standard mitigation:

```solidity
if (IERC20(token).allowance(creator, address(this)) < amount) {
    try IERC20Permit(token).permit(...) { } catch { revert PermitFailed(); }
}
```

This is a known, repeatedly exploited pattern (Uniswap Permit2, 1inch, etc.).

#### H-2 — `claimHop` trusts an arbitrary `bridgeFactory` address

**File:** `AvalancheEscrowVault.sol:192-238`

`HopData.bridgeFactory` is supplied by the caller and only checked via the recipient's signature. There is no whitelist of legitimate `IICMBridgeFactory` addresses. The vault then calls `forceApprove(_hopData.bridgeFactory, vaultBalance)` and `bridgeFactory.bridge(...)`. If the recipient's key is compromised — or the recipient is socially engineered into signing a malicious `HopData` — the entire vault balance is approved to and pulled by an attacker-controlled contract. Recommend either:

- store an immutable allowlist of bridge factories (set by `AvalancheEscrowFactory` and burned into the clone args), or
- require the vault's creator to also co-sign the hop authorization, or
- have `AvalancheEscrowFactory` maintain a `s_authorizedBridgeFactories` mapping that the vault checks.

This is the largest open attack surface in the new Avalanche path.

---

### MEDIUM

#### M-1 — Pre-funded escrow balance accepted as "≥ amount" makes donation/over-funding pay out to recipient

**Files:** `EscrowFactory.sol:243-246, 281-284`, `AvalancheEscrowVault.sol:174-179`

Both `claim` and `refund` transfer `IERC20(token).balanceOf(address(this))`, not the original `amount`. If anyone (creator, attacker, or accidental sender) over-funds the deterministic vault address before settlement, the recipient (or creator on refund) sweeps the entire balance. Funds are not stuck, but the *legitimate* depositor of the surplus loses them. Consider storing `amount` as an immutable arg and capping payouts.

#### M-2 — No upper bound on `expiryBlocks` enables refund overflow lock

**Files:** `EscrowFactory.sol:167`, `AvalancheEscrowVault.sol:247`

`block.number >= s_depositedAt + expiryBlocks` reverts on overflow under Solidity 0.8.x. A creator who passes `expiryBlocks` close to `type(uint256).max` makes refund permanently unreachable. This is mainly a footgun (creator hurts themselves), but for `createEscrowSigned` / `createEscrowPermit` a malicious *relayer* could shape parameters and trick a careless signer. Add an upper bound (e.g. `expiryBlocks <= MAX_EXPIRY`).

#### M-3 — `createEscrowSigned` / `createEscrowPermit` signatures cannot be cancelled

**Files:** `EscrowFactory.sol:418-432`, `AvalancheEscrowFactory.sol:319-334`

The EIP-712 struct hash has no `nonce`, no `deadline`, and the only thing preventing replay is `s_deployedEscrows[addr]`. Once a creator signs, a relayer can submit at any future point as long as the creator still has the matching token approval. There is no on-chain cancellation primitive. Add either:

- a per-creator nonce (`mapping(address => uint256) s_nonces`), or
- a `deadline` field included in the EIP-712 hash and checked on chain, or
- a `cancelEscrowSignature(bytes32 structHash)` function gated to `msg.sender == creator`.

#### M-5 — Reentrancy via malicious / hooked ERC20 in `createEscrowPermit` (slither: `reentrancy-benign`)

**Files:** `EscrowFactory.sol:337-353` → `_executePermit:457-465`, `AvalancheEscrowFactory.sol:263-275` → `_executePermit:350-358`

`_executePermit` calls `IERC20Permit(token).permit(...)` — an external call to a token chosen from the whitelist — *before* `s_deployedEscrows[addr] = true` is written. A whitelisted token whose `permit()` reenters the factory (e.g. an upgradable token whose new implementation invokes `createEscrow*` for a different escrow) can interleave state with the in-flight escrow. The whitelist is the only mitigation; if the protocol ever lists a token whose code can change (proxied tokens, USDC-style admin upgrades), this becomes exploitable.

Mitigation:
- Add `nonReentrant` to all `createEscrow*` functions (cheapest fix), or
- Move the deterministic-address check + `s_deployedEscrows[addr] = true` *before* `_executePermit`. Note this requires careful refactoring of `_deployEscrow` to avoid double-writes.

#### M-4 — Anyone can deploy an escrow on a creator's behalf once the predicted address is funded

**File:** `EscrowFactory.sol:225` (`createEscrow`)

`createEscrow` has no `msg.sender == creator` check (and intentionally so, for relayer flows), but neither the signed nor the permit variant is required for plain `createEscrow`. A creator who pre-funds the predicted address as part of an off-chain flow has no way to abort if they change their mind — anyone can finalize the escrow against them. Acceptable design for the HTLC use case, but document it loudly; right now the natspec just says "Creator must pre-fund the predicted escrow address before calling".

---

### LOW

#### L-1 — Hard-coded `gas: 8000` on native sends is a footgun

**Files:** `EscrowFactory.sol:320`, `EscrowVault.sol:115,139`, `AvalancheEscrowFactory.sol:255`, `AvalancheEscrowVault.sol:175,252`

`addr.call{value: ..., gas: 8000}("")`. For an undeployed clone address this is fine, but on `claim` / `refund` the `recipient` / `creator` is arbitrary. 8000 gas is below the 21k base intrinsic, but enough for a non-payable contract to revert and possibly enough for a multisig fallback to enter — the choice is unusual and inconsistent with the typical 2300-stipend or unlimited forward. If the recipient is a smart account / Gnosis Safe / fallback-using contract, settlement may permanently revert and the only recovery is `refund` (which has the same gas limit). Either remove the limit, raise it, or document the recipient-is-EOA assumption.

#### L-2 — `_verifyHopSignature` uses `MessageHashUtils.toEthSignedMessageHash` (EIP-191), not EIP-712

**File:** `AvalancheEscrowVault.sol:298-312`

The factory signs with EIP-712 but the vault uses EIP-191 personal-sign for hop authorization — the natspec acknowledges this as a deliberate choice, but signers will see an opaque hex blob in their wallet (no domain, no struct). Worth either upgrading to EIP-712 (the typehash is already defined) or being explicit in client-side signing UX.

#### L-3 — `BridgeableERC20` decimals are stored, not constant

**File:** `ictt/src/BridgeableERC20.sol:13,27`

`_decimals` is in storage but only ever set in the constructor. Make it `immutable` to save an SLOAD per `decimals()` call (cheap fix). The contract self-declares "NOT audited for production"; if you do plan to deploy it, also consider whether an `Ownable` mint or supply cap is needed.

#### L-4 — `delistToken` does not affect already-deployed escrows

Only escrow *creation* respects the whitelist; existing escrows for delisted tokens continue to claim/refund normally. This is correct behavior, but worth a one-line comment so future readers don't expect a kill-switch.

#### L-5 — `getEscrowAddress` reverts on already-deployed escrow

**Files:** `EscrowFactory.sol:392-409`, `AvalancheEscrowFactory.sol:293-304`

Pure view utility; reverting prevents off-chain scripts from looking up the address of an *existing* escrow. Make it return the address regardless and let callers check `s_deployedEscrows` separately.

---

### INFORMATIONAL / CODE QUALITY

- **I-1** — `registerRoute` and `updateRoute` are 95% duplicated; collapse via a single internal `_setRoute`.
- **I-2** — `safeParams` / `_safeParams` exists in both factories with identical bodies — extract into a shared library.
- **I-3** — `s_routes[token][destBlockchainId].active` doubles as an existence flag; consider an explicit `exists` boolean or store-by-index pattern for cleaner semantics.
- **I-4** — `ICMBridgeFactory.bridge` hard-codes `secondaryRelayerFee = 0` and `multiHopFallback = address(0)`; if multi-hop support is on the roadmap, surface these as parameters now to avoid an interface migration later.
- **I-5** — `EscrowVault.initialize` is `public`; making it `external` saves a small amount of gas on deployment of the implementation.
- **I-6** — Several errors are defined but never compared for selector collisions — duplicates are unlikely with the current naming, but adding `// 0x...` selector comments (which the codebase already does) is good; keep them in sync if signatures change.
- **I-7** — `createEscrowBatch` does an external `balanceOf` per iteration (slither: `calls-loop`). One bad token (revert in `balanceOf`) DoS's the entire batch; consider isolating each escrow with try/catch or processing per-token.
- **I-8** — `_deployEscrow` uses `escrow.functionCall(abi.encodeCall(EscrowVault.initialize, ()))` and discards the returned bytes (slither: `unused-return`). `initialize()` returns nothing today, but a typed call (`EscrowVault(escrow).initialize()`) is safer if the implementation ever changes signature.
- **I-9** — `reentrancy-events` fires on `claim`, `refund`, `claimHop`, and `bridge`: events are emitted *after* the external value transfer / bridge call. Indexers may observe out-of-order events if the post-call frame reverts. Move emits before the transfer or accept current ordering as tolerable.

---

### NON-FINDINGS (verified safe)

- Solidity 0.8.28 overflow checks cover all arithmetic; no SafeMath needed.
- `s_settled = true` is set *before* every external transfer/bridge → reentrancy via ERC777 / malicious tokens cannot double-claim.
- `EIP712` domain names differ between the two factories → cross-factory signature replay is impossible.
- `claimHop` signature includes `chainId` and `address(this)` → cross-chain and cross-vault replay are blocked.
- `forceApprove` is the recommended pattern for tokens that disallow non-zero→non-zero allowance changes.
- `_disableInitializers()` in both vaults' constructors prevents the implementation from being initialized.
- CREATE2 collisions are infeasible given the salt scheme (`chainid, token, creator, recipient, expiryBlocks, commitmentHash[, l1Hop]`).
- `ECDSA.parseCalldata` handles both 65-byte and 64-byte (EIP-2098) signatures and returns zeros on invalid lengths, which causes `permit()` verification to fail safely.
- **Non-finding A** (slither `arbitrary-send-erc20` on `_createErc20EscrowFromCreator`): `safeTransferFrom(creator, addr, amount)` uses an arbitrary `from`. This is the *intended* relayer pattern — the call site is reached only after `_executePermit` (which authenticates `creator` via EIP-2612 signature) or `_verifyCreateEscrowSignature` (which authenticates via EIP-712). A creator who has not signed and not pre-approved cannot have funds pulled.
- **Non-finding B** (slither `reentrancy-eth` on `createEscrowNative`): the `addr.call{gas:8000, value:amount}("")` targets a CREATE2-derived address that has *no code* at the time of the call (the clone is deployed two lines later). Reentrancy is impossible with no code at the destination. Tracked separately as L-1 (the gas:8000 limit being unusual).
- **Non-finding C** (slither `return-bomb`): with `gas:8000`, the callee cannot construct large returndata. The current call ignores the return value entirely (only `success` is captured), so even unbounded returndata would not be allocated.

---

## Recommended next steps

1. Fix **H-1** (permit allowance check) — trivial, high impact.
2. Decide on the **H-2** trust model for `bridgeFactory` (whitelist vs. co-signature).
3. Add `nonReentrant` guard for **M-5**, the missing nonce/deadline (**M-3**), and `expiryBlocks` cap (**M-2**) before mainnet.
4. Re-run slither under Python 3.11 (or pin slitherin) to recover `pess-nft-approve-warning` and `pess-public-vs-external` detector coverage.
5. Optional: add a CI step that fails on new slither high/medium findings (`slither . --fail-medium`).

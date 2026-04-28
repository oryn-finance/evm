# Invariant Map

> Oryn Escrow | 54 guards | 11 inferred | 4 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`recipient != address(0) && creator != address(0) && creator != recipient` - `src/EscrowFactory.sol:163` - prevents unusable or self-directed standard escrow parties.

#### G-2
`expiryBlocks > 0` - `src/EscrowFactory.sol:167` - prevents immediately expired standard escrows.

#### G-3
`amount > 0` - `src/EscrowFactory.sol:168` - prevents zero-value standard escrow creation.

#### G-4
`s_whitelistedTokens[token]` - `src/EscrowFactory.sol:233` - gates standard prefunded creation to owner-approved assets.

#### G-5
`!s_deployedEscrows[addr]` - `src/EscrowFactory.sol:240` - preserves one deployment per deterministic standard escrow address.

#### G-6
`address(addr).balance >= amount` - `src/EscrowFactory.sol:243` - confirms native prefunding before clone deployment.

#### G-7
`IERC20(token).balanceOf(addr) >= amount` - `src/EscrowFactory.sol:245` - confirms ERC20 prefunding before clone deployment.

#### G-8
`length > 0` - `src/EscrowFactory.sol:263` - prevents empty standard batch calls.

#### G-9
`s_whitelistedTokens[p.token]` - `src/EscrowFactory.sol:271` - gates each standard batch item to owner-approved assets.

#### G-10
`!s_deployedEscrows[addr]` - `src/EscrowFactory.sol:278` - preserves one deployment per standard batch item address.

#### G-11
`address(addr).balance >= p.amount` - `src/EscrowFactory.sol:281` - confirms native batch prefunding.

#### G-12
`IERC20(p.token).balanceOf(addr) >= p.amount` - `src/EscrowFactory.sol:283` - confirms ERC20 batch prefunding.

#### G-13
`token == NATIVE_TOKEN` - `src/EscrowFactory.sol:309` - restricts payable standard creation to the native sentinel.

#### G-14
`msg.value == amount` - `src/EscrowFactory.sol:310` - keeps native deposit amount aligned with escrow amount.

#### G-15
`s_whitelistedTokens[token]` - `src/EscrowFactory.sol:311` - gates native standard creation to an approved sentinel.

#### G-16
`!s_deployedEscrows[addr]` - `src/EscrowFactory.sol:319` - prevents duplicate native standard deployment.

#### G-17
`success` - `src/EscrowFactory.sol:321` - requires native prefund call to the predicted address to succeed.

#### G-18
`token != NATIVE_TOKEN` - `src/EscrowFactory.sol:347` - keeps permit creation on ERC20 assets.

#### G-19
`s_whitelistedTokens[token]` - `src/EscrowFactory.sol:348` - gates permit creation to approved ERC20s.

#### G-20
`token != NATIVE_TOKEN` - `src/EscrowFactory.sol:374` - keeps signed creation on ERC20 assets.

#### G-21
`s_whitelistedTokens[token]` - `src/EscrowFactory.sol:375` - gates signed creation to approved ERC20s.

#### G-22
`signer == creator` - `src/EscrowFactory.sol:431` - binds signed standard creation parameters to the creator.

#### G-23
`!s_deployedEscrows[addr]` - `src/EscrowFactory.sol:447` - prevents duplicate ERC20 deployment after permit/signed transfer.

#### G-24
`IERC20(token).balanceOf(addr) >= amount` - `src/EscrowFactory.sol:450` - rejects ERC20 creation when the clone received less than the requested amount.

#### G-25
`commitmentHash != bytes32(0)` - `src/EscrowFactory.sol:495` - prevents trivially empty standard commitment hashes.

#### G-26
`!s_settled` - `src/EscrowVault.sol:106` - prevents double settlement on standard claim.

#### G-27
`sha256(abi.encodePacked(_commitment)) == commitmentHash` - `src/EscrowVault.sol:110` - enforces the standard hash-lock.

#### G-28
`success` - `src/EscrowVault.sol:116` - requires native claim payout to succeed.

#### G-29
`!s_settled` - `src/EscrowVault.sol:128` - prevents double settlement on standard refund.

#### G-30
`block.number >= s_depositedAt + expiryBlocks` - `src/EscrowVault.sol:134` - unlocks refund only after the stored block window.

#### G-31
`success` - `src/EscrowVault.sol:140` - requires native refund payout to succeed.

#### G-32
`token != address(0) && tokenTransferrer != address(0) && destTransferrer != address(0)` - `src/ICMBridgeFactory.sol:169` - prevents unusable bridge route endpoints.

#### G-33
`destBlockchainId != bytes32(0)` - `src/ICMBridgeFactory.sol:173` - prevents zero destination chain IDs on route registration.

#### G-34
`requiredGasLimit > 0` - `src/ICMBridgeFactory.sol:174` - prevents routes with no delivery gas.

#### G-35
`!s_routes[token][destBlockchainId].active` - `src/ICMBridgeFactory.sol:175` - prevents accidental overwrite during route registration.

#### G-36
`token != address(0) && tokenTransferrer != address(0) && destTransferrer != address(0)` - `src/ICMBridgeFactory.sol:200` - prevents route updates to unusable endpoints.

#### G-37
`requiredGasLimit > 0` - `src/ICMBridgeFactory.sol:204` - prevents route updates with no delivery gas.

#### G-38
`s_routes[token][destBlockchainId].active` - `src/ICMBridgeFactory.sol:205` - ensures only existing routes are updated.

#### G-39
`s_routes[token][destBlockchainId].active` - `src/ICMBridgeFactory.sol:221` - ensures only existing routes are deleted.

#### G-40
`amount > 0` - `src/ICMBridgeFactory.sol:255` - prevents zero-value bridge dispatch.

#### G-41
`recipient != address(0)` - `src/ICMBridgeFactory.sol:256` - prevents bridging to the zero recipient.

#### G-42
`primaryRelayerFee == 0 || primaryFeeToken != address(0)` - `src/ICMBridgeFactory.sol:257` - requires an explicit fee token for nonzero relayer fees.

#### G-43
`route.active` - `src/ICMBridgeFactory.sol:260` - gates bridge dispatch to active owner-configured routes.

#### G-44
`s_whitelistedTokens[p.token]` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:187` - gates Avalanche prefunded creation to owner-approved assets.

#### G-45
`p.token != NATIVE_TOKEN` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:188` - prevents native-token hop escrows.

#### G-46
`!s_deployedEscrows[addr]` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:194` - preserves one deployment per Avalanche deterministic address.

#### G-47
`p.token == NATIVE_TOKEN` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:244` - restricts payable Avalanche creation to the native sentinel.

#### G-48
`!p.l1Hop` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:245` - prevents native-token hop creation.

#### G-49
`signer == p.creator` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:333` - binds signed Avalanche creation parameters to the creator.

#### G-50
`commitmentHash != bytes32(0)` - `src/AvalancheEscrows/AvalancheEscrowFactory.sol:380` - prevents trivially empty Avalanche commitment hashes.

#### G-51
`!s_settled` - `src/AvalancheEscrows/AvalancheEscrowVault.sol:165` - prevents double settlement on standard Avalanche claim.

#### G-52
`!l1Hop` - `src/AvalancheEscrows/AvalancheEscrowVault.sol:169` - routes non-hop vaults to the standard claim path.

#### G-53
`l1Hop` - `src/AvalancheEscrows/AvalancheEscrowVault.sol:197` - routes hop vaults to the bridge claim path.

#### G-54
`signer == recipient` - `src/AvalancheEscrows/AvalancheEscrowVault.sol:312` - binds hop destination and fee data to the immutable recipient.

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`StateMachine` - On-chain: **Yes**

> A standard escrow vault can settle at most once.

**Derivation** - edge: `s_settled == false` guarded at `src/EscrowVault.sol:106` and `src/EscrowVault.sol:128`, then written true at `src/EscrowVault.sol:112` and `src/EscrowVault.sol:136`; no writer resets it.

**If violated** - the same vault balance could be claimed/refunded through more than one settlement path.

---

#### I-2

`Temporal` - On-chain: **Yes**

> Standard refunds are unavailable until the initialized block plus immutable `expiryBlocks`.

**Derivation** - temporal: `s_depositedAt = block.number` at `src/EscrowVault.sol:92` and `require(block.number >= s_depositedAt + expiryBlocks)` at `src/EscrowVault.sol:134`.

**If violated** - creator refunds could execute before the intended timeout.

---

#### I-3

`StateMachine` - On-chain: **Yes**

> An Avalanche escrow vault can settle at most once across claim, claimHop, and refund.

**Derivation** - edge: `s_settled == false` guarded at `src/AvalancheEscrows/AvalancheEscrowVault.sol:165`, `:193`, and `:243`, then written true at `:172`, `:223`, and `:249`; no writer resets it.

**If violated** - the same vault balance could traverse more than one settlement path.

---

#### I-4

`Temporal` - On-chain: **Yes**

> Avalanche refunds are unavailable until the initialized block plus immutable `expiryBlocks`.

**Derivation** - temporal: `s_depositedAt = block.number` at `src/AvalancheEscrows/AvalancheEscrowVault.sol:155` and `require(block.number >= s_depositedAt + expiryBlocks)` at `src/AvalancheEscrows/AvalancheEscrowVault.sol:247`.

**If violated** - creator refunds could execute before the intended timeout.

---

#### I-5

`StateMachine` - On-chain: **Yes**

> A standard deterministic escrow address moves from undeployed to deployed once and is never cleared.

**Derivation** - edge: `!s_deployedEscrows[addr]` at `src/EscrowFactory.sol:240`, `:278`, `:319`, and `:447`, then `s_deployedEscrows[escrow] = true` at `src/EscrowFactory.sol:477`; no delete/reset writer exists.

**If violated** - clone address reuse could overwrite the one-escrow-per-address lifecycle.

---

#### I-6

`StateMachine` - On-chain: **Yes**

> An Avalanche deterministic escrow address moves from undeployed to deployed once and is never cleared.

**Derivation** - edge: `!s_deployedEscrows[addr]` at `src/AvalancheEscrows/AvalancheEscrowFactory.sol:194`, `:226`, `:253`, `:301`, and `:341`, then `s_deployedEscrows[escrow] = true` at `src/AvalancheEscrows/AvalancheEscrowFactory.sol:366`; no delete/reset writer exists.

**If violated** - clone address reuse could overwrite the one-escrow-per-address lifecycle.

---

#### I-7

`Temporal` - On-chain: **No**

> Standard refund deadline arithmetic must remain evaluable for every accepted `expiryBlocks`.

**Derivation** - temporal: `expiryBlocks > 0` is the only creation bound at `src/EscrowFactory.sol:167`, while refund evaluates `s_depositedAt + expiryBlocks` at `src/EscrowVault.sol:134` in checked arithmetic.

**If violated** - an oversized expiry can make refund revert before the comparison and keep funds unrecoverable unless claim succeeds.

---

#### I-8

`Temporal` - On-chain: **No**

> Avalanche refund deadline arithmetic must remain evaluable for every accepted `expiryBlocks`.

**Derivation** - temporal: `expiryBlocks > 0` is the only creation bound at `src/AvalancheEscrows/AvalancheEscrowFactory.sol:315`, while refund evaluates `s_depositedAt + expiryBlocks` at `src/AvalancheEscrows/AvalancheEscrowVault.sol:247` in checked arithmetic.

**If violated** - an oversized expiry can make hop and non-hop refund paths revert before the comparison.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **No**

> Hop settlement assumes the signed `_hopData.bridgeFactory` is the intended `ICMBridgeFactory` implementation for the selected route.

**Caller side** - `src/AvalancheEscrows/AvalancheEscrowVault.sol:203-236` - verifies the recipient signature, approves `_hopData.bridgeFactory`, and calls `bridge()`.

**Callee side** - `src/ICMBridgeFactory.sol:247-295` - pulls tokens from `msg.sender`, checks `s_routes`, approves the route transferrer, and dispatches `send()`.

**If violated** - a recipient-signed hop authorization can intentionally route the vault through a different bridge factory address; the code relies on signer correctness rather than an on-chain factory registry.

---

## 4. Economic Invariants

#### E-1

On-chain: **Yes**

> A settled standard escrow pays the full current vault balance to exactly one immutable endpoint: recipient on claim or creator on refund.

**Follows from** - `I-1` + `I-2`

**If violated** - funds could be split, duplicated, or sent to an endpoint outside the clone args.

---

#### E-2

On-chain: **No**

> A hop escrow bridges through the route the recipient intended and then becomes permanently settled.

**Follows from** - `I-3` + `I-4` + `X-1`

**If violated** - hop settlement remains single-use, but the correctness of the destination route depends on the recipient-signed bridge factory and external ICTT route behavior.

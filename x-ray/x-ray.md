# X-Ray Report

> Oryn Escrow | 826 in-scope nSLOC | 2448c85 (`audit`) | Foundry | 28/04/26

---

## 1. Protocol Overview

**What it does:** HTLC escrow factories deploy deterministic clone vaults for token/native settlements, with an Avalanche-specific path that can route a claim through ICTT.

- **Users**: Creators fund escrows; recipients claim with a SHA-256 preimage or sign hop destination data; creators refund after expiry.
- **Core flow**: Factory validates parameters and funding, deploys a clone with immutable args, then the vault settles once through claim, claimHop, or refund.
- **Key mechanism**: Deterministic clone addresses plus hash-lock / block-time refund windows.
- **Token model**: Whitelisted ERC20s and a native-token sentinel; Avalanche hop mode is ERC20-only.
- **Admin model**: `Ownable` owner controls token whitelists, pause toggles, and ICTT bridge routes with no code-level timelock.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Standard HTLC | `EscrowFactory`, `EscrowVault` | 311 | Chain-agnostic deterministic escrow creation and settlement. |
| Avalanche HTLC hop | `AvalancheEscrowFactory`, `AvalancheEscrowVault` | 369 | Standard escrow plus optional ICTT claim routing. |
| ICTT route registry | `ICMBridgeFactory` | 146 | Pulls user/vault tokens and dispatches configured TokenTransferrer routes. |

### How It Fits Together

The core trick: each escrow is a clone whose immutable args define who can receive, who can refund, when refund unlocks, and which commitment unlocks the claim path.

### Standard pre-funded ERC20 escrow

```text
creator pre-funds predicted vault address
EscrowFactory.createEscrow()
  -> _getEscrowArgsAndSalt()
  -> balanceOf(predicted) >= amount
  -> _deployEscrow()
     -> EscrowVault.initialize()
```

*Funding is verified before deployment; the clone is then marked in `s_deployedEscrows`.*

### Signed or permit ERC20 escrow

```text
relayer/user calls createEscrowPermit() or createEscrowSigned()
  -> permit() or EIP-712 signer recovery
  -> safeTransferFrom(creator, predicted vault, amount)
  -> balanceOf(predicted) >= amount
  -> _deployEscrow()
```

*The signed path authorizes parameters, but the deterministic vault identity does not include `amount`.*

### Standard settlement

```text
EscrowVault.claim(preimage)
  -> sha256(preimage) == commitmentHash
  -> s_settled = true
  -> transfer full vault balance to recipient

EscrowVault.refund()
  -> block.number >= s_depositedAt + expiryBlocks
  -> s_settled = true
  -> transfer full vault balance to creator
```

*Both claim and refund are permissionless; value always goes to the immutable recipient or creator.*

### Avalanche hop settlement

```text
AvalancheEscrowVault.claimHop(preimage, recipientSig, hopData)
  -> verify preimage and recipient signature over hopData
  -> approve bridgeFactory for vaultBalance
  -> ICMBridgeFactory.bridge()
     -> pull tokens from vault
     -> approve route.tokenTransferrer
     -> TokenTransferrer.send()
```

*The recipient signature binds the destination, bridge factory, destination chain ID, fee token, and fee amount.*

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Bridge** with **HTLC escrow / atomic settlement** characteristics

The dominant code signals are cross-chain route configuration, ICTT `send()` dispatch, and hash/time locked escrow settlement. The standard escrow path is chain-agnostic, while the Avalanche path adds route and relayer dependencies.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|--------------|
| Owner | Trusted | Instant token whitelist changes, pause/unpause, and ICTT route register/update/delete; no code-level timelock. |
| Creator | Bounded (funds own escrow) | Funds predicted vaults, signs create messages, and receives refunds after the block expiry. |
| Recipient / redeemer | Bounded (needs secret/signature) | Claims with the preimage; for hop escrows signs destination and fee data. |
| Relayer / third-party caller | Permissionless | Can submit signed creation or settlement transactions, but value routes to immutable args. |
| ICTT / Teleporter stack | External trusted dependency | Executes lock/burn/mint message path after `ICMBridgeFactory.bridge()`. |
| ERC20 token | External dependency | Must obey SafeERC20-compatible transfers and expected balance behavior. |

**Adversary Ranking**

1. **Message/route attacker** - Relevant because ICTT route addresses and destination chain IDs define where bridged value is sent.
2. **Preimage observer / MEV searcher** - Can copy revealed secrets, so settlement must route value only to immutable recipients or signed hop destinations.
3. **Compromised owner** - Can instantly alter token allowlists and bridge routes without a timelock.
4. **Non-standard token issuer** - Accepted tokens can have fees, blacklists, rebases, paused transfers, or upgradeable behavior.
5. **Relayer/operator failure** - Hop claims depend on off-chain ICM delivery after the on-chain send is dispatched.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Owner boundary** - `Ownable` gates token and route configuration at `EscrowFactory:189-212`, `AvalancheEscrowFactory:165-180`, and `ICMBridgeFactory:147-222`; role transfer delay or multisig is not enforced in code.

- **Escrow commitment boundary** - `claim()`/`claimHop()` accept any caller but route funds to immutable recipients after SHA-256 preimage verification at `EscrowVault:110` and `AvalancheEscrowVault:170,198`.

- **Expiry boundary** - `refund()` is gated by `block.number >= s_depositedAt + expiryBlocks`, while claim paths have no corresponding "before expiry" check.

- **Bridge route boundary** - `ICMBridgeFactory.bridge()` trusts `s_routes[token][destBlockchainId]` for transferrer addresses and gas limit, then hands approval to the configured transferrer.

- **Recipient hop-authorization boundary** - `AvalancheEscrowVault.claimHop()` trusts `_hopData.bridgeFactory` and destination fields because the immutable recipient signed them.

### Key Attack Surfaces

- **Deterministic identity excludes amount** - `EscrowFactory:496-497` and `AvalancheEscrowFactory:381-382` omit `amount` from clone args/salt while public create/address APIs and signatures accept it; worth checking off-chain order uniqueness assumptions.

- **Permit-funded creation does not bind escrow terms** - `EscrowFactory:337-352` and `AvalancheEscrowFactory:263-274` use ERC-2612 permit only as allowance setup, so recipient, commitment, expiry, and hop mode are caller-controlled unless another authorization layer exists.

- **Expiry is refund eligibility, not claim cutoff** &nbsp;[[I-2](invariants.md#i-2), [I-4](invariants.md#i-4)] - `claim()` and `claimHop()` do not compare block number against expiry, so auditors should confirm intended HTLC timeout semantics.

- **Refund deadline arithmetic can overflow** &nbsp;[[I-7](invariants.md#i-7), [I-8](invariants.md#i-8)] - `refund()` adds `s_depositedAt + expiryBlocks`, while factories only require `expiryBlocks > 0`; oversized expiries should be bounded or compared by elapsed blocks.

- **Hop bridge factory is recipient-signed data** &nbsp;[[X-1](invariants.md#x-1)] - `AvalancheEscrowVault:203-236` binds `_hopData.bridgeFactory` by signature but does not restrict it to a factory registry.

- **ICTT approval handoff** - `ICMBridgeFactory:270-292` pulls tokens, sets exact approvals, and relies on `TokenTransferrer.send()` behavior; review route mutation and residual allowance behavior across token types.

- **Signed creation has no nonce or deadline** - `EscrowFactory:427-431` and `AvalancheEscrowFactory:320-333` bind parameters but not cancellation state; README/tests still reference removed nonce support.

- **Native transfer gas cap mismatch** - Native payouts and deposits use `gas: 8000` at `EscrowVault:115,139`, `AvalancheEscrowVault:175,252`, `EscrowFactory:320`, and `AvalancheEscrowFactory:255`, while README claims 30,000 gas.

- **Owner operational power without delay** - `ICMBridgeFactory:193-222` can update or delete routes instantly, and factory whitelists can be changed instantly.

### Protocol-Type Concerns

**As a Bridge:**
- `ICMBridgeFactory.bridge()` validates route activity but not the downstream transferrer's message semantics; ICTT/Teleporter correctness is outside this repo.
- `AvalancheEscrowVault.claimHop()` signs `block.chainid`, vault, commitment hash, bridge factory, destination chain ID, recipient, fee token, and fee amount, giving replay resistance inside that tuple.
- Bridge fees in a separate token are supported by direct `bridge()` users, but vault hop claims reject separate fee tokens because the vault only holds the escrow token.

**As an HTLC escrow:**
- `s_settled` is written before external payout/bridge calls, giving a clear single-settlement guard if downstream calls re-enter.
- Both claim and refund transfer the entire current vault balance, so direct token donations become part of the settlement balance.

### Temporal Risk Profile

**Deployment & Initialization:**
- `initialize()` is public but `initializer`-guarded and called immediately after clone deployment; uninitialized clone windows should be checked in deployment traces.
- Owner addresses are constructor-supplied, and the repo does not enforce a multisig/timelock handoff after deployment.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **ERC20 tokens** - via factories, vaults, and bridge factory
> - Assumes: SafeERC20-compatible transfer/approval behavior and meaningful `balanceOf`.
> - Validates: post-transfer/prefund balance checks on creation; no explicit rebase/blacklist/paused-token handling.
> - Mutability: token-specific; allowlist is owner-controlled.
> - On failure: SafeERC20 calls revert, or settlement remains uncompleted.

> **ICTT TokenTransferrer** - via `ICMBridgeFactory.bridge()`
> - Assumes: `send()` pulls exactly the approved tokens and emits a valid cross-chain message.
> - Validates: route active, nonzero route addresses at registration, required gas limit > 0.
> - Mutability: external Avalanche ICTT/Teleporter stack.
> - On failure: bridge transaction reverts.

> **Teleporter / ICM relayer** - after `send()`
> - Assumes: off-chain relayer delivery for destination execution.
> - Validates: none in this repo after message dispatch.
> - Mutability: external operational dependency.
> - On failure: source-chain send may succeed while destination delivery waits on relaying.

**Token Assumptions**:
- Fee-on-transfer tokens are rejected on factory-funded creation by post-transfer balance checks, but direct donations/rebases can still change the full vault balance paid out on settlement.
- Blacklistable or pausable tokens can block `claim`, `refund`, or `bridge` token transfers.

---

## 3. Invariants

> ### Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis.
>
> - **54 Enforced Guards** (`G-1` ... `G-54`) - per-call preconditions with check, location, and purpose
> - **8 Single-Contract Invariants** (`I-1` ... `I-8`) - state-machine and temporal properties
> - **1 Cross-Contract Invariant** (`X-1`) - scoped caller/callee assumption
> - **2 Economic Invariants** (`E-1` ... `E-2`) - settlement properties derived from invariants

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | Covers standard escrow and ICTT at a high level, but is stale on nonce support, gas cap, test count, and current contract set. |
| NatSpec | Adequate | Contract/function NatSpec is present across core files; no `@invariant` tags found. |
| Spec/Whitepaper | Missing | `docs/DEPLOY.md` is an operational guide, not a security spec. |
| Inline Comments | Adequate | Useful comments on hop signatures, expiry semantics, and ICTT fee handling. |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 3 | File scan |
| Test functions | 189 | `forge test --list --json` |
| Line coverage | 95.5% in `src/` (80.4% full Forge total) | Coverage tool |
| Branch coverage | 81.2% in `src/` (77.4% full Forge total) | Coverage tool |

### Test Depth

| Category | Count | Contracts Covered |
|----------|------:|-------------------|
| Unit | 176 | Escrow, Avalanche escrow, ICM bridge factory |
| Stateless Fuzz | 13 | Escrow creation/claim/refund, bridge amounts/fees/routes |
| Stateful Fuzz (Foundry) | 0 | none |
| Formal Verification | 0 | none |

### Gaps

- No stateful invariant tests were detected for lifecycle properties such as single settlement, route mutation, and deterministic address uniqueness.
- No formal verification harnesses were detected for signature domain separation, clone salt construction, or ICTT handoff assumptions.
- Coverage is strong for `src/`, but `AvalancheEscrowFactory` branch coverage is lower than the other in-scope contracts.

---

## 6. Developer & Git History

> Repo shape: normal_dev - 45 commits, 28 source-touching commits, and 159 days of visible history on branch `audit` at `2448c85`.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Additions |
|--------|--------:|--------------------|----------------------:|
| Pranav | 18 | +1862 / -390 | 83.0% |
| Sainath Reddy | 23 | +254 / -110 | 11.3% |
| PranavLakkadi13 | 1 | +127 / -28 | 5.7% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 5 | Small team, but source changes are concentrated. |
| Merge commits | 3 of 45 | Some branch integration history visible. |
| Repo age | 2025-11-20 -> 2026-04-28 | 159 days. |
| Recent source activity (30d) | 0 | No late source burst after 2026-03-29. |
| Test co-change rate | 75% | Source commits often changed tests too; measures co-modification, not coverage. |

### File Hotspots

| File | Modifications | Note |
|------|--------------:|------|
| `src/EscrowVault.sol` | 3 | Current in-scope settlement path. |
| `src/EscrowFactory.sol` | 3 | Current in-scope creation/signature path. |
| `src/AvalancheEscrows/AvalancheEscrowVault.sol` | 3 | Current in-scope hop settlement path. |
| `src/ICMBridgeFactory.sol` | 2 | Current in-scope bridge handoff path. |
| `src/AvalancheEscrows/AvalancheEscrowFactory.sol` | 2 | Current in-scope Avalanche creation path. |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 32c2994 | 2026-03-11 | added changes | 15 | Guards, token transfers, signatures, accounting. |
| 52369a9 | 2026-03-23 | Add: Avax hop escrow changes | 14 | Large bridge/HTLC feature addition with guards and tests. |
| 35ad0e4 | 2026-03-23 | Add: base registry for icm | 14 | Route registry and bridge fund-flow changes. |
| b429243 | 2026-03-27 | Enhance Avalanche escrow and bridge integration | 11 | Signature and fund-flow changes in hop vault. |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|---------------|--------:|-----------|
| fund_flows | 7 | Escrow factories/vaults, ICM bridge factory |
| access_control | 5 | Escrow factories, ICM bridge factory |
| signatures | 5 | Escrow factories, Avalanche vault |
| state_machines | 5 | Escrow factories, ICM bridge factory |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| icm-services | `lib/icm-services` | Avalanche ICTT/Teleporter | Submodule | Large external bridge dependency, compiled under separate profile. |
| openzeppelin-contracts | `lib/openzeppelin-contracts` | OpenZeppelin | Submodule | Standard dependency. |
| openzeppelin-contracts-upgradeable | `lib/openzeppelin-contracts-upgradeable` | OpenZeppelin | Submodule | Standard dependency for `Initializable`. |

### Security Observations

- **Source concentration** - Pranav accounts for 83% of source additions.
- **High fund-flow churn** - fund-flow code changed in 7 commits, including the Avalanche hop addition.
- **Docs drift** - README still references nonce support and a 30,000 gas cap that current source does not implement.
- **Removed-history hotspots** - git history includes removed `SwapRegistry`/`TokenDepositVault` churn, so current-scope review should focus on the escrow replacement paths.

### Cross-Reference Synthesis

- **Fund-flow churn plus hop bridge surface** - the highest-churn security domain routes into `AvalancheEscrowVault.claimHop()` and `ICMBridgeFactory.bridge()`.
- **Signature churn plus stale nonce docs** - signature-related commits align with the missing nonce/deadline surface in signed creation.
- **Route admin plus no timelock** - bridge route configuration is security-critical and remains instant owner power.

---

## X-Ray Verdict

**ADEQUATE** - Strong unit/fuzz coverage and readable NatSpec are offset by no stateful/formal invariant layer and instant owner powers over token/route configuration.

**Structural facts:**
1. 826 in-scope nSLOC across 5 protocol contracts.
2. 189 tests passed, including 13 Foundry fuzz tests.
3. In-scope source coverage is about 95.5% lines and 81.2% branches.
4. No stateful invariant tests or formal verification harnesses were detected.
5. Current branch history has 45 commits and 28 source-touching commits.

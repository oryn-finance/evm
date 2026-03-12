# ORYN ICTT Integration
### Wrappers, Adapters & Betterments for Avalanche L1 Bridging
*March 2026 | Complements AVALANCHE_ICTT_ARCHITECTURE.md*

---

## 1. ORYN Escrow vs ICTT — Different Purposes

| Aspect | ORYN Escrow | ICTT |
|---|---|---|
| **Use case** | HTLC atomic swap — lock until recipient claims with preimage or creator refunds | Simple token bridge — lock on home, mint on remote |
| **Flow** | Creator locks → Recipient `claim(preimage)` OR Creator `refund()` after expiry | User calls `send()` → ICM relayer → TokenRemote mints to recipient |
| **Chains** | Any EVM (Ethereum, Avalanche C-Chain, Avalanche L1s, etc.) | Avalanche C-Chain ↔ Avalanche L1s only |
| **Commitment** | Requires `commitmentHash`; recipient reveals preimage | No commitment; recipient is set at transfer time |
| **Trust** | Trustless — hash-lock + time-lock | Trustless — BLS validator signatures |

**Conclusion:** They are **orthogonal**. Use **Escrow** for atomic swaps (HTLC). Use **ICTT** for simple token transfers (C-Chain ↔ L1, L1 ↔ L1). No changes needed to EscrowFactory or EscrowVault for ICTT—they remain chain-agnostic.

---

## 2. Extend Existing Contracts (Preferred)

ORYN already deploys **EscrowFactory** on each chain as the central registry (token whitelist, escrow creation). Rather than new wrapper contracts, extend EscrowFactory with ICTT bridge state and logic.

### 2.0 Add to EscrowFactory

| Addition | Purpose |
|---|---|
| `s_bridgeRoutes` | `mapping(bytes32 => BridgeRoute)` keyed by `keccak256(abi.encode(token, destChainId))` |
| `struct BridgeRoute { address sourceContract; address destContract; }` | `sourceContract` = TokenHome or TokenRemote to call on this chain; `destContract` = destination TokenTransferrer for `SendTokensInput` |
| `registerBridgeRoute(token, destChainId, sourceContract, destContract)` | Owner registers a route (e.g. C-Chain: USDC + L1-X → TokenHome, TokenRemote) |
| `getBridgeRoute(token, destChainId)` | View: returns route for UI / adapter |
| `bridge(token, amount, destChainId, recipient, feeToken, feeAmount)` | Pulls tokens, builds `SendTokensInput`, calls `sourceContract.send()` |

**On C-Chain:** `sourceContract` = TokenHome (USDC), `destContract` = TokenRemote on L1.  
**On L1 (return path):** `sourceContract` = TokenRemote on this L1, `destContract` = TokenHome on C-Chain.

**Benefits:**
- No new contracts — EscrowFactory stays the single Oryn entry point
- Same owner pattern as `whitelistToken` / `delistToken`
- One deployment per chain, one source of truth
- Bridge routes are independent of escrow whitelist (token can have routes without being escrow-whitelisted)

**Implementation sketch:**
```solidity
// In EscrowFactory
struct BridgeRoute {
    address sourceContract;  // TokenHome or TokenRemote on THIS chain
    address destContract;    // Destination TokenTransferrer for SendTokensInput
}

mapping(bytes32 => BridgeRoute) public s_bridgeRoutes;

function registerBridgeRoute(
    address token,
    bytes32 destChainId,
    address sourceContract,
    address destContract
) external onlyOwner {
    bytes32 id = keccak256(abi.encode(token, destChainId));
    s_bridgeRoutes[id] = BridgeRoute(sourceContract, destContract);
    emit BridgeRouteRegistered(token, destChainId, sourceContract, destContract);
}

function bridge(
    address token,
    uint256 amount,
    bytes32 destChainId,
    address recipient,
    address feeToken,
    uint256 feeAmount
) external whenNotPaused {
    bytes32 id = keccak256(abi.encode(token, destChainId));
    BridgeRoute memory route = s_bridgeRoutes[id];
    require(route.sourceContract != address(0), "Bridge route not registered");
    // transferFrom, approve, IERC20TokenTransferrer(route.sourceContract).send(...)
}
```

---

## 3. Alternative: New Wrappers / Adapters

If extending EscrowFactory is not desired (e.g. keep escrow and bridge strictly separated, or avoid upgrading), the following separate contracts can be used.

### 3.1 OrynBridgeAdapter (ICTT Bridge Facade)

**Purpose:** Unified `bridge()` interface so ORYN frontends/APIs call one contract regardless of destination chain type.

| Function | Description |
|---|---|
| `bridge(token, amount, destinationChainId, recipient)` | Approves TokenHome, builds `SendTokensInput`, calls `TokenHome.send()` |
| `bridgeWithFee(token, amount, destinationChainId, recipient, feeToken, feeAmount)` | Same, with optional relayer fee |

**Benefits:**
- Single entry point for "send token to chain X"
- Hides ICTT's `SendTokensInput` complexity (destinationBlockchainID, destinationTokenTransferrerAddress, requiredGasLimit, multiHopFallback, etc.)
- Frontend only needs: token, amount, chain, recipient

**Interface:**
```solidity
/// @notice Simplified bridge interface — abstracts TokenHome/TokenRemote
interface IOrynBridgeAdapter {
    function bridge(
        address token,
        uint256 amount,
        bytes32 destinationChainId,
        address recipient,
        address feeToken,
        uint256 feeAmount
    ) external;
}
```

**Implementation sketch:**
```solidity
function bridge(address token, uint256 amount, bytes32 destChainId, address recipient) external {
    (address tokenHome, address tokenRemote) = registry.getRoute(token, destChainId);
    IERC20(token).transferFrom(msg.sender, address(this), amount);
    IERC20(token).approve(tokenHome, amount);
    IERC20TokenTransferrer(tokenHome).send(SendTokensInput({
        destinationBlockchainID: destChainId,
        destinationTokenTransferrerAddress: tokenRemote,
        recipient: recipient,
        primaryFeeTokenAddress: address(0),
        primaryFee: 0,
        secondaryFee: 0,
        requiredGasLimit: DEFAULT_GAS_LIMIT,
        multiHopFallback: msg.sender
    }), amount);
}
```

---

### 3.2 OrynTokenRegistry (Bridge Token Registry)

**Purpose:** Maps canonical tokens + destination chains → TokenHome / TokenRemote addresses. Enables discovery and validation.

| Function | Description |
|---|---|
| `registerRoute(token, chainId, tokenHome, tokenRemote)` | Owner registers a bridge route |
| `getRoute(token, chainId)` | Returns (tokenHome, tokenRemote) for a route |
| `getTokenRemote(token, chainId)` | On L1, returns the wrapped-token address (TokenRemote) so UIs show correct balance |

**Interface:**
```solidity
interface IOrynTokenRegistry {
    function getTokenTransferrer(address canonicalToken, bytes32 chainId) external view returns (address tokenTransferrer);
    function registerTokenHome(address canonicalToken, address tokenHome) external;
    function registerTokenRemote(address canonicalToken, bytes32 chainId, address tokenRemote) external;
}
```

**Use case:** On an Avalanche L1, "USDC" is the `ERC20TokenRemote` for USDC—a different address than C-Chain USDC. The registry tells UIs: "For USDC on this L1, use address 0x..."

---

### 3.3 OrynSendAndCallReceiver (Optional)

**Purpose:** Implements ICTT's `receiveTokens` callback for `sendAndCall`. Enables "bridge + action" in one tx.

| Use Case | Flow |
|---|---|
| Bridge + deposit into lending | User calls `sendAndCall` with payload → tokens arrive on L1 → receiver auto-deposits into lending market |
| Bridge + swap | Tokens arrive → receiver swaps into another token |

**Requirements:** Implement `ITeleporterReceiver.receiveTeleporterMessage`. Add re-entrancy guards.

```solidity
contract OrynSendAndCallReceiver is ITeleporterReceiver, ReentrancyGuard {
    function receiveTeleporterMessage(...) external {
        // Decode amount, perform deposit/swap/etc.
    }
}
```

---

## 3. ICTT API Complexity — What the Adapter Hides

ICTT's `send()` requires a `SendTokensInput` struct:

| Field | Description |
|---|---|
| `destinationBlockchainID` | bytes32 chain ID |
| `destinationTokenTransferrerAddress` | TokenRemote address |
| `recipient` | Destination recipient |
| `primaryFeeTokenAddress` | ERC20 for relayer fee (or zero) |
| `primaryFee` | Fee amount |
| `secondaryFee` | Multi-hop fee |
| `requiredGasLimit` | Gas for destination execution |
| `multiHopFallback` | Fallback if multi-hop fails |

Users typically only care about: **token, amount, destination chain, recipient**. The adapter encodes chain-specific knowledge (TokenHome, TokenRemote, gas estimates) and exposes a simple API.

---

## 4. What Does *Not* Need Wrappers

| Component | Need wrapper? | Reason |
|---|---|---|
| **EscrowFactory** | No | Chain-agnostic; works on Avalanche L1s for HTLC swaps |
| **EscrowVault** | No | No ICTT dependency |
| **TokenHome / TokenRemote** | No | Use as provided by Ava Labs |
| **Direct ICTT usage** | Optional | Power users can call TokenHome.send() directly |

---

## 5. Escrow Betterments (From Code Review)

Potential improvements to the existing escrow (not ICTT-specific):

| Area | Suggestion |
|---|---|
| **Token whitelist** | Consider a separate `TokenRegistry` contract that EscrowFactory reads from, so token management can be decentralized or multi-sig controlled without upgrading the factory. |
| **Block-based expiry** | `expiryBlocks` varies with chain speed. Consider optional time-based expiry (e.g. `expiryTimestamp`) for cross-chain UX where block counts differ. |
| **Gas limit** | `8000` gas for native transfer in `claim`/`refund` may be tight for some contract wallets; document or make configurable. |
| **Replay across chains** | Salt includes `block.chainid`—good. Ensure frontends never reuse the same (creator, recipient, commitmentHash) across chains if they represent different logical swaps. |
| **Nonce in createEscrowSigned** | `CREATE_ESCROW_TYPEHASH` should include nonce to prevent replay. Verify current implementation. |

---

## 6. Implementation Order

**Preferred (extend existing):**

| Phase | Deliverable |
|---|---|
| 1 | **Extend EscrowFactory** — add `s_bridgeRoutes`, `registerBridgeRoute`, `getBridgeRoute`, `bridge()` |
| 2 | Register routes per chain (C-Chain: TokenHome + TokenRemote per L1; each L1: TokenRemote + TokenHome for return) |
| 3 | Frontend integration — use `EscrowFactory.bridge()` for "Bridge" and `createEscrow*` for "Swap" |
| 4 | (Optional) **OrynSendAndCallReceiver** — if bridge + DeFi flows are required |

**Alternative (new contracts):** TokenRegistry + BridgeAdapter if escrow and bridge must stay separate.

---

## 7. Summary

| Component | Required? | Purpose |
|---|---|---|
| **EscrowFactory + bridge routes** | **Yes (preferred)** | Add `registerBridgeRoute`, `bridge()` to existing registry; no new deployments |
| **OrynBridgeAdapter + TokenRegistry** | Alternative | Use if extending EscrowFactory is not desired |
| **OrynSendAndCallReceiver** | Optional | Bridge + DeFi action in one tx |
| **EscrowVault** | No changes | Use as-is for HTLC on all chains |

- **Preferred:** Extend EscrowFactory with bridge state and `bridge()` — reuse existing registry on each chain.
- **ORYN Escrow:** Unchanged; use for HTLC swaps.
- **ICTT:** Use for C-Chain ↔ L1 transfers; extend EscrowFactory to expose a simple `bridge()` API.

---

*Complements [AVALANCHE_ICTT_ARCHITECTURE.md](./AVALANCHE_ICTT_ARCHITECTURE.md). Technical research document. Not financial or legal advice.*

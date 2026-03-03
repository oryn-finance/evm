## Oryn Atomic Swap Escrow

Hash-locked atomic swap system for ERC20 and native ETH. Creator deposits funds into a deterministic vault; recipient withdraws by revealing the preimage, or creator cancels after expiry.

---

## Contracts

### SwapRegistry (Factory)

- **Owner-managed**: Whitelists tokens, deploys vaults.
- **Deterministic vault addresses**: Same params → same address (chainid, token, creator, recipient, expiryBlocks, commitmentHash).
- **Four creation paths**:
  1. **Pre-fund + create** – Creator funds predicted address, then calls `createTokenSwapVault`.
  2. **Native one-tx** – Creator sends ETH with call; registry forwards to vault address (`createTokenSwapVaultNativeCall`).
  3. **ERC20 permit** – No prior approve; creator signs EIP-2612 permit, anyone submits (`createTokenSwapVaultPermit`).
  4. **ERC20 signed** – Creator signs EIP-712 params, relayer submits with prior approval (`createTokenSwapVaultSigned`).

### TokenDepositVault (Cloned per swap)

- **Immutable params**: token, creator, recipient, expiryBlocks, commitmentHash.
- **Withdraw**: Recipient calls `withdraw(preimage)`; funds go to recipient if `sha256(preimage) == commitmentHash`.
- **Cancel**: Creator calls `cancelSwap()` after `expiryBlocks`; funds return to creator.
- **Supports**: ERC20 and native ETH (sentinel `0xEee...eE`).

---

## Fund Flow

```
Creator ──► Predicted vault address (pre-fund)
    or
Creator ──► Registry ──► Vault (one-tx: native / permit / signed)

Vault holds funds until:
  • Recipient withdraws (with valid preimage)
  • Creator cancels (after expiryBlocks)
```

---

## Flow Summary

| Step | Actor | Action |
|------|-------|--------|
| 1 | Owner | Whitelist token(s) |
| 2 | Creator | Get `getTokenVaultAddress(...)` → predicted address |
| 3 | Creator | Fund vault (transfer ETH or ERC20 to predicted address) |
| 4 | Creator / Relayer | Call create function → vault deployed |
| 5a | Recipient | `withdraw(preimage)` → receives funds |
| 5b | Creator | `cancelSwap()` after expiry → receives refund |


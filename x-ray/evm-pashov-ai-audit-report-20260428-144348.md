# Security Review - evm

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL / default                                          |
| **Files reviewed**               | `src/EscrowFactory.sol` - `src/EscrowVault.sol` - `src/ICMBridgeFactory.sol`<br>`src/AvalancheEscrows/AvalancheEscrowFactory.sol` - `src/AvalancheEscrows/AvalancheEscrowVault.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[95] **1. ERC-2612 permits can fund attacker-chosen escrow terms**

`EscrowFactory.createEscrowPermit` / `AvalancheEscrowFactory.createEscrowPermit` - Confidence: 95

**Description**
`createEscrowPermit()` only consumes an ERC-2612 permit for allowance and does not bind `recipient`, `commitmentHash`, `expiryBlocks`, `amount`, or `l1Hop`, so a copied permit can pull the creator's tokens into attacker-selected escrow parameters.

**Evidence**
- `src/EscrowFactory.sol:337-352`
- `src/EscrowFactory.sol:457-464`
- `src/EscrowFactory.sol:443-452`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:263-274`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:350-357`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:336-346`

**Fix**

```diff
- _executePermit(token, creator, amount, deadline, signature);
- return _createErc20EscrowFromCreator(token, creator, recipient, expiryBlocks, commitmentHash, amount);
+ _executePermit(token, creator, amount, deadline, permitSignature);
+ _verifyCreateEscrowSignature(token, creator, recipient, expiryBlocks, commitmentHash, amount, createSignature);
+ return _createErc20EscrowFromCreator(token, creator, recipient, expiryBlocks, commitmentHash, amount);
```

Alternatively, require `msg.sender == creator` for permit-based creation or use Permit2 witness data that signs the full escrow parameters.

---

[92] **2. Expired escrows remain claimable and can front-run refunds**

`EscrowVault.claim` / `AvalancheEscrowVault.claim` / `AvalancheEscrowVault.claimHop` - Confidence: 92

**Description**
After `block.number >= s_depositedAt + expiryBlocks`, `refund()` is enabled but `claim()` and `claimHop()` still have no expiry cutoff, so the preimage holder can settle first and block the creator refund.

**Evidence**
- `src/EscrowVault.sol:105-112`
- `src/EscrowVault.sol:127-134`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:164-172`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:192-223`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:242-247`

**Fix**

```diff
 function claim(bytes32 _commitment) external {
     require(!s_settled, EscrowVault__EscrowAlreadySettled());
-    (address token,, address recipient,, bytes32 commitmentHash) = getEscrowParameters();
+    (address token,, address recipient, uint256 expiryBlocks, bytes32 commitmentHash) = getEscrowParameters();
+    require(block.number < s_depositedAt + expiryBlocks, EscrowVault__EscrowExpired());
     require(sha256(abi.encodePacked(_commitment)) == commitmentHash, EscrowVault__InvalidCommitment());
```

Apply the same pre-expiry guard to `AvalancheEscrowVault.claim()` and `AvalancheEscrowVault.claimHop()` before any state change or approval.

---

[90] **3. Amount is omitted from deterministic escrow identity**

`EscrowFactory._getEscrowArgsAndSalt` / `AvalancheEscrowFactory._getEscrowArgsAndSalt` - Confidence: 90

**Description**
`amount` is accepted, checked, and emitted, but not included in the clone immutable args or CREATE2 salt, allowing a lower-amount prefund call to deploy the same address intended for a higher-amount escrow.

**Evidence**
- `src/EscrowFactory.sol:225-248`
- `src/EscrowFactory.sol:488-498`
- `src/EscrowFactory.sol:477`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:185-202`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:372-382`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:212-238`

**Fix**

```diff
- encodedArgs = abi.encode(token, creator, recipient, expiryBlocks, commitmentHash);
- salt = keccak256(abi.encode(block.chainid, token, creator, recipient, expiryBlocks, commitmentHash));
+ encodedArgs = abi.encode(token, creator, recipient, expiryBlocks, commitmentHash, amount);
+ salt = keccak256(abi.encode(block.chainid, token, creator, recipient, expiryBlocks, commitmentHash, amount));
```

Mirror the same binding in the Avalanche factory, including `l1Hop` and `amount` in both immutable args and salt.

---

[86] **4. Signed escrow authorizations never expire or consume a nonce**

`EscrowFactory.createEscrowSigned` / `AvalancheEscrowFactory.createEscrowSigned` - Confidence: 86

**Description**
EIP-712 create signatures omit nonce and deadline, and verification is view-only, so an unused old signature can be executed later if the creator has balance and allowance.

**Evidence**
- `src/EscrowFactory.sol:89-92`
- `src/EscrowFactory.sol:365-379`
- `src/EscrowFactory.sol:417-431`
- `src/EscrowFactory.sol:443-452`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:105-108`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:277-289`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:319-333`

**Fix**

```diff
- "CreateEscrowParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount)"
+ "CreateEscrowParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount,uint256 nonce,uint256 deadline)"
```

Track `nonces[creator]`, reject expired signatures, consume the nonce before token movement, and expose cancellation.

---

[85] **5. Unbounded expiry can overflow refund deadline arithmetic**

`EscrowVault.refund` / `AvalancheEscrowVault.refund` - Confidence: 85

**Description**
Factories only require `expiryBlocks > 0`, while `refund()` computes `s_depositedAt + expiryBlocks` in checked arithmetic; oversized expiries can make refund revert before the comparison.

**Evidence**
- `src/EscrowFactory.sol:167`
- `src/EscrowVault.sol:130-134`
- `src/AvalancheEscrows/AvalancheEscrowFactory.sol:315`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:245-247`

**Fix**

```diff
- require(block.number >= s_depositedAt + expiryBlocks, EscrowVault__EscrowNotExpired());
+ require(block.number - s_depositedAt >= expiryBlocks, EscrowVault__EscrowNotExpired());
```

Also reject creation where the chosen expiry cannot be represented safely for the expected chain lifetime.

---

[82] **6. Native payouts can fail for contract recipients due to 8k gas cap**

`EscrowVault.claim/refund` / `AvalancheEscrowVault.claim/refund` - Confidence: 82

**Description**
Native token settlement forwards only 8,000 gas, so contract recipients or creators with non-trivial `receive()` logic can be unable to claim or refund, with no alternate withdrawal path.

**Evidence**
- `src/EscrowVault.sol:114-116`
- `src/EscrowVault.sol:138-140`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:174-176`
- `src/AvalancheEscrows/AvalancheEscrowVault.sol:251-253`

**Fix**

```diff
- (bool success,) = recipient.call{value: address(this).balance, gas: 8000}("");
+ (bool success,) = recipient.call{value: address(this).balance}("");
```

State is already updated before the external call, but add tests for contract recipients and creators if the gas cap is removed.

---

Findings List

| # | Confidence | Title |
|---|---:|---|
| 1 | 95 | ERC-2612 permits can fund attacker-chosen escrow terms |
| 2 | 92 | Expired escrows remain claimable and can front-run refunds |
| 3 | 90 | Amount is omitted from deterministic escrow identity |
| 4 | 86 | Signed escrow authorizations never expire or consume a nonce |
| 5 | 85 | Unbounded expiry can overflow refund deadline arithmetic |
| 6 | 82 | Native payouts can fail for contract recipients due to 8k gas cap |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives - they are high-signal leads for manual review. Not scored._

- **Hop settlement can approve and call an arbitrary bridge factory** - `AvalancheEscrowVault.claimHop` - Code smells: `_hopData.bridgeFactory` is authenticated only by the recipient signature; the vault approves `vaultBalance` before calling it and does not whitelist a canonical ICM bridge factory. Review whether recipients are intentionally allowed to select arbitrary bridge routers.

- **Bridge success is trusted without proving token consumption** - `ICMBridgeFactory.bridge` - Code smells: the factory pulls tokens and approves `route.tokenTransferrer`, then emits `BridgeSent` after any non-reverting `send()` without checking post-call balances or clearing residual allowance. Route selection is owner-gated, so this is mainly a misconfiguration/dependency-failure trail.

- **README/docs drift from source** - `README.md` vs source - Code smells: README references nonce support and a 30,000 native gas cap while current source has no nonce state and uses an 8,000 gas cap. This is not directly exploitable, but it can cause unsafe integration assumptions.

---

> This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended.

# Entry Point Map

> Oryn Escrow | 29 runtime entry points | 16 permissionless | 0 role-gated | 13 admin-only

---

## Protocol Flow Paths

### Setup (Owner)

`EscrowFactory.constructor()` -> `whitelistToken()` -> standard escrow creation

`AvalancheEscrowFactory.constructor()` -> `whitelistToken()` -> Avalanche escrow creation

`ICMBridgeFactory.constructor()` -> `registerRoute()` -> `bridge()` / `AvalancheEscrowVault.claimHop()`

### Standard Escrow

`[standard setup above]` -> `getEscrowAddress()` -> pre-fund predicted address -> `createEscrow()` -> `EscrowVault.initialize()` -> `claim()` or `refund()`  <-- refund needs block expiry

`[standard setup above]` -> `createEscrowNative()` -> `EscrowVault.initialize()` -> `claim()` or `refund()`

`[standard setup above]` -> `createEscrowPermit()` / `createEscrowSigned()` -> `EscrowVault.initialize()` -> `claim()` or `refund()`

### Avalanche Hop Escrow

`[Avalanche setup above]` -> `createEscrow(l1Hop=false)` -> `AvalancheEscrowVault.claim()` or `refund()`

`[Avalanche setup above]` -> `createEscrow(l1Hop=true)` -> `claimHop()` -> `ICMBridgeFactory.bridge()`  <-- route must be active

`[Avalanche setup above]` -> `createEscrowPermit()` / `createEscrowSigned()` -> `claim()` or `claimHop()` based on `l1Hop`

### Direct Bridge

`[route setup above]` -> user approves bridge token and optional fee token -> `ICMBridgeFactory.bridge()` -> `TokenTransferrer.send()`

---

## Permissionless

### `EscrowFactory.createEscrow()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused`, `safeParams` |
| Caller | Anyone after predicted vault is pre-funded |
| Parameters | token, creator, recipient, expiryBlocks, commitmentHash, amount (user-controlled) |
| Call chain | `-> _getEscrowArgsAndSalt() -> predictDeterministicAddressWithImmutableArgs() -> _deployEscrow() -> EscrowVault.initialize()` |
| State modified | `s_deployedEscrows[escrow] = true`; clone `s_depositedAt` |
| Value flow | Pre-funded vault balance stays in clone |
| Reentrancy guard | no |

### `EscrowFactory.createEscrowBatch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | Anyone after all predicted vaults are pre-funded |
| Parameters | params[] (user-controlled) |
| Call chain | `-> _safeParams() -> _getEscrowArgsAndSalt() -> _deployEscrow() -> EscrowVault.initialize()` |
| State modified | `s_deployedEscrows[escrow] = true` for each clone |
| Value flow | Pre-funded vault balances stay in clones |
| Reentrancy guard | no |

### `EscrowFactory.createEscrowNative()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `whenNotPaused`, `safeParams` |
| Caller | Native-token creator or relayer supplying `msg.value` |
| Parameters | token, creator, recipient, expiryBlocks, commitmentHash, amount (user-controlled) |
| Call chain | `-> predict address -> native call to predicted address -> _deployEscrow() -> EscrowVault.initialize()` |
| State modified | `s_deployedEscrows[escrow] = true`; clone `s_depositedAt` |
| Value flow | Native token: caller -> clone |
| Reentrancy guard | no |

### `EscrowFactory.createEscrowPermit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused`, `safeParams` |
| Caller | Relayer/user with creator's EIP-2612 permit |
| Parameters | token, creator, recipient, expiryBlocks, commitmentHash, amount, deadline, signature (user-signed) |
| Call chain | `-> IERC20Permit.permit() -> _createErc20EscrowFromCreator() -> safeTransferFrom() -> _deployEscrow()` |
| State modified | `s_deployedEscrows[escrow] = true`; token allowance in external token |
| Value flow | ERC20: creator -> clone |
| Reentrancy guard | no |

### `EscrowFactory.createEscrowSigned()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused`, `safeParams` |
| Caller | Relayer/user with creator's EIP-712 signature and allowance |
| Parameters | token, creator, recipient, expiryBlocks, commitmentHash, amount, signature (user-signed) |
| Call chain | `-> ECDSA.recover() -> _createErc20EscrowFromCreator() -> safeTransferFrom() -> _deployEscrow()` |
| State modified | `s_deployedEscrows[escrow] = true` |
| Value flow | ERC20: creator -> clone |
| Reentrancy guard | no |

### `EscrowVault.claim()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone with the commitment preimage |
| Parameters | _commitment (user-controlled secret) |
| Call chain | `-> getEscrowParameters() -> token/native payout` |
| State modified | `s_settled = true` |
| Value flow | Full vault balance -> immutable recipient |
| Reentrancy guard | no, but state flips before payout |

### `EscrowVault.refund()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone after expiry |
| Parameters | none |
| Call chain | `-> getEscrowParameters() -> token/native payout` |
| State modified | `s_settled = true` |
| Value flow | Full vault balance -> immutable creator |
| Reentrancy guard | no, but state flips before payout |

### `AvalancheEscrowFactory.createEscrow()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | Anyone after predicted vault is pre-funded |
| Parameters | EscrowParams p (user-controlled) |
| Call chain | `-> _safeParams() -> _getEscrowArgsAndSalt() -> _deployEscrow() -> AvalancheEscrowVault.initialize()` |
| State modified | `s_deployedEscrows[escrow] = true`; clone `s_depositedAt` |
| Value flow | Pre-funded vault balance stays in clone |
| Reentrancy guard | no |

### `AvalancheEscrowFactory.createEscrowBatch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | Anyone after all predicted vaults are pre-funded |
| Parameters | params[] (user-controlled) |
| Call chain | `-> _safeParams() -> _getEscrowArgsAndSalt() -> _deployEscrow() -> AvalancheEscrowVault.initialize()` |
| State modified | `s_deployedEscrows[escrow] = true` for each clone |
| Value flow | Pre-funded vault balances stay in clones |
| Reentrancy guard | no |

### `AvalancheEscrowFactory.createEscrowNative()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `whenNotPaused` |
| Caller | Native-token creator or relayer supplying `msg.value` |
| Parameters | EscrowParams p (user-controlled) |
| Call chain | `-> _getEscrowArgsAndSalt() -> native call to predicted address -> _deployEscrow()` |
| State modified | `s_deployedEscrows[escrow] = true`; clone `s_depositedAt` |
| Value flow | Native token: caller -> clone |
| Reentrancy guard | no |

### `AvalancheEscrowFactory.createEscrowPermit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | Relayer/user with creator's EIP-2612 permit |
| Parameters | EscrowParams p, deadline, signature (user-signed) |
| Call chain | `-> IERC20Permit.permit() -> _createErc20EscrowFromCreator() -> safeTransferFrom() -> _deployEscrow()` |
| State modified | `s_deployedEscrows[escrow] = true`; token allowance in external token |
| Value flow | ERC20: creator -> clone |
| Reentrancy guard | no |

### `AvalancheEscrowFactory.createEscrowSigned()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | Relayer/user with creator's EIP-712 signature and allowance |
| Parameters | EscrowParams p, signature (user-signed) |
| Call chain | `-> ECDSA.recover() -> _createErc20EscrowFromCreator() -> safeTransferFrom() -> _deployEscrow()` |
| State modified | `s_deployedEscrows[escrow] = true` |
| Value flow | ERC20: creator -> clone |
| Reentrancy guard | no |

### `AvalancheEscrowVault.claim()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone with the commitment preimage for a non-hop vault |
| Parameters | _commitment (user-controlled secret) |
| Call chain | `-> getEscrowParameters() -> token/native payout` |
| State modified | `s_settled = true` |
| Value flow | Full vault balance -> immutable recipient |
| Reentrancy guard | no, but state flips before payout |

### `AvalancheEscrowVault.claimHop()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone with preimage and recipient's hop authorization |
| Parameters | _commitment (secret), _signature (user-signed), _hopData (user-signed) |
| Call chain | `-> _verifyHopSignature() -> forceApprove(bridgeFactory) -> ICMBridgeFactory.bridge() -> TokenTransferrer.send()` |
| State modified | `s_settled = true`; external token allowance to bridge factory |
| Value flow | Vault ERC20 balance -> bridge factory -> ICTT route |
| Reentrancy guard | no, but state flips before bridge call |

### `AvalancheEscrowVault.refund()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone after expiry |
| Parameters | none |
| Call chain | `-> getEscrowParameters() -> token/native payout` |
| State modified | `s_settled = true` |
| Value flow | Full vault balance -> immutable creator |
| Reentrancy guard | no, but state flips before payout |

### `ICMBridgeFactory.bridge()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | User, vault, or approved token holder |
| Parameters | token, amount, destBlockchainId, recipient, primaryFeeToken, primaryRelayerFee (user-controlled) |
| Call chain | `-> s_routes lookup -> safeTransferFrom() -> forceApprove() -> TokenTransferrer.send()` |
| State modified | external token balances/allowances; no protocol storage write |
| Value flow | Token and optional fee: caller -> bridge factory -> TokenTransferrer |
| Reentrancy guard | no |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| EscrowFactory | `pause()` | none | Pausable state |
| EscrowFactory | `unpause()` | none | Pausable state |
| EscrowFactory | `whitelistToken()` | _tokenAddress | `s_whitelistedTokens[_tokenAddress] = true` |
| EscrowFactory | `delistToken()` | _tokenAddress | `s_whitelistedTokens[_tokenAddress] = false` |
| AvalancheEscrowFactory | `pause()` | none | Pausable state |
| AvalancheEscrowFactory | `unpause()` | none | Pausable state |
| AvalancheEscrowFactory | `whitelistToken()` | _tokenAddress | `s_whitelistedTokens[_tokenAddress] = true` |
| AvalancheEscrowFactory | `delistToken()` | _tokenAddress | `s_whitelistedTokens[_tokenAddress] = false` |
| ICMBridgeFactory | `pause()` | none | Pausable state |
| ICMBridgeFactory | `unpause()` | none | Pausable state |
| ICMBridgeFactory | `registerRoute()` | token, destBlockchainId, tokenTransferrer, destTransferrer, requiredGasLimit | `s_routes[token][destBlockchainId]` |
| ICMBridgeFactory | `updateRoute()` | token, destBlockchainId, tokenTransferrer, destTransferrer, requiredGasLimit | `s_routes[token][destBlockchainId]` |
| ICMBridgeFactory | `deregisterRoute()` | token, destBlockchainId | deletes `s_routes[token][destBlockchainId]` |

---

## Initialization

| Contract | Function | Caller | State Modified |
|----------|----------|--------|----------------|
| EscrowVault | `initialize()` | Factory immediately after clone deployment | `s_depositedAt = block.number` |
| AvalancheEscrowVault | `initialize()` | Factory immediately after clone deployment | `s_depositedAt = block.number` |

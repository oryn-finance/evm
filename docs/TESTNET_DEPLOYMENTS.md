# Testnet Deployments

All addresses deployed for the Oryn multihop swap integration on Avalanche Fuji + Echo L1.

**Deployer / Owner:** `0xc0cda028C025035DdA84E724AAB2D82B9c321dC5`

---

## Teleporter Infrastructure (Pre-existing on Both Chains)

| Contract | Address | Chains |
|----------|---------|--------|
| TeleporterMessenger | `0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf` | Fuji C-chain + Echo L1 |
| TeleporterRegistry | `0xF86Cb19Ad8405AEFa7d09C778215D2Cb6eBfB228` | Fuji C-chain + Echo L1 |

---

## Blockchain IDs (bytes32)

| Chain | Blockchain ID |
|-------|---------------|
| Fuji C-chain | `0x7fc93d85c6d62c5b2ac0b519c87010ea5294012d1e407030d6acd0021cac10d5` |
| Echo L1 | `0x1278d1be4b987e847be3465940eb5066c4604a7fbd6e086900823597d81af4c1` |

---

## Fuji C-Chain (Chain ID: 43113)

**RPC:** `https://api.avax-test.network/ext/bc/C/rpc`

### Base Tokens (ERC20)

| Token | Symbol | Decimals | Address |
|-------|--------|----------|---------|
| USD Coin | USDC | 6 | `0x61a4E421721DBd10b49c36CFE8296FF0dE277B74` |
| Wrapped Bitcoin | WBTC | 8 | `0x95e56Ef41A36eC996F51dBcd21785aa58F32815c` |

### ICTT Token Homes (lock tokens on C-chain for bridging)

| Token | ERC20TokenHome Address |
|-------|----------------------|
| USDC | `0xe3faad8f84a206f0a4be492f10a413dd38366bad` |
| WBTC | `0x1158b14442f91bbe75a6643ea19edc275a5bc82c` |

### Escrow & Bridge Factories

| Contract | Address |
|----------|---------|
| AvalancheEscrowFactory | `0xF871B8D3417a4180680204dff900033761A5C9DD` |
| ICMBridgeFactory | `0xADa9734ba4075EE27EA7CA3aEb8E5a2006b4B87D` |

### Whitelisted Tokens on AvalancheEscrowFactory

- USDC: `0x61a4E421721DBd10b49c36CFE8296FF0dE277B74`
- WBTC: `0x95e56Ef41A36eC996F51dBcd21785aa58F32815c`

### Registered Forward Routes on ICMBridgeFactory (C-chain → Echo)

| Token | Dest Blockchain ID | TokenTransferrer (Home) | DestTransferrer (Remote) | Gas Limit |
|-------|--------------------|------------------------|-------------------------|-----------|
| USDC | `0x1278d1...af4c1` | `0xe3faad8f84a206f0a4be492f10a413dd38366bad` | `0x188381687be21fcf26e279b76f48dd4a018aaa8b` | 250,000 |
| WBTC | `0x1278d1...af4c1` | `0x1158b14442f91bbe75a6643ea19edc275a5bc82c` | `0xb2d658beb1a2d48749ac0a71b74eb3c1e326ad55` | 250,000 |

---

## Echo L1 (Chain ID: 173750)

**RPC:** `https://subnets.avax.network/echo/testnet/rpc`

### Bridged Tokens (ERC20TokenRemote — minted via ICTT)

| Token | Symbol | Decimals | ERC20TokenRemote Address | Home Token (C-chain) |
|-------|--------|----------|--------------------------|---------------------|
| Bridged USDC | USDC.e | 6 | `0x188381687be21fcf26e279b76f48dd4a018aaa8b` | `0x61a4E421721DBd10b49c36CFE8296FF0dE277B74` |
| Bridged WBTC | WBTC.e | 8 | `0xb2d658beb1a2d48749ac0a71b74eb3c1e326ad55` | `0x95e56Ef41A36eC996F51dBcd21785aa58F32815c` |

### Escrow & Bridge Factories

| Contract | Address |
|----------|---------|
| AvalancheEscrowFactory | `0x3f0e9fa48107f56205d68593b1af7948a7f9e41c` |
| ICMBridgeFactory | `0xacfa160f9f3acb6bebacc740b86d0ea320a0d6aa` |

### Whitelisted Tokens on AvalancheEscrowFactory

- USDC.e (bridged): `0x188381687be21fcf26e279b76f48dd4a018aaa8b`
- WBTC.e (bridged): `0xb2d658beb1a2d48749ac0a71b74eb3c1e326ad55`

### Registered Reverse Routes on ICMBridgeFactory (Echo → C-chain)

| Token | Dest Blockchain ID | TokenTransferrer (Remote) | DestTransferrer (Home) | Gas Limit |
|-------|--------------------|--------------------------|----------------------|-----------|
| USDC.e | `0x7fc93d...10d5` | `0x188381687be21fcf26e279b76f48dd4a018aaa8b` | `0xe3faad8f84a206f0a4be492f10a413dd38366bad` | 250,000 |
| WBTC.e | `0x7fc93d...10d5` | `0xb2d658beb1a2d48749ac0a71b74eb3c1e326ad55` | `0x1158b14442f91bbe75a6643ea19edc275a5bc82c` | 250,000 |

---

## Bridge Route Summary

```
Forward (C-chain → Echo L1):
  USDC: TokenHome(0xe3fa) locks on C-chain → TokenRemote(0x1883) mints on Echo
  WBTC: TokenHome(0x1158) locks on C-chain → TokenRemote(0xb2d6) mints on Echo

Reverse (Echo L1 → C-chain):
  USDC.e: TokenRemote(0x1883) burns on Echo → TokenHome(0xe3fa) unlocks on C-chain
  WBTC.e: TokenRemote(0xb2d6) burns on Echo → TokenHome(0x1158) unlocks on C-chain
```

---

## Quick Verification Commands

```bash
# Check USDC forward route on Fuji
cast call 0xADa9734ba4075EE27EA7CA3aEb8E5a2006b4B87D \
  "getRoute(address,bytes32)(address,address,uint256,bool)" \
  0x61a4E421721DBd10b49c36CFE8296FF0dE277B74 \
  0x1278d1be4b987e847be3465940eb5066c4604a7fbd6e086900823597d81af4c1 \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc

# Check WBTC forward route on Fuji
cast call 0xADa9734ba4075EE27EA7CA3aEb8E5a2006b4B87D \
  "getRoute(address,bytes32)(address,address,uint256,bool)" \
  0x95e56Ef41A36eC996F51dBcd21785aa58F32815c \
  0x1278d1be4b987e847be3465940eb5066c4604a7fbd6e086900823597d81af4c1 \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc

# Check USDC reverse route on Echo
cast call 0xacfa160f9f3acb6bebacc740b86d0ea320a0d6aa \
  "getRoute(address,bytes32)(address,address,uint256,bool)" \
  0x188381687be21fcf26e279b76f48dd4a018aaa8b \
  0x7fc93d85c6d62c5b2ac0b519c87010ea5294012d1e407030d6acd0021cac10d5 \
  --rpc-url https://subnets.avax.network/echo/testnet/rpc

# Check WBTC reverse route on Echo
cast call 0xacfa160f9f3acb6bebacc740b86d0ea320a0d6aa \
  "getRoute(address,bytes32)(address,address,uint256,bool)" \
  0xb2d658beb1a2d48749ac0a71b74eb3c1e326ad55 \
  0x7fc93d85c6d62c5b2ac0b519c87010ea5294012d1e407030d6acd0021cac10d5 \
  --rpc-url https://subnets.avax.network/echo/testnet/rpc

# Check whitelisted tokens
cast call 0xF871B8D3417a4180680204dff900033761A5C9DD \
  "s_whitelistedTokens(address)(bool)" 0x61a4E421721DBd10b49c36CFE8296FF0dE277B74 \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc

cast call 0x3f0e9fa48107f56205d68593b1af7948a7f9e41c \
  "s_whitelistedTokens(address)(bool)" 0x188381687be21fcf26e279b76f48dd4a018aaa8b \
  --rpc-url https://subnets.avax.network/echo/testnet/rpc
```

---

## Notes

- **ICM Relayer**: Required for cross-chain message delivery (registration messages, token transfers). No public relayer exists for Fuji ↔ Echo — must run your own. See [DEPLOY.md](./DEPLOY.md#relayer-setup).
- **Token Remotes registered with Homes**: `registerWithHome()` was called on both TokenRemote contracts. The ICM relayer must deliver these registration messages for bridging to work.
- **CREATE2**: Fuji factories used deterministic CREATE2 deployment. Echo factories were deployed with regular CREATE (CREATE2 deployer not available on Echo).
- **Gas Limit**: All routes use 250,000 gas limit for ICM relayer delivery. Adjust if needed based on actual gas consumption.

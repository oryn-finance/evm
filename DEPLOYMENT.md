# Deployment

> **Full end-to-end guide (ICTT + Escrow):** See [`docs/DEPLOY.md`](docs/DEPLOY.md) for the complete walkthrough covering Teleporter infra, ICTT token bridge, and escrow deployment.

This document describes how to deploy the Oryn Escrow contracts (EscrowFactory and optional ERC20 tokens) to any EVM chain using Foundry.

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Deployer wallet funded with the chain’s native token for gas
- (Optional) Block explorer API key for contract verification

---

## Environment

Set variables in your shell or in a `.env` file in the project root. Do not commit `.env` (it is gitignored).

```bash
cp .env.example .env
# Edit .env with your values
```

| Variable | Required | Description |
|----------|----------|-------------|
| `PRIVATE_KEY` | Yes | Deployer private key. Foundry uses it when you pass `--broadcast`. |
| `OWNER_ADDRESS` | Yes | Address that will own the EscrowFactory (e.g. your EOA or multisig). |
| `ETH_RPC_URL` | Yes (or pass `--rpc-url`) | RPC URL for the target chain. |
| `ETHERSCAN_API_KEY` (or chain-specific key) | No | Only needed for `--verify`. Use the explorer for the chain (Etherscan, Basescan, Arbiscan, Snowtrace, Moonscan, etc.). |

---

## Deploy scripts

| Script | Purpose |
|--------|---------|
| `script/DeployRegistry.s.sol` | Deploys the EscrowFactory (registry) only. |
| `script/DeployErc20Tokens.s.sol` | Deploys USDC and WBTC ERC20 tokens (e.g. for testnets). |
| `script/WhitelistTokens.s.sol` | Whitelists one token on an existing EscrowFactory. Run once per token. |

---

## Deploy commands

From the project root, after `forge install` and `forge build`.

### 1. Deploy EscrowFactory (registry)

```bash
export OWNER_ADDRESS=<owner-address>
export PRIVATE_KEY=<deployer-private-key>
export ETH_RPC_URL=<rpc-url>

forge script script/DeployRegistry.s.sol --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $ETH_RPC_URL --broadcast --verify
```

- Replace `<owner-address>`, `<deployer-private-key>`, and `<rpc-url>` with your values.
- Omit `--verify` if you do not have an explorer API key.
- Save the printed **EscrowFactory** address for your records.

### 2. (Optional) Deploy ERC20 tokens

If you want USDC and WBTC on the chain (e.g. for testnets), deploy them and then whitelist them (step 3):

```bash
export OWNER_ADDRESS=<owner-address>
export PRIVATE_KEY=<deployer-private-key>
export ETH_RPC_URL=<rpc-url>

forge script script/DeployErc20Tokens.s.sol --sig "run(address)" $OWNER_ADDRESS \
  --rpc-url $ETH_RPC_URL --broadcast
```

Save the printed USDC and WBTC addresses for the whitelist step.

### 3. Whitelist tokens (run individually)

After the EscrowFactory is deployed, whitelist tokens by running the whitelist script **once per token**. The transaction must be sent by the factory owner.

```bash
export FACTORY_ADDRESS=<escrow-factory-address>
export TOKEN_ADDRESS=<token-to-whitelist>
export PRIVATE_KEY=<deployer-private-key>
export ETH_RPC_URL=<rpc-url>

forge script script/WhitelistTokens.s.sol \
  --sig "run(address,address)" $FACTORY_ADDRESS $TOKEN_ADDRESS \
  --rpc-url $ETH_RPC_URL --broadcast
```

- Replace `<escrow-factory-address>` with the EscrowFactory address from step 1.
- Replace `<token-to-whitelist>` with the ERC20 token address (e.g. from step 2 or an existing token).
- To whitelist more tokens, run the same command again with a different `TOKEN_ADDRESS`.

Example after deploying ERC20 tokens: whitelist USDC, then WBTC:

```bash
export FACTORY_ADDRESS=0x...   # from step 1
export PRIVATE_KEY=...
export ETH_RPC_URL=...

export TOKEN_ADDRESS=0x...      # USDC address from step 2
forge script script/WhitelistTokens.s.sol --sig "run(address,address)" $FACTORY_ADDRESS $TOKEN_ADDRESS --rpc-url $ETH_RPC_URL --broadcast

export TOKEN_ADDRESS=0x...      # WBTC address from step 2
forge script script/WhitelistTokens.s.sol --sig "run(address,address)" $FACTORY_ADDRESS $TOKEN_ADDRESS --rpc-url $ETH_RPC_URL --broadcast
```

---

## Token whitelist summary

- **Deploy registry** (step 1) deploys the factory only; no tokens are whitelisted by default.
- **Whitelist tokens** (step 3) by running `WhitelistTokens.s.sol` once per token. You can do this anytime after deployment, with tokens you deployed via `DeployErc20Tokens.s.sol` or any existing ERC20 address. Only the factory owner can whitelist.

---

## Verification

If you use `--verify`, Foundry will verify the contract on the chain’s block explorer. If that fails, verify manually:

```bash
forge verify-contract <FACTORY_ADDRESS> src/EscrowFactory.sol:EscrowFactory \
  --chain-id <CHAIN_ID> --etherscan-api-key <API_KEY>
```

Use the correct chain ID and the API key for that chain’s explorer (Etherscan, Basescan, Arbiscan, Snowtrace, Moonscan, etc.).

---

## Example networks (reference)

| Network | Chain ID | Example RPC (no key) |
|---------|----------|----------------------|
| Ethereum Mainnet | 1 | `https://eth.llamarpc.com` |
| Ethereum Sepolia | 11155111 | `https://rpc.sepolia.org` |
| Base Sepolia | 84532 | `https://sepolia.base.org` |
| Arbitrum Sepolia | 421614 | `https://sepolia-rollup.arbitrum.io/rpc` |
| Avalanche Fuji | 43113 | `https://api.avax-test.network/ext/bc/C/rpc` |
| Moonbase Alpha | 1287 | `https://rpc.api.moonbase.moonbeam.network` |

RPC URLs and more chains: [Chainlist](https://chainlist.org).

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "../../lib/forge-std/src/Script.sol";
import {BridgeableERC20} from "../src/BridgeableERC20.sol";

/**
 * @title DeployBridgeableERC20
 * @notice Step 1 — Deploy a BridgeableERC20 token on the HOME chain.
 *
 * Environment variables (set before running):
 *   TOKEN_NAME      — e.g. "USD Coin"
 *   TOKEN_SYMBOL    — e.g. "USDC"
 *   TOKEN_DECIMALS  — e.g. 6  (default: 18)
 *   INITIAL_SUPPLY  — raw units, e.g. 1000000000000 for 1M USDC (default: 1e24)
 *   PRIVATE_KEY     — deployer private key
 *
 * Usage:
 *   FOUNDRY_PROFILE=ictt forge script ictt/script/DeployBridgeableERC20.s.sol \
 *     --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
 */
contract DeployBridgeableERC20 is Script {
    function run() external returns (address tokenAddress) {
        string memory name = vm.envOr("TOKEN_NAME", string("Bridge Token"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("BTK"));
        uint8 tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(18)));
        uint256 initialSupply = vm.envOr("INITIAL_SUPPLY", uint256(1e24));

        vm.startBroadcast();
        BridgeableERC20 token = new BridgeableERC20(
            name,
            symbol,
            tokenDecimals,
            initialSupply
        );
        tokenAddress = address(token);
        vm.stopBroadcast();

        console.log("=== BridgeableERC20 Deployed ===");
        console.log("  Token:    ", tokenAddress);
        console.log("  Name:     ", name);
        console.log("  Symbol:   ", symbol);
        console.log("  Decimals: ", tokenDecimals);
        console.log("  Supply:   ", initialSupply);
    }
}

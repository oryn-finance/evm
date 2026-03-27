// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "../../lib/forge-std/src/Script.sol";
import {ERC20TokenHome} from "../../lib/icm-services/icm-contracts/avalanche/ictt/TokenHome/ERC20TokenHome.sol";

/**
 * @title DeployERC20TokenHome
 * @notice Step 2 — Deploy ERC20TokenHome on the HOME chain.
 *         Requires TeleporterRegistry already deployed on this chain.
 *
 * Environment variables:
 *   TELEPORTER_REGISTRY_ADDRESS  — TeleporterRegistry on this chain (required)
 *   TELEPORTER_MANAGER_ADDRESS   — owner/manager EOA or multisig (required)
 *   TOKEN_ADDRESS                — BridgeableERC20 from Step 1 (required)
 *   TOKEN_DECIMALS               — token decimals (default: 18)
 *   MIN_TELEPORTER_VERSION       — minimum Teleporter version (default: 1)
 *   PRIVATE_KEY                  — deployer private key
 *
 * Usage:
 *   FOUNDRY_PROFILE=ictt forge script ictt/script/DeployERC20TokenHome.s.sol \
 *     --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
 */
contract DeployERC20TokenHome is Script {
    function run() external returns (address homeAddress) {
        address registry = vm.envAddress("TELEPORTER_REGISTRY_ADDRESS");
        address manager = vm.envAddress("TELEPORTER_MANAGER_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");
        uint8 tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(18)));
        uint256 minVersion = vm.envOr("MIN_TELEPORTER_VERSION", uint256(1));

        vm.startBroadcast();
        ERC20TokenHome home = new ERC20TokenHome(
            registry,
            manager,
            minVersion,
            token,
            tokenDecimals
        );
        homeAddress = address(home);
        vm.stopBroadcast();

        console.log("=== ERC20TokenHome Deployed ===");
        console.log("  Home:     ", homeAddress);
        console.log("  Token:    ", token);
        console.log("  Registry: ", registry);
        console.log("  Manager:  ", manager);
    }
}

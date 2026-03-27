// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "../../lib/forge-std/src/Script.sol";
import {ERC20TokenRemote} from "../../lib/icm-services/icm-contracts/avalanche/ictt/TokenRemote/ERC20TokenRemote.sol";
import {TokenRemoteSettings} from "../../lib/icm-services/icm-contracts/avalanche/ictt/TokenRemote/interfaces/ITokenRemote.sol";

/**
 * @title DeployERC20TokenRemote
 * @notice Step 3 — Deploy ERC20TokenRemote on the REMOTE chain.
 *         Requires TeleporterRegistry on this chain and TokenHome already deployed on the home chain.
 *
 * Environment variables:
 *   TELEPORTER_REGISTRY_ADDRESS  — TeleporterRegistry on THIS chain (required)
 *   TELEPORTER_MANAGER_ADDRESS   — manager EOA or multisig on THIS chain (required)
 *   TOKEN_HOME_BLOCKCHAIN_ID     — home chain blockchain ID, bytes32 hex 0x-prefixed (required)
 *   TOKEN_HOME_ADDRESS           — ERC20TokenHome address on the home chain (required)
 *   TOKEN_HOME_DECIMALS          — home token decimals (default: 18)
 *   REMOTE_TOKEN_NAME            — bridged token name, e.g. "Bridged USDC" (required)
 *   REMOTE_TOKEN_SYMBOL          — bridged token symbol, e.g. "bUSDC" (required)
 *   REMOTE_TOKEN_DECIMALS        — remote token decimals (default: 18)
 *   MIN_TELEPORTER_VERSION       — minimum Teleporter version (default: 1)
 *   PRIVATE_KEY                  — deployer private key
 *
 * Usage:
 *   FOUNDRY_PROFILE=ictt forge script ictt/script/DeployERC20TokenRemote.s.sol \
 *     --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
 */
contract DeployERC20TokenRemote is Script {
    function run() external returns (address remoteAddress) {
        address registry = vm.envAddress("TELEPORTER_REGISTRY_ADDRESS");
        address manager = vm.envAddress("TELEPORTER_MANAGER_ADDRESS");
        uint256 minVersion = vm.envOr("MIN_TELEPORTER_VERSION", uint256(1));
        bytes32 homeBlockchainId = vm.envBytes32("TOKEN_HOME_BLOCKCHAIN_ID");
        address homeAddress = vm.envAddress("TOKEN_HOME_ADDRESS");
        uint8 homeDecimals = uint8(vm.envOr("TOKEN_HOME_DECIMALS", uint256(18)));
        string memory tokenName = vm.envString("REMOTE_TOKEN_NAME");
        string memory tokenSymbol = vm.envString("REMOTE_TOKEN_SYMBOL");
        uint8 remoteDecimals = uint8(vm.envOr("REMOTE_TOKEN_DECIMALS", uint256(18)));

        TokenRemoteSettings memory settings = TokenRemoteSettings({
            teleporterRegistryAddress: registry,
            teleporterManager: manager,
            minTeleporterVersion: minVersion,
            tokenHomeBlockchainID: homeBlockchainId,
            tokenHomeAddress: homeAddress,
            tokenHomeDecimals: homeDecimals
        });

        vm.startBroadcast();
        ERC20TokenRemote remote = new ERC20TokenRemote(
            settings,
            tokenName,
            tokenSymbol,
            remoteDecimals
        );
        remoteAddress = address(remote);
        vm.stopBroadcast();

        console.log("=== ERC20TokenRemote Deployed ===");
        console.log("  Remote:       ", remoteAddress);
        console.log("  Name:         ", tokenName);
        console.log("  Symbol:       ", tokenSymbol);
        console.log("  Home address: ", homeAddress);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "../../lib/forge-std/src/Script.sol";
import {ITokenRemote} from "../../lib/icm-services/icm-contracts/avalanche/ictt/TokenRemote/interfaces/ITokenRemote.sol";
import {TeleporterFeeInfo} from "../../lib/icm-services/icm-contracts/avalanche/teleporter/ITeleporterMessenger.sol";

/**
 * @title RegisterRemoteWithHome
 * @notice Step 4 — Register an ERC20TokenRemote with its ERC20TokenHome via ICM message.
 *         Run this on the REMOTE chain. The ICM relayer must be running to deliver the
 *         registration message to the home chain.
 *
 * Environment variables:
 *   TOKEN_REMOTE_ADDRESS  — ERC20TokenRemote on THIS chain (required)
 *   FEE_TOKEN_ADDRESS     — fee token for relayer incentive, address(0) for no fee (default: 0x0)
 *   FEE_AMOUNT            — fee amount in raw units (default: 0)
 *   PRIVATE_KEY           — deployer/sender private key
 *
 * Usage:
 *   FOUNDRY_PROFILE=ictt forge script ictt/script/RegisterRemoteWithHome.s.sol \
 *     --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
 */
contract RegisterRemoteWithHome is Script {
    function run() external {
        address remoteAddr = vm.envAddress("TOKEN_REMOTE_ADDRESS");
        address feeToken = vm.envOr("FEE_TOKEN_ADDRESS", address(0));
        uint256 feeAmount = vm.envOr("FEE_AMOUNT", uint256(0));

        vm.startBroadcast();
        ITokenRemote(remoteAddr).registerWithHome(
            TeleporterFeeInfo({feeTokenAddress: feeToken, amount: feeAmount})
        );
        vm.stopBroadcast();

        console.log("=== registerWithHome called ===");
        console.log("  Remote:    ", remoteAddr);
        console.log("  Fee token: ", feeToken);
        console.log("  Fee amount:", feeAmount);
        console.log("");
        console.log("  >> Run the ICM relayer to deliver the message to the home chain.");
    }
}

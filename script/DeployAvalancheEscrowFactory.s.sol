// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AvalancheEscrowFactory} from "../src/AvalancheEscrows/AvalancheEscrowFactory.sol";

contract DeployAvalancheEscrowFactory is Script {
    /// @notice Deploy AvalancheEscrowFactory with deterministic address (CREATE2).
    /// @param _owner Address that will own the factory (pause, whitelist, etc.)
    function run(address _owner) external {
        if (_owner == address(0)) revert("DeployAvalancheEscrowFactory: zero owner");

        vm.startBroadcast();

        bytes32 salt = keccak256("avalanche-escrow-factory-v2");
        AvalancheEscrowFactory factory = new AvalancheEscrowFactory{salt: salt}(_owner);

        console.log("AvalancheEscrowFactory deployed at:", address(factory));
        console.log("Owner:", _owner);

        vm.stopBroadcast();
    }

    /// @notice Deploy AvalancheEscrowFactory without CREATE2 (for chains without the deployer).
    /// @param _owner Address that will own the factory (pause, whitelist, etc.)
    function runNoDeterministic(address _owner) external {
        if (_owner == address(0)) revert("DeployAvalancheEscrowFactory: zero owner");

        vm.startBroadcast();

        AvalancheEscrowFactory factory = new AvalancheEscrowFactory(_owner);

        console.log("AvalancheEscrowFactory deployed at:", address(factory));
        console.log("Owner:", _owner);

        vm.stopBroadcast();
    }
}

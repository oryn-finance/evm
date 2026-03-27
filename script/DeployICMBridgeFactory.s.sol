// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICMBridgeFactory} from "../src/ICMBridgeFactory.sol";

contract DeployICMBridgeFactory is Script {
    /// @notice Deploy ICMBridgeFactory with deterministic address.
    /// @param _owner Address that will own the factory (register routes, pause, etc.)
    function run(address _owner) external {
        if (_owner == address(0)) revert("DeployICMBridgeFactory: zero owner");

        vm.startBroadcast();

        bytes32 salt = keccak256("icm-bridge-factory");
        ICMBridgeFactory factory = new ICMBridgeFactory{salt: salt}(_owner);

        console.log("ICMBridgeFactory deployed at:", address(factory));
        console.log("Owner:", _owner);

        vm.stopBroadcast();
    }
}

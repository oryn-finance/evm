// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {SwapRegistry} from "../src/SwapRegistry.sol";

contract DeploySwapRegistry is Script {
    function run(address _owner) external {
        vm.startBroadcast();

        SwapRegistry registry = new SwapRegistry(_owner);

        console.log("SwapRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}

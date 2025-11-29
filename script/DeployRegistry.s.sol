// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {SwapRegistry} from "../src/SwapRegistry.sol";

contract DeploySwapRegistry is Script {
    function run() external {
        vm.startBroadcast();

        // bytes32 salt = keccak256(abi.encode("orynfi_registry"));
        // SwapRegistry registry = new SwapRegistry{salt: salt}();
        SwapRegistry registry = new SwapRegistry();

        console.log("SwapRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}

// https://api.routescan.io/v2/network/testnet/evm/43113/etherscan

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SwapRegistry} from "../src/SwapRegistry.sol";

contract DeploySwapRegistry is Script {
    function run(address _owner) external {
        vm.startBroadcast();

        bytes32 salt = keccak256("swapregistry");
        SwapRegistry registry = new SwapRegistry{salt: salt}(_owner);
        // SwapRegistry registry = SwapRegistry(0xC2B45A621ECda87818DA1D9F22272a636f233047);

        console.log("SwapRegistry deployed at:", address(registry));

        address[] memory tokens = new address[](2);
        // tokens[0] = address(0x32e6A42bffA30082Da8401DaABc1E68d5FA7BF4E);
        // tokens[1] = address(0xa6c72F80ad6761E34405Aa33a4a611356407c278);
        tokens[0] = address(0x3cd5902CDf8e74B7f2340D0BEa25006cE46f7B48);
        tokens[1] = address(0xcbD43C2a7b6cB3df228FDd49A535C82D673109eB);

        for (uint256 i = 0; i < tokens.length; i++) {
            registry.whitelistToken(tokens[i], true);
        }

        vm.stopBroadcast();
    }
}

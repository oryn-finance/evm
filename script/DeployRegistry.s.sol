// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";

contract DeployEscrowFactory is Script {
    function run(address _owner) external {
        vm.startBroadcast();

        bytes32 salt = keccak256("escrowfactory");
        EscrowFactory factory = new EscrowFactory{salt: salt}(_owner);

        console.log("EscrowFactory deployed at:", address(factory));

        address[] memory tokens = new address[](2);
        tokens[0] = address(0x3cd5902CDf8e74B7f2340D0BEa25006cE46f7B48);
        tokens[1] = address(0xcbD43C2a7b6cB3df228FDd49A535C82D673109eB);

        for (uint256 i = 0; i < tokens.length; i++) {
            factory.whitelistToken(tokens[i]);
        }

        vm.stopBroadcast();
    }
}

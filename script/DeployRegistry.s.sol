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

        vm.stopBroadcast();
    }
}

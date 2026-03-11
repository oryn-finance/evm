// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";

contract WhitelistTokens is Script {
    /// @notice Whitelist a single token on an existing EscrowFactory. Call multiple times for multiple tokens.
    /// @param _factory EscrowFactory contract address
    /// @param _token ERC20 token address to whitelist
    function run(address _factory, address _token) external {
        if (_token == address(0)) revert("WhitelistTokens: zero token address");
        EscrowFactory factory = EscrowFactory(payable(_factory));

        vm.startBroadcast();
        factory.whitelistToken(_token);
        console.log("Whitelisted token at:", _token);
        vm.stopBroadcast();
    }
}

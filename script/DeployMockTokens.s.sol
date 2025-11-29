// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract DeployMockTokens is Script {
    function run() external {
        vm.startBroadcast();

        USDC x = new USDC();
        console.log("the address to the deployed USDC: ", address(x));

        WBTC y = new WBTC();
        console.log("the address to the deployed WBTC: ", address(y));

        vm.stopBroadcast();
    }
}

contract USDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 100_000_000_000 * (10 ** decimals()));
    }

    function minttoken(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract WBTC is ERC20 {
    constructor() ERC20("Mock WBTC", "WBTC") {
        _mint(msg.sender, 100_000_000_000 * (10 ** decimals()));
    }

    function minttoken(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

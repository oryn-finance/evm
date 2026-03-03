// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DeployMockTokens is Script {
    function run(address _owner) external {
        vm.startBroadcast();

        bytes32 saltusdc = keccak256("usdc");
        USDC x = new USDC{salt: saltusdc}(_owner);
        console.log("the address to the deployed USDC: ", address(x));

        bytes32 saltwbtc = keccak256("wbtc");
        WBTC y = new WBTC{salt: saltwbtc}(_owner);
        console.log("the address to the deployed WBTC: ", address(y));

        vm.stopBroadcast();
    }
}

contract USDC is ERC20 {
    constructor(address _owner) ERC20("USDC", "USDC") {
        _mint(_owner, 100_000_000_000 * (10 ** decimals()));
    }

    function minttoken(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract WBTC is ERC20 {
    constructor(address _owner) ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(_owner, 21_000_000 * (10 ** decimals()));
    }

    function minttoken(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

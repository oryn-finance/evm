// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DeployErc20Tokens is Script {
    function run(address _owner) external {
        vm.startBroadcast();

        bytes32 saltUsdc = keccak256("usdc");
        USDC usdc = new USDC{salt: saltUsdc}(_owner);
        console.log("USDC deployed at:", address(usdc));

        bytes32 saltWbtc = keccak256("wbtc");
        WBTC wbtc = new WBTC{salt: saltWbtc}(_owner);
        console.log("WBTC deployed at:", address(wbtc));

        vm.stopBroadcast();
    }
}

contract USDC is ERC20 {
    constructor(address _owner) ERC20("USDC", "USDC") {
        _mint(_owner, 100_000_000_000 * (10 ** decimals()));
    }

    function mintToken(address to, uint256 amount) external {
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

    function mintToken(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

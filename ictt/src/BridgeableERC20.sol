// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/ERC20.sol";

/**
 * @title BridgeableERC20
 * @notice Minimal ERC20 for ICTT deployments. Deploy on the home chain, then
 *         bridge via ERC20TokenHome / ERC20TokenRemote.
 * @dev For testnet / from-scratch deployments. NOT audited for production.
 */
contract BridgeableERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        if (initialSupply_ > 0) {
            _mint(msg.sender, initialSupply_);
        }
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}

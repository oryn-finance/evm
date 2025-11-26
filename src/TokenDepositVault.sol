// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenDepositVault is Initializable {
    using Clones for address;
    using SafeERC20 for IERC20;

    uint256 public s_depositedAt;

    error TokenDepositVault__InvalidCommitment();
    error TokenDepositVault__SwapNotExpired();
    error TokenDepositVault__NativeWithdrawFailed();

    event Withdraw(address indexed recipient, bytes commitment);
    event Cancel(address indexed creator, bytes32 commitmentHash);

    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        s_depositedAt = block.number;
    }

    function withdraw(bytes calldata _commitment) external {
        (address token,, address recipient,, bytes32 commitmentHash) = getSwapParameters();

        require(sha256(_commitment) == commitmentHash, TokenDepositVault__InvalidCommitment());

        if (token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            (bool success,) = recipient.call{value: address(this).balance, gas: 5000}("");
            require(success, TokenDepositVault__NativeWithdrawFailed());
        } else {
            IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)));
        }

        emit Withdraw(recipient, _commitment);
    }

    function cancelSwap() external {
        (address token, address creator,, uint256 expiryblocks, bytes32 commitmentHash) = getSwapParameters();

        require(block.number > s_depositedAt + expiryblocks, TokenDepositVault__SwapNotExpired());

        if (token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            (bool success,) = creator.call{value: address(this).balance, gas: 5000}("");
            require(success, TokenDepositVault__NativeWithdrawFailed());
        } else {
            IERC20(token).safeTransfer(creator, IERC20(token).balanceOf(address(this)));
        }

        emit Cancel(creator, commitmentHash);
    }

    function getSwapParameters() internal view returns (address, address, address, uint256, bytes32) {
        bytes memory args = address(this).fetchCloneArgs();
        return abi.decode(args, (address, address, address, uint256, bytes32));
    }
}

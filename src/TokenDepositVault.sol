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
        (,,, uint256 expiryBlocks,,) = getSwapParameters();
        s_depositedAt = block.number + expiryBlocks;
    }

    function withdraw(bytes calldata _commitment) external {
        (address token,, address recipient,, bytes32 commitmentHash,) = getSwapParameters();

        require(sha256(_commitment) == commitmentHash, TokenDepositVault__InvalidCommitment());

        if (token == address(0)) {
            (bool success,) = recipient.call{value: address(this).balance, gas: 2500}("");
            require(success, TokenDepositVault__NativeWithdrawFailed());
        } else {
            IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)));
        }

        emit Withdraw(recipient, _commitment);
    }

    function cancelSwap() external {
        (address token, address creator,,, bytes32 commitmentHash,) = getSwapParameters();

        require(block.number >= s_depositedAt, TokenDepositVault__SwapNotExpired());

        if (token == address(0)) {
            (bool success,) = creator.call{value: address(this).balance, gas: 2500}("");
            require(success, TokenDepositVault__NativeWithdrawFailed());
        } else {
            IERC20(token).safeTransfer(creator, IERC20(token).balanceOf(address(this)));
        }

        emit Cancel(creator, commitmentHash);
    }

    function getSwapParameters() internal view returns (address, address, address, uint256, bytes32, uint256) {
        bytes memory args = address(this).fetchCloneArgs();
        return abi.decode(args, (address, address, address, uint256, bytes32, uint256));
    }
}

// contract NativeDepositVault is Initializable {
//     using Clones for address;
//     using SafeERC20 for IERC20;

//     uint256 public depositedAt;

//     constructor() {
//         _disableInitializers();
//     }

//     function initialize() public initializer {
//         // (
//         //     address nativeEscrowContract,
//         //     address creator,
//         //     address recipient,
//         //     uint256 expiryBlocks,
//         //     bytes32 commitmentHash,
//         //     uint256 amount
//         // ) = getSwapParameters();
//         // NativeTokenEscrow(nativeEscrowContract).createSwapFor{value: amount}(
//         //     payable(creator),
//         //     payable(recipient),
//         //     expiryBlocks,
//         //     amount,
//         //     commitmentHash
//         // );
//     }

//     function getSwapParameters() internal view returns (address, address, address, uint256, bytes32, uint256) {
//         bytes memory args = address(this).fetchCloneArgs();
//         return abi.decode(args, (address, address, address, uint256, bytes32, uint256));
//     }

//     function withdraw() external {}

//     function cancelSwap() external {}

// }

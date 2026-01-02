// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenDepositVault is Initializable {
    using Clones for address;
    using SafeERC20 for IERC20;

    /// @notice Block number when the vault was initialized and assets were deposited
    /// @dev Used to enforce swap expiry deadlines
    uint256 public s_depositedAt;

    // 0x245729d0
    error TokenDepositVault__InvalidCommitment();
    // 0x265cc10b
    error TokenDepositVault__SwapNotExpired();
    // 0xe587eaf5
    error TokenDepositVault__NativeWithdrawFailed();

    /// @notice Emitted when assets are withdrawn by the recipient via valid commitment
    /// @param recipient Address that received the withdrawn assets
    /// @param commitment Preimage that satisfied the commitment hash
    event Withdraw(address indexed recipient, bytes commitment);

    /// @notice Emitted when assets are returned to creator after swap expiry
    /// @param creator Address that receives the returned assets
    /// @param commitmentHash Hash of the original swap commitment
    event Cancel(address indexed creator, bytes32 commitmentHash);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault and records the deposit block number
    /// @dev Can only be called once per vault due to Initializable guard
    /// @dev Called immediately after clone deployment by SwapRegistry
    function initialize() public initializer {
        // Record the block number when assets were deposited for expiry calculations
        s_depositedAt = block.number;
    }

    /// @notice Withdraws vault assets to the recipient if valid commitment is provided
    /// @param _commitment The preimage that hashes to the stored commitmentHash
    /// @dev Supports both ERC20 tokens and native ETH withdrawal
    /// @dev Reverts if commitment does not match or is invalid
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

    /// @notice Returns vault assets to the creator after the swap has expired
    /// @dev Only callable after expiryBlocks have passed since initialization
    /// @dev Supports both ERC20 tokens and native ETH withdrawal
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

    /// @notice Retrieves swap parameters stored as immutable arguments in the clone
    /// @return token Address of the ERC20 token or NATIVE_TOKEN sentinel for ETH
    /// @return creator Address of the swap initiator who deposits the assets
    /// @return recipient Address that can withdraw by revealing commitment
    /// @return expiryBlocks Number of blocks until the swap expires
    /// @return commitmentHash Hash (SHA256) that must be revealed to withdraw
    /// @dev Internal helper that decodes clone immutable arguments
    function getSwapParameters() internal view returns (address, address, address, uint256, bytes32) {
        bytes memory args = address(this).fetchCloneArgs();
        return abi.decode(args, (address, address, address, uint256, bytes32));
    }
}

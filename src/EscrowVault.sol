//
//    ▄▄▄▄                                  ▄▄                  ▄▄
//   ██▀▀██                                 ██                  ██
//  ██    ██   ██▄████  ▀██  ███  ██▄████▄  ██         ▄█████▄  ██▄███▄   ▄▄█████▄
//  ██    ██   ██▀       ██▄ ██   ██▀   ██  ██         ▀ ▄▄▄██  ██▀  ▀██  ██▄▄▄▄ ▀
//  ██    ██   ██         ████▀   ██    ██  ██        ▄██▀▀▀██  ██    ██   ▀▀▀▀██▄
//   ██▄▄██    ██          ███    ██    ██  ██▄▄▄▄▄▄  ██▄▄▄███  ███▄▄██▀  █▄▄▄▄▄██
//    ▀▀▀▀     ▀▀          ██     ▀▀    ▀▀  ▀▀▀▀▀▀▀▀   ▀▀▀▀ ▀▀  ▀▀ ▀▀▀     ▀▀▀▀▀▀
//                       ███
//
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EscrowVault is Initializable {
    using Clones for address;
    using SafeERC20 for IERC20;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Errors ////////////////
    //////////////////////////////////
    //////////////////////////////////

    // 0x245729d0
    error EscrowVault__InvalidCommitment();
    // 0x265cc10b
    error EscrowVault__EscrowNotExpired();
    // 0xe587eaf5
    error EscrowVault__NativeTransferFailed();
    // 0xc9d92dfc
    error EscrowVault__EscrowAlreadySettled();

    //////////////////////////////////
    //////////////////////////////////
    /////// Constants ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Sentinel address representing native ETH
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //////////////////////////////////
    //////////////////////////////////
    ////// State Variables ///////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Block number when the escrow was initialized and assets were deposited
    /// @dev Used to enforce escrow expiry deadlines
    uint256 public s_depositedAt;

    /// @notice Whether the escrow has been settled (claimed or refunded)
    /// @dev Once true, no further claim or refund operations are allowed
    bool public s_settled;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Events ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Emitted when assets are claimed by the recipient via valid commitment
    /// @param recipient Address that received the claimed assets
    /// @param commitment Preimage that satisfied the commitment hash
    event Claimed(address indexed recipient, bytes32 commitment);

    /// @notice Emitted when assets are returned to creator after escrow expiry
    /// @param creator Address that receives the returned assets
    /// @param commitmentHash Hash of the original escrow commitment
    event Refunded(address indexed creator, bytes32 commitmentHash);

    //////////////////////////////////
    //////////////////////////////////
    /////// Constructor //////////////
    //////////////////////////////////
    //////////////////////////////////

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the escrow and records the deposit block number
    /// @dev Can only be called once per escrow due to Initializable guard
    /// @dev Called immediately after clone deployment by EscrowFactory
    function initialize() public initializer {
        // Record the block number when assets were deposited for expiry calculations
        s_depositedAt = block.number;
    }

    //////////////////////////////////
    //////////////////////////////////
    ////////// Functions /////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Claims escrow assets to the recipient if valid commitment is provided
    /// @param _commitment The preimage that hashes to the stored commitmentHash
    /// @dev Supports both ERC20 tokens and native ETH
    /// @dev Reverts if commitment does not match or is invalid
    function claim(bytes32 _commitment) external {
        require(!s_settled, EscrowVault__EscrowAlreadySettled());

        (address token,, address recipient,, bytes32 commitmentHash) = getEscrowParameters();

        require(sha256(abi.encodePacked(_commitment)) == commitmentHash, EscrowVault__InvalidCommitment());

        s_settled = true;

        if (token == NATIVE_TOKEN) {
            (bool success,) = recipient.call{value: address(this).balance, gas: 8000}("");
            require(success, EscrowVault__NativeTransferFailed());
        } else {
            IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)));
        }

        emit Claimed(recipient, _commitment);
    }

    /// @notice Returns escrow assets to the creator after the escrow has expired
    /// @dev Only callable after expiryBlocks have passed since initialization
    /// @dev Supports both ERC20 tokens and native ETH
    function refund() external {
        require(!s_settled, EscrowVault__EscrowAlreadySettled());

        (address token, address creator,, uint256 expiryBlocks, bytes32 commitmentHash) = getEscrowParameters();

        require(block.number > s_depositedAt + expiryBlocks, EscrowVault__EscrowNotExpired());

        s_settled = true;

        if (token == NATIVE_TOKEN) {
            (bool success,) = creator.call{value: address(this).balance, gas: 8000}("");
            require(success, EscrowVault__NativeTransferFailed());
        } else {
            IERC20(token).safeTransfer(creator, IERC20(token).balanceOf(address(this)));
        }

        emit Refunded(creator, commitmentHash);
    }

    //////////////////////////////////
    //////////////////////////////////
    //////// Getter Functions ////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Retrieves escrow parameters stored as immutable arguments in the clone
    /// @return token Address of the ERC20 token or NATIVE_TOKEN sentinel for ETH
    /// @return creator Address of the escrow initiator who deposits the assets
    /// @return recipient Address that can claim by revealing commitment
    /// @return expiryBlocks Number of blocks until the escrow expires
    /// @return commitmentHash Hash (SHA256) that must be revealed to claim
    function getEscrowParameters() public view returns (address, address, address, uint256, bytes32) {
        bytes memory args = address(this).fetchCloneArgs();
        return abi.decode(args, (address, address, address, uint256, bytes32));
    }
}

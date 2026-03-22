// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Input parameters for a single-hop ERC20 token transfer via Avalanche ICTT.
///         Mirrors the canonical SendTokensInput struct from ava-labs/icm-contracts.
struct SendTokensInput {
    /// @dev Avalanche blockchain ID of the destination chain (bytes32, not uint256 EVM chain ID)
    bytes32 destinationBlockchainID;
    /// @dev Address of the TokenRemote (or TokenHome) contract on the destination chain
    address destinationTokenTransferrerAddress;
    /// @dev Address on the destination chain that will receive the bridged tokens
    address recipient;
    /// @dev Token used to pay the ICM relayer incentive (address(0) = no fee)
    address primaryFeeTokenAddress;
    /// @dev Relayer incentive amount in primaryFeeToken units
    uint256 primaryRelayerFee;
    /// @dev Secondary relayer fee for multi-hop routes (0 for single-hop)
    uint256 secondaryRelayerFee;
    /// @dev Gas limit forwarded to the ICM relayer for message delivery on the destination chain
    uint256 requiredGasLimit;
    /// @dev Fallback address for multi-hop if the intermediate hop fails (address(0) for single-hop)
    address multiHopFallback;
}

/// @notice Minimal interface for ICTT ERC20TokenHome and ERC20TokenRemote contracts.
///         Both contracts implement this send function — callers approve tokens to the
///         transferrer then call send() to initiate an ICM cross-chain transfer.
interface ITokenTransferrer {
    function send(SendTokensInput calldata input, uint256 amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal interface for ICMBridgeFactory used by AvalancheEscrowVault.claimHop()
interface IICMBridgeFactory {
    function bridge(
        address token,
        uint256 amount,
        bytes32 destBlockchainId,
        address recipient,
        address primaryFeeToken,
        uint256 primaryRelayerFee
    ) external;
}

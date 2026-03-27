// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICMBridgeFactory} from "../src/ICMBridgeFactory.sol";

contract RegisterBridgeRoute is Script {
    /// @notice Register a bridge route on an existing ICMBridgeFactory.
    /// @param _factory        ICMBridgeFactory address
    /// @param _token          ERC20 token on this chain (e.g. WBTC on C-chain, or wrappedWBTC on L1)
    /// @param _destBlockchainId Avalanche blockchain ID of the destination chain (bytes32)
    /// @param _tokenTransferrer Local ITokenTransferrer (TokenHome on C-chain, TokenRemote on L1)
    /// @param _destTransferrer  Paired transferrer on destination (TokenRemote on L1, TokenHome on C-chain)
    /// @param _gasLimit       Required gas limit for ICM relayer delivery on destination
    function run(
        address _factory,
        address _token,
        bytes32 _destBlockchainId,
        address _tokenTransferrer,
        address _destTransferrer,
        uint256 _gasLimit
    ) external {
        if (_factory == address(0)) revert("RegisterBridgeRoute: zero factory");
        if (_token == address(0)) revert("RegisterBridgeRoute: zero token");
        if (_destBlockchainId == bytes32(0)) revert("RegisterBridgeRoute: zero blockchain ID");
        if (_tokenTransferrer == address(0)) revert("RegisterBridgeRoute: zero tokenTransferrer");
        if (_destTransferrer == address(0)) revert("RegisterBridgeRoute: zero destTransferrer");
        if (_gasLimit == 0) revert("RegisterBridgeRoute: zero gas limit");

        ICMBridgeFactory factory = ICMBridgeFactory(_factory);

        vm.startBroadcast();

        factory.registerRoute(_token, _destBlockchainId, _tokenTransferrer, _destTransferrer, _gasLimit);

        console.log("Route registered on ICMBridgeFactory:", _factory);
        console.log("  Token:", _token);
        console.log("  TokenTransferrer:", _tokenTransferrer);
        console.log("  DestTransferrer:", _destTransferrer);

        vm.stopBroadcast();
    }
}

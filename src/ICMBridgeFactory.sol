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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenTransferrer, SendTokensInput} from "./interfaces/IICTT.sol";

/// @author Oryn Finance
/// @title ICMBridgeFactory
/// @notice Registry and routing layer for Avalanche ICM / ICTT token bridges.
///
///         Manages bridge routes (token → destination blockchain → TokenTransferrer pair)
///         and provides a single entry-point for users to bridge ERC20s between Avalanche
///         chains using the mint-and-burn ICTT pattern:
///           - Home chain  : ERC20TokenHome  — locks tokens, emits ICM message
///           - Remote chain: ERC20TokenRemote — mints on receive, burns on send-back
///
///         The factory is the sole caller of ITokenTransferrer.send(). It pulls tokens
///         from the user, approves the transferrer, and dispatches the ICM message.
///
/// @dev Avalanche-specific: uses bytes32 blockchain IDs, not uint256 EVM chain IDs.
///      Designed to complement EscrowFactory — both are independent, deployable separately.
///      EscrowFactory (v1) is chain-agnostic HTLC; this contract (v2) is Avalanche-only bridging.
contract ICMBridgeFactory is Ownable, Pausable {
    using SafeERC20 for IERC20;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Errors ////////////////
    //////////////////////////////////
    //////////////////////////////////

    // 0x755f4be0
    error ICMBridgeFactory__ZeroAddress();
    // 0x66627364
    error ICMBridgeFactory__ZeroAmount();
    // 0xfa576eee
    error ICMBridgeFactory__RouteNotFound();
    // 0x37733856
    error ICMBridgeFactory__RouteAlreadyRegistered();
    // 0x94eeb618
    error ICMBridgeFactory__ZeroGasLimit();
    // 0xae120c30
    error ICMBridgeFactory__InvalidBlockchainId();
    // 0x0587de8c
    error ICMBridgeFactory__InvalidFeeParameters();

    //////////////////////////////////
    //////////////////////////////////
    /////// Structs //////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Configuration for a single ERC20 bridge route on one destination chain
    /// @param tokenTransferrer Local ERC20TokenHome (C-Chain) or ERC20TokenRemote (L1) address
    /// @param destTransferrer  Paired ERC20TokenRemote (L1) or ERC20TokenHome (C-Chain) on destination
    /// @param requiredGasLimit Gas limit the ICM relayer uses to deliver the message on the destination
    /// @param active           Whether this route is enabled
    struct BridgeRoute {
        address tokenTransferrer;
        address destTransferrer;
        uint256 requiredGasLimit;
        bool active;
    }

    //////////////////////////////////
    //////////////////////////////////
    ////// State Variables ///////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice token address → Avalanche destination blockchain ID (bytes32) → bridge route
    mapping(address token => mapping(bytes32 destBlockchainId => BridgeRoute)) public s_routes;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Events ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Emitted when a new bridge route is registered
    event RouteRegistered(
        address indexed token,
        bytes32 indexed destBlockchainId,
        address tokenTransferrer,
        address destTransferrer,
        uint256 requiredGasLimit
    );

    /// @notice Emitted when an existing bridge route's parameters are updated
    event RouteUpdated(
        address indexed token,
        bytes32 indexed destBlockchainId,
        address tokenTransferrer,
        address destTransferrer,
        uint256 requiredGasLimit
    );

    /// @notice Emitted when a bridge route is removed
    event RouteDeregistered(address indexed token, bytes32 indexed destBlockchainId);

    /// @notice Emitted when a cross-chain token transfer is initiated
    /// @param token            ERC20 token bridged
    /// @param destBlockchainId Destination Avalanche blockchain ID
    /// @param sender           Address that called bridge()
    /// @param recipient        Address on the destination chain receiving the tokens
    /// @param amount           Token amount forwarded to the ICTT transferrer (net, before fee if fee is in bridge token)
    /// @param relayerFee       Relayer incentive fee amount
    event BridgeSent(
        address indexed token,
        bytes32 indexed destBlockchainId,
        address indexed sender,
        address recipient,
        uint256 amount,
        uint256 relayerFee
    );

    //////////////////////////////////
    //////////////////////////////////
    /////// Constructor //////////////
    //////////////////////////////////
    //////////////////////////////////

    constructor(address _owner) Ownable(_owner) {}

    //////////////////////////////////
    //////////////////////////////////
    ////////// Functions /////////////
    //////////////////////////////////
    //////////////////////////////////

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Pauses all bridge operations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses bridge operations
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Registers a new bridge route for an ERC20 token on a destination Avalanche chain
    /// @param token            ERC20 token to enable bridging for
    /// @param destBlockchainId Avalanche blockchain ID of the destination chain (bytes32 hex)
    /// @param tokenTransferrer Local ERC20TokenHome or ERC20TokenRemote contract address
    /// @param destTransferrer  Destination ERC20TokenRemote or ERC20TokenHome contract address
    /// @param requiredGasLimit ICM relayer gas limit for delivery on the destination chain (e.g. 250_000)
    function registerRoute(
        address token,
        bytes32 destBlockchainId,
        address tokenTransferrer,
        address destTransferrer,
        uint256 requiredGasLimit
    ) external onlyOwner {
        require(
            token != address(0) && tokenTransferrer != address(0) && destTransferrer != address(0),
            ICMBridgeFactory__ZeroAddress()
        );
        require(destBlockchainId != bytes32(0), ICMBridgeFactory__InvalidBlockchainId());
        require(requiredGasLimit > 0, ICMBridgeFactory__ZeroGasLimit());
        require(!s_routes[token][destBlockchainId].active, ICMBridgeFactory__RouteAlreadyRegistered());

        s_routes[token][destBlockchainId] = BridgeRoute({
            tokenTransferrer: tokenTransferrer,
            destTransferrer: destTransferrer,
            requiredGasLimit: requiredGasLimit,
            active: true
        });

        emit RouteRegistered(token, destBlockchainId, tokenTransferrer, destTransferrer, requiredGasLimit);
    }

    /// @notice Updates the transferrer addresses or gas limit for an existing bridge route
    /// @param token            ERC20 token whose route to update
    /// @param destBlockchainId Avalanche destination blockchain ID
    /// @param tokenTransferrer New local TokenHome / TokenRemote address
    /// @param destTransferrer  New destination TokenRemote / TokenHome address
    /// @param requiredGasLimit New ICM delivery gas limit
    function updateRoute(
        address token,
        bytes32 destBlockchainId,
        address tokenTransferrer,
        address destTransferrer,
        uint256 requiredGasLimit
    ) external onlyOwner {
        require(
            token != address(0) && tokenTransferrer != address(0) && destTransferrer != address(0),
            ICMBridgeFactory__ZeroAddress()
        );
        require(requiredGasLimit > 0, ICMBridgeFactory__ZeroGasLimit());
        require(s_routes[token][destBlockchainId].active, ICMBridgeFactory__RouteNotFound());

        s_routes[token][destBlockchainId] = BridgeRoute({
            tokenTransferrer: tokenTransferrer,
            destTransferrer: destTransferrer,
            requiredGasLimit: requiredGasLimit,
            active: true
        });

        emit RouteUpdated(token, destBlockchainId, tokenTransferrer, destTransferrer, requiredGasLimit);
    }

    /// @notice Removes a bridge route, preventing further bridging for that token/chain pair
    /// @param token            ERC20 token whose route to remove
    /// @param destBlockchainId Avalanche destination blockchain ID
    function deregisterRoute(address token, bytes32 destBlockchainId) external onlyOwner {
        require(s_routes[token][destBlockchainId].active, ICMBridgeFactory__RouteNotFound());
        delete s_routes[token][destBlockchainId];
        emit RouteDeregistered(token, destBlockchainId);
    }

    // ─── Bridge ───────────────────────────────────────────────────────────────

    /// @notice Bridge ERC20 tokens to a destination Avalanche chain via ICTT
    ///
    ///         Token flow:
    ///           sender → ICMBridgeFactory → ITokenTransferrer.send() → (ICM message) → recipient
    ///
    ///         Fee handling:
    ///           - No fee    : pass primaryFeeToken = address(0), primaryRelayerFee = 0
    ///           - Fee in bridge token: pass primaryFeeToken = token, primaryRelayerFee = fee.
    ///             Caller must approve amount + primaryRelayerFee to this contract.
    ///             The ICTT transferrer deducts the fee from the combined pull.
    ///           - Fee in separate token: pass primaryFeeToken = feeTokenAddress, primaryRelayerFee = fee.
    ///             Caller must approve both the bridge token (amount) and the fee token (primaryRelayerFee).
    ///
    /// @param token             ERC20 token to bridge (must have an active registered route)
    /// @param amount            Net token amount the recipient will receive on the destination chain
    /// @param destBlockchainId  Avalanche destination blockchain ID (bytes32)
    /// @param recipient         Address on the destination chain to receive the tokens
    /// @param primaryFeeToken   Token address for the ICM relayer incentive (address(0) = no fee)
    /// @param primaryRelayerFee Relayer incentive amount (0 = no fee)
    function bridge(
        address token,
        uint256 amount,
        bytes32 destBlockchainId,
        address recipient,
        address primaryFeeToken,
        uint256 primaryRelayerFee
    ) external whenNotPaused {
        require(amount > 0, ICMBridgeFactory__ZeroAmount());
        require(recipient != address(0), ICMBridgeFactory__ZeroAddress());
        require(
            primaryRelayerFee == 0 || primaryFeeToken != address(0), ICMBridgeFactory__InvalidFeeParameters()
        );

        BridgeRoute memory route = s_routes[token][destBlockchainId];
        require(route.active, ICMBridgeFactory__RouteNotFound());

        // ── Pull bridge tokens ──────────────────────────────────────────────
        // When the relayer fee is denominated in the bridge token, ICTT pulls
        // (amount + fee) from the caller in a single transferFrom, so we must
        // approve the combined amount.
        uint256 tokenPullAmount = amount;
        if (primaryFeeToken == token && primaryRelayerFee > 0) {
            tokenPullAmount += primaryRelayerFee;
        }
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenPullAmount);
        IERC20(token).forceApprove(route.tokenTransferrer, tokenPullAmount);

        // ── Pull separate fee token (if applicable) ─────────────────────────
        if (primaryFeeToken != address(0) && primaryFeeToken != token && primaryRelayerFee > 0) {
            IERC20(primaryFeeToken).safeTransferFrom(msg.sender, address(this), primaryRelayerFee);
            IERC20(primaryFeeToken).forceApprove(route.tokenTransferrer, primaryRelayerFee);
        }

        // ── Dispatch ICM message ────────────────────────────────────────────
        ITokenTransferrer(route.tokenTransferrer).send(
            SendTokensInput({
                destinationBlockchainID: destBlockchainId,
                destinationTokenTransferrerAddress: route.destTransferrer,
                recipient: recipient,
                primaryFeeTokenAddress: primaryFeeToken,
                primaryRelayerFee: primaryRelayerFee,
                secondaryRelayerFee: 0,
                requiredGasLimit: route.requiredGasLimit,
                multiHopFallback: address(0)
            }),
            amount
        );

        emit BridgeSent(token, destBlockchainId, msg.sender, recipient, amount, primaryRelayerFee);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /// @notice Returns the full BridgeRoute struct for a token/destination pair
    /// @dev Returns a zeroed struct (active = false) if no route is registered
    function getRoute(address token, bytes32 destBlockchainId) external view returns (BridgeRoute memory) {
        return s_routes[token][destBlockchainId];
    }

    /// @notice Returns whether a bridge route is currently active
    function isRouteActive(address token, bytes32 destBlockchainId) external view returns (bool) {
        return s_routes[token][destBlockchainId].active;
    }
}

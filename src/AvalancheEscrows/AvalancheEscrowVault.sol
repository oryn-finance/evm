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
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IICMBridgeFactory} from "../interfaces/IICMBridgeFactory.sol";

/// @author Oryn Finance
/// @title AvalancheEscrowVault
/// @notice HTLC escrow vault clone that optionally routes the claim through an
///         Avalanche ICM bridge to deliver tokens on a destination L1.
///
///         Two settlement paths based on the immutable `l1Hop` flag:
///
///         l1Hop = false — standard HTLC
///           claim(preimage) → transfers tokens to recipient on THIS chain
///
///         l1Hop = true  — cross-chain HTLC
///           claimHop(preimage, recipientSig, hopData) →
///             verifies preimage + recipient signature over hopData →
///             calls ICMBridgeFactory.bridge() → tokens locked in TokenHome →
///             ICM message → TokenRemote mints to hopData.recipient on destination L1
///
///         refund() is always available to creator after expiry, regardless of l1Hop.
///
/// @dev Clone-with-immutable-args pattern: args are ABI-encoded by AvalancheEscrowFactory
///      and stored in the clone's bytecode. Read back via fetchCloneArgs().
///      Arg layout: (address token, address creator, address recipient,
///                   uint256 expiryBlocks, bytes32 commitmentHash, bool l1Hop)
contract AvalancheEscrowVault is Initializable {
    using Clones for address;
    using SafeERC20 for IERC20;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Errors ////////////////
    //////////////////////////////////
    //////////////////////////////////

    // 0x7d85c817
    error AvalancheEscrowVault__InvalidCommitment();
    // 0x461c2e18
    error AvalancheEscrowVault__EscrowNotExpired();
    // 0xd2d0dad5
    error AvalancheEscrowVault__NativeTransferFailed();
    // 0xcd90e25b
    error AvalancheEscrowVault__EscrowAlreadySettled();
    // 0x8abc0b00 — claim() called on a l1Hop vault; use claimHop() instead
    error AvalancheEscrowVault__IsHopEscrow();
    // 0xbecd325b — claimHop() called on a non-hop vault; use claim() instead
    error AvalancheEscrowVault__NotHopEscrow();
    // 0xbab3b546 — recipient's signature over HopData is invalid or from wrong signer
    error AvalancheEscrowVault__InvalidHopSignature();
    // 0x97c8dc41 — separate fee token not supported; use address(0) or the bridge token
    error AvalancheEscrowVault__UnsupportedFeeToken();
    // 0x488d2ddf — vault balance is less than the requested relayer fee
    error AvalancheEscrowVault__InsufficientBalanceForFee();

    //////////////////////////////////
    //////////////////////////////////
    /////// Constants ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Sentinel address representing native ETH
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice EIP-191 personal-sign struct hash for HopAuthorization.
    ///         chainId and vault are embedded directly in the signed data (not in a domain
    ///         separator) keeping the vault free of EIP-712 domain infrastructure.
    ///         - chainId  prevents cross-chain replay (same vault address, different network)
    ///         - vault    prevents cross-vault replay (same creator, different escrow)
    bytes32 public constant HOP_AUTHORIZATION_TYPEHASH = keccak256(
        "HopAuthorization(uint256 chainId,address vault,bytes32 commitmentHash,address bridgeFactory,bytes32 destBlockchainId,address recipient,address primaryFeeToken,uint256 primaryRelayerFee)"
    );

    //////////////////////////////////
    //////////////////////////////////
    /////// Structs //////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Parameters for the cross-chain hop, signed by the recipient (redeemer) and passed at claim time
    /// @param bridgeFactory     ICMBridgeFactory on this chain
    /// @param destBlockchainId  Avalanche destination blockchain ID (bytes32)
    /// @param recipient         Address on the destination L1 that receives the bridged tokens
    /// @param primaryFeeToken   Relayer fee token: address(0) = no fee, or the bridge token address
    ///                          (separate third-party fee tokens are not supported from a vault)
    /// @param primaryRelayerFee Relayer incentive amount in primaryFeeToken units (0 = no fee)
    struct HopData {
        address bridgeFactory;
        bytes32 destBlockchainId;
        address recipient;
        address primaryFeeToken;
        uint256 primaryRelayerFee;
    }

    //////////////////////////////////
    //////////////////////////////////
    ////// State Variables ///////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Block number when the escrow was initialized
    uint256 public s_depositedAt;

    /// @notice Whether this escrow has been settled (claimed, claimHop-ed, or refunded)
    bool public s_settled;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Events ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Emitted when a standard (non-hop) claim succeeds
    event Claimed(address indexed recipient, bytes32 commitment);

    /// @notice Emitted when a cross-chain hop claim is dispatched to ICMBridgeFactory
    /// @param commitment       Preimage that satisfied the commitmentHash
    /// @param destBlockchainId Destination Avalanche L1 blockchain ID
    /// @param hopRecipient     Address on the destination chain receiving the tokens
    /// @param amount           Net token amount bridged
    event ClaimedHop(
        bytes32 commitment, bytes32 indexed destBlockchainId, address indexed hopRecipient, uint256 amount
    );

    /// @notice Emitted when assets are returned to creator after expiry
    event Refunded(address indexed creator, bytes32 commitmentHash);

    //////////////////////////////////////////////////////////////////////////
    // Constructor / Initialize
    //////////////////////////////////////////////////////////////////////////

    constructor() {
        _disableInitializers();
    }

    /// @notice Records the deposit block. Called once by AvalancheEscrowFactory after clone deploy.
    function initialize() public initializer {
        s_depositedAt = block.number;
    }

    //////////////////////////////////////////////////////////////////////////
    // Settlement functions
    //////////////////////////////////////////////////////////////////////////

    /// @notice Claim escrow assets to the on-chain recipient (l1Hop must be false)
    /// @param _commitment Preimage whose SHA-256 equals the stored commitmentHash
    function claim(bytes32 _commitment) external {
        require(!s_settled, AvalancheEscrowVault__EscrowAlreadySettled());

        (address token,, address recipient,, bytes32 commitmentHash, bool l1Hop) = getEscrowParameters();

        require(!l1Hop, AvalancheEscrowVault__IsHopEscrow());
        require(sha256(abi.encodePacked(_commitment)) == commitmentHash, AvalancheEscrowVault__InvalidCommitment());

        s_settled = true;

        if (token == NATIVE_TOKEN) {
            (bool ok,) = recipient.call{value: address(this).balance, gas: 8000}("");
            require(ok, AvalancheEscrowVault__NativeTransferFailed());
        } else {
            IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)));
        }

        emit Claimed(recipient, _commitment);
    }

    /// @notice Claim and bridge tokens to a destination L1 via ICMBridgeFactory (l1Hop must be true)
    /// @param _commitment Preimage whose SHA-256 equals the stored commitmentHash
    /// @param _signature  Recipient's EIP-191 signature over HopAuthorization(vault, commitmentHash, hopData...)
    /// @param _hopData    Destination routing: bridgeFactory, destChain, recipient on L1, fee config
    /// @dev Only ERC20 tokens are supported for hop escrows (native token cannot be bridged via ICTT ERC20 path)
    /// @dev If primaryFeeToken == token: vault approves (balance) to factory; factory deducts fee
    ///      If primaryFeeToken == address(0): full balance bridged, no relayer fee
    ///      Separate fee tokens are rejected — the vault does not hold them
    function claimHop(bytes32 _commitment, bytes calldata _signature, HopData calldata _hopData) external {
        require(!s_settled, AvalancheEscrowVault__EscrowAlreadySettled());

        (address token,, address recipient,, bytes32 commitmentHash, bool l1Hop) = getEscrowParameters();

        require(l1Hop, AvalancheEscrowVault__NotHopEscrow());
        require(sha256(abi.encodePacked(_commitment)) == commitmentHash, AvalancheEscrowVault__InvalidCommitment());

        // ── Verify recipient (redeemer) authorized this exact hop destination ──
        // This prevents frontrunning: even if a bot extracts the secret from the
        // mempool, they cannot redirect funds without the recipient's signature.
        _verifyHopSignature(recipient, commitmentHash, _hopData, _signature);

        // ── Validate fee token: only bridge token or no fee supported ───────
        require(
            _hopData.primaryFeeToken == address(0) || _hopData.primaryFeeToken == token,
            AvalancheEscrowVault__UnsupportedFeeToken()
        );

        // ── Calculate amounts ────────────────────────────────────────────────
        uint256 vaultBalance = IERC20(token).balanceOf(address(this));
        uint256 bridgeAmount;

        if (_hopData.primaryFeeToken == token && _hopData.primaryRelayerFee > 0) {
            require(vaultBalance > _hopData.primaryRelayerFee, AvalancheEscrowVault__InsufficientBalanceForFee());
            // ICMBridgeFactory pulls (bridgeAmount + fee) when feeToken == token
            bridgeAmount = vaultBalance - _hopData.primaryRelayerFee;
        } else {
            bridgeAmount = vaultBalance;
        }

        s_settled = true;

        // ── Approve and dispatch via ICMBridgeFactory ────────────────────────
        IERC20(token).forceApprove(_hopData.bridgeFactory, vaultBalance);

        IICMBridgeFactory(_hopData.bridgeFactory)
            .bridge(
                token,
                bridgeAmount,
                _hopData.destBlockchainId,
                _hopData.recipient,
                _hopData.primaryFeeToken,
                _hopData.primaryRelayerFee
            );

        emit ClaimedHop(_commitment, _hopData.destBlockchainId, _hopData.recipient, bridgeAmount);
    }

    /// @notice Return assets to creator after the escrow has expired (works for both hop and non-hop)
    function refund() external {
        require(!s_settled, AvalancheEscrowVault__EscrowAlreadySettled());

        (address token, address creator,, uint256 expiryBlocks, bytes32 commitmentHash,) = getEscrowParameters();

        require(block.number >= s_depositedAt + expiryBlocks, AvalancheEscrowVault__EscrowNotExpired());

        s_settled = true;

        if (token == NATIVE_TOKEN) {
            (bool ok,) = creator.call{value: address(this).balance, gas: 8000}("");
            require(ok, AvalancheEscrowVault__NativeTransferFailed());
        } else {
            IERC20(token).safeTransfer(creator, IERC20(token).balanceOf(address(this)));
        }

        emit Refunded(creator, commitmentHash);
    }

    //////////////////////////////////////////////////////////////////////////
    // View
    //////////////////////////////////////////////////////////////////////////

    /// @notice Returns all escrow parameters stored as immutable args in the clone
    function getEscrowParameters()
        public
        view
        returns (
            address token,
            address creator,
            address recipient,
            uint256 expiryBlocks,
            bytes32 commitmentHash,
            bool l1Hop
        )
    {
        bytes memory args = address(this).fetchCloneArgs();
        return abi.decode(args, (address, address, address, uint256, bytes32, bool));
    }

    //////////////////////////////////////////////////////////////////////////
    // Internal
    //////////////////////////////////////////////////////////////////////////

    /// @notice Verifies that _signature is the recipient's (redeemer's) EIP-191 personal
    ///         signature over the hop authorization hash. This ensures only the rightful
    ///         redeemer can authorize the bridge destination, preventing frontrunning attacks
    ///         where a bot extracts the secret from mempool and redirects funds.
    ///         chainId and vault address are included in the hash to prevent cross-chain
    ///         and cross-vault replay without EIP-712 domain infrastructure.
    function _verifyHopSignature(
        address recipient,
        bytes32 commitmentHash,
        HopData calldata _hopData,
        bytes calldata _signature
    ) internal view {
        bytes32 hash = keccak256(
            abi.encode(
                HOP_AUTHORIZATION_TYPEHASH,
                block.chainid,
                address(this),
                commitmentHash,
                _hopData.bridgeFactory,
                _hopData.destBlockchainId,
                _hopData.recipient,
                _hopData.primaryFeeToken,
                _hopData.primaryRelayerFee
            )
        );
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), _signature);
        require(signer == recipient, AvalancheEscrowVault__InvalidHopSignature());
    }
}

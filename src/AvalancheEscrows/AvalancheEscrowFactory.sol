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

import {AvalancheEscrowVault} from "./AvalancheEscrowVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @author Oryn Finance
/// @title AvalancheEscrowFactory
/// @notice Extension of the core EscrowFactory design for Avalanche chains.
///
///         Adds a single boolean — `l1Hop` — to every escrow creation path.
///         When l1Hop = false the vault behaves identically to EscrowVault (standard HTLC).
///         When l1Hop = true the vault's claim path is replaced by claimHop(), which
///         routes the settlement through an ICMBridgeFactory to deliver tokens on a
///         destination Avalanche L1 (Base → C-Chain lock → ICM message → L1 mint).
///
///         l1Hop is included in the deterministic salt, so the same parameters with
///         l1Hop=true and l1Hop=false produce different vault addresses.
///
///         Native token (ETH/AVAX) escrows with l1Hop=true are rejected — the ICM ERC20
///         bridging path requires an ERC20 token on the home chain.
contract AvalancheEscrowFactory is Ownable, Pausable, EIP712 {
    using Clones for address;
    using Address for address;
    using SafeERC20 for IERC20;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Errors ////////////////
    //////////////////////////////////
    //////////////////////////////////

    // 0xf3eac7ab
    error AvalancheEscrowFactory__InvalidAddressParameters();
    // 0x92be78de
    error AvalancheEscrowFactory__ZeroExpiryBlocks();
    // 0xa418527d
    error AvalancheEscrowFactory__ZeroAmount();
    // 0x28195c7e
    error AvalancheEscrowFactory__InsufficientFundsDeposited();
    // 0xca651666
    error AvalancheEscrowFactory__TokenNotAccepted();
    // 0xe1f9d064
    error AvalancheEscrowFactory__EscrowAlreadyDeployed();
    // 0xa2581b2f
    error AvalancheEscrowFactory__MsgValueAmountMismatch();
    // 0x3ceac956
    error AvalancheEscrowFactory__NativeDepositFailed();
    // 0x246c0997
    error AvalancheEscrowFactory__OnlyNativeTokenAllowed();
    // 0x54fda3c9
    error AvalancheEscrowFactory__OnlyERC20Allowed();
    // 0x6164d1f6
    error AvalancheEscrowFactory__InvalidSignature();
    // 0xf2ba4af2
    error AvalancheEscrowFactory__PermitFailed();
    // 0x37d2b7db
    error AvalancheEscrowFactory__InvalidCommitmentHash();
    // 0x8c618abc
    error AvalancheEscrowFactory__EmptyBatch();
    // 0x4ac44998 — native token escrows cannot use the ICM ERC20 bridge hop path
    error AvalancheEscrowFactory__NativeNotSupportedForHop();

    //////////////////////////////////
    //////////////////////////////////
    /////// Structs //////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Parameters for a single escrow creation call (also used in batch)
    struct EscrowParams {
        address token;
        address creator;
        address recipient;
        uint256 expiryBlocks;
        bytes32 commitmentHash;
        uint256 amount;
        bool l1Hop;
    }

    //////////////////////////////////
    //////////////////////////////////
    /////// Constants ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice EIP-712 typehash for CreateEscrowParams
    bytes32 public constant CREATE_ESCROW_TYPEHASH = keccak256(
        "CreateEscrowParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount,bool l1Hop)"
    );

    /// @notice Sentinel address representing native ETH/AVAX
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //////////////////////////////////
    //////////////////////////////////
    ////// State Variables ///////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice AvalancheEscrowVault reference implementation used for cloning
    address public immutable i_escrowImplementation;

    /// @notice Token whitelist
    mapping(address => bool) public s_whitelistedTokens;

    /// @notice Tracks deployed escrow addresses to prevent duplicate creation
    mapping(address => bool) public s_deployedEscrows;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Events ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Emitted when a new escrow vault is deployed
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed creator,
        address indexed token,
        address recipient,
        bytes32 commitmentHash,
        uint256 expiryBlocks,
        uint256 amount,
        bool l1Hop
    );

    event TokenWhitelisted(address indexed tokenAddress);
    event TokenDelisted(address indexed tokenAddress);

    //////////////////////////////////
    //////////////////////////////////
    /////// Constructor //////////////
    //////////////////////////////////
    //////////////////////////////////

    constructor(address _owner) EIP712("AvalancheEscrowFactory", "1.0.0") Ownable(_owner) {
        i_escrowImplementation = address(new AvalancheEscrowVault());
    }

    //////////////////////////////////
    //////////////////////////////////
    ////////// Functions /////////////
    //////////////////////////////////
    //////////////////////////////////

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function whitelistToken(address _tokenAddress) external onlyOwner {
        s_whitelistedTokens[_tokenAddress] = true;
        emit TokenWhitelisted(_tokenAddress);
    }

    function delistToken(address _tokenAddress) external onlyOwner {
        s_whitelistedTokens[_tokenAddress] = false;
        emit TokenDelisted(_tokenAddress);
    }

    /// @notice Creates a new pre-funded escrow vault
    /// @param p.l1Hop When true the vault enforces claimHop() instead of claim()
    function createEscrow(EscrowParams calldata p) external whenNotPaused returns (address) {
        _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
        require(s_whitelistedTokens[p.token], AvalancheEscrowFactory__TokenNotAccepted());
        if (p.l1Hop) require(p.token != NATIVE_TOKEN, AvalancheEscrowFactory__NativeNotSupportedForHop());

        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(p.token, p.creator, p.recipient, p.expiryBlocks, p.commitmentHash, p.l1Hop);

        address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);
        require(!s_deployedEscrows[addr], AvalancheEscrowFactory__EscrowAlreadyDeployed());

        if (p.token == NATIVE_TOKEN) {
            require(address(addr).balance >= p.amount, AvalancheEscrowFactory__InsufficientFundsDeposited());
        } else {
            require(IERC20(p.token).balanceOf(addr) >= p.amount, AvalancheEscrowFactory__InsufficientFundsDeposited());
        }

        _deployEscrow(encodedArgs, salt, p.amount);
        return addr;
    }

    /// @notice Creates multiple pre-funded escrow vaults in one transaction
    function createEscrowBatch(EscrowParams[] calldata params)
        external
        whenNotPaused
        returns (address[] memory escrows)
    {
        uint256 length = params.length;
        require(length > 0, AvalancheEscrowFactory__EmptyBatch());
        escrows = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            EscrowParams calldata p = params[i];
            _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
            require(s_whitelistedTokens[p.token], AvalancheEscrowFactory__TokenNotAccepted());
            if (p.l1Hop) require(p.token != NATIVE_TOKEN, AvalancheEscrowFactory__NativeNotSupportedForHop());

            (bytes memory encodedArgs, bytes32 salt) =
                _getEscrowArgsAndSalt(p.token, p.creator, p.recipient, p.expiryBlocks, p.commitmentHash, p.l1Hop);

            address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);
            require(!s_deployedEscrows[addr], AvalancheEscrowFactory__EscrowAlreadyDeployed());

            if (p.token == NATIVE_TOKEN) {
                require(address(addr).balance >= p.amount, AvalancheEscrowFactory__InsufficientFundsDeposited());
            } else {
                require(
                    IERC20(p.token).balanceOf(addr) >= p.amount, AvalancheEscrowFactory__InsufficientFundsDeposited()
                );
            }

            _deployEscrow(encodedArgs, salt, p.amount);
            escrows[i] = addr;
        }
    }

    /// @notice Creates a native token escrow in one transaction (p.l1Hop must be false)
    function createEscrowNative(EscrowParams calldata p) external payable whenNotPaused returns (address) {
        _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
        require(p.token == NATIVE_TOKEN, AvalancheEscrowFactory__OnlyNativeTokenAllowed());
        require(!p.l1Hop, AvalancheEscrowFactory__NativeNotSupportedForHop());
        require(msg.value == p.amount, AvalancheEscrowFactory__MsgValueAmountMismatch());
        require(s_whitelistedTokens[p.token], AvalancheEscrowFactory__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(p.token, p.creator, p.recipient, p.expiryBlocks, p.commitmentHash, p.l1Hop);

        address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);
        require(!s_deployedEscrows[addr], AvalancheEscrowFactory__EscrowAlreadyDeployed());

        (bool success,) = addr.call{value: p.amount, gas: 8000}("");
        require(success, AvalancheEscrowFactory__NativeDepositFailed());

        _deployEscrow(encodedArgs, salt, p.amount);
        return addr;
    }

    /// @notice Creates an ERC20 escrow in one transaction using EIP-2612 permit
    function createEscrowPermit(EscrowParams calldata p, uint256 deadline, bytes calldata signature)
        external
        whenNotPaused
        returns (address)
    {
        _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
        require(p.token != NATIVE_TOKEN, AvalancheEscrowFactory__OnlyERC20Allowed());
        require(s_whitelistedTokens[p.token], AvalancheEscrowFactory__TokenNotAccepted());

        _executePermit(p.token, p.creator, p.amount, deadline, signature);

        return _createErc20EscrowFromCreator(p);
    }

    /// @notice Creates an ERC20 escrow using EIP-712 signed authorization (relayer-submittable)
    function createEscrowSigned(EscrowParams calldata p, bytes calldata signature)
        external
        whenNotPaused
        returns (address)
    {
        _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
        require(p.token != NATIVE_TOKEN, AvalancheEscrowFactory__OnlyERC20Allowed());
        require(s_whitelistedTokens[p.token], AvalancheEscrowFactory__TokenNotAccepted());

        _verifyCreateEscrowSignature(p, signature);

        return _createErc20EscrowFromCreator(p);
    }

    /// @notice Predicts the deterministic vault address without deploying it
    function getEscrowAddress(EscrowParams calldata p) external view returns (address) {
        _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
        require(s_whitelistedTokens[p.token], AvalancheEscrowFactory__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(p.token, p.creator, p.recipient, p.expiryBlocks, p.commitmentHash, p.l1Hop);
        address predictedAddr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedEscrows[predictedAddr], AvalancheEscrowFactory__EscrowAlreadyDeployed());

        return predictedAddr;
    }

    //////////////////////////////////////////////////////////////////////////
    // Internal
    //////////////////////////////////////////////////////////////////////////

    function _safeParams(address creator, address recipient, uint256 expiryBlocks, uint256 amount) internal pure {
        require(
            recipient != address(0) && creator != address(0) && creator != recipient,
            AvalancheEscrowFactory__InvalidAddressParameters()
        );
        require(expiryBlocks > 0, AvalancheEscrowFactory__ZeroExpiryBlocks());
        require(amount > 0, AvalancheEscrowFactory__ZeroAmount());
    }

    function _verifyCreateEscrowSignature(EscrowParams calldata p, bytes calldata signature) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_ESCROW_TYPEHASH,
                p.token,
                p.creator,
                p.recipient,
                p.expiryBlocks,
                p.commitmentHash,
                p.amount,
                p.l1Hop
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == p.creator, AvalancheEscrowFactory__InvalidSignature());
    }

    function _createErc20EscrowFromCreator(EscrowParams calldata p) internal returns (address) {
        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(p.token, p.creator, p.recipient, p.expiryBlocks, p.commitmentHash, p.l1Hop);
        address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedEscrows[addr], AvalancheEscrowFactory__EscrowAlreadyDeployed());

        IERC20(p.token).safeTransferFrom(p.creator, addr, p.amount);
        require(IERC20(p.token).balanceOf(addr) >= p.amount, AvalancheEscrowFactory__InsufficientFundsDeposited());

        _deployEscrow(encodedArgs, salt, p.amount);
        return addr;
    }

    function _executePermit(address token, address creator, uint256 amount, uint256 deadline, bytes calldata signature)
        internal
    {
        (uint8 v, bytes32 r, bytes32 s) = ECDSA.parseCalldata(signature);
        try IERC20Permit(token).permit(creator, address(this), amount, deadline, v, r, s) {}
        catch {
            revert AvalancheEscrowFactory__PermitFailed();
        }
    }

    function _deployEscrow(bytes memory encodedArgs, bytes32 salt, uint256 amount) internal {
        address escrow = i_escrowImplementation.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
        escrow.functionCall(abi.encodeCall(AvalancheEscrowVault.initialize, ()));
        (address token, address creator, address recipient, uint256 expiryBlocks, bytes32 commitmentHash, bool l1Hop) =
            abi.decode(encodedArgs, (address, address, address, uint256, bytes32, bool));
        emit EscrowCreated(escrow, creator, token, recipient, commitmentHash, expiryBlocks, amount, l1Hop);
        s_deployedEscrows[escrow] = true;
    }

    /// @notice Encodes immutable args and computes deterministic salt.
    ///         l1Hop is included in both so that vaults with identical other params
    ///         but different l1Hop values deploy to different addresses.
    function _getEscrowArgsAndSalt(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        bool l1Hop
    ) internal view returns (bytes memory encodedArgs, bytes32 salt) {
        require(commitmentHash != bytes32(0), AvalancheEscrowFactory__InvalidCommitmentHash());
        encodedArgs = abi.encode(token, creator, recipient, expiryBlocks, commitmentHash, l1Hop);
        salt = keccak256(abi.encode(block.chainid, token, creator, recipient, expiryBlocks, commitmentHash, l1Hop));
    }
}

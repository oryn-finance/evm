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

import {EscrowVault} from "./EscrowVault.sol";
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
/// @title EscrowFactory
/// @notice Factory for creating deterministic escrow vaults that allow seamless atomic swaps
contract EscrowFactory is Ownable, Pausable, EIP712 {
    using Clones for address;
    using Address for address;
    using SafeERC20 for IERC20;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Errors ////////////////
    //////////////////////////////////
    //////////////////////////////////
    // 0xd6e2de8f
    error EscrowFactory__InvalidAddressParameters();
    // 0x2515eed4
    error EscrowFactory__ZeroExpiryBlocks();
    // 0x7510a9d5
    error EscrowFactory__ZeroAmount();
    // 0x65db15b5
    error EscrowFactory__InsufficientFundsDeposited();
    // 0xcd1f0e00
    error EscrowFactory__TokenNotAccepted();
    // 0x769f851d
    error EscrowFactory__EscrowAlreadyDeployed();
    // 0x784f0cfd
    error EscrowFactory__MsgValueAmountMismatch();
    // 0xc7104a3a
    error EscrowFactory__NativeDepositFailed();
    // 0xd1494aa7
    error EscrowFactory__OnlyNativeTokenAllowed();
    // 0xcd33b650
    error EscrowFactory__OnlyERC20Allowed();
    // 0x29265638
    error EscrowFactory__InvalidSignature();
    // 0xed772378
    error EscrowFactory__PermitFailed();
    // 0xddce1499
    error EscrowFactory__InvalidCommitmentHash();
    // 0x9236c60b
    error EscrowFactory__EmptyBatch();

    //////////////////////////////////
    //////////////////////////////////
    /////// Structs //////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Parameters for a single escrow in a batch creation call
    struct EscrowParams {
        address token;
        address creator;
        address recipient;
        uint256 expiryBlocks;
        bytes32 commitmentHash;
        uint256 amount;
    }

    //////////////////////////////////
    //////////////////////////////////
    /////// Constants ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice EIP-712 typehash for CreateEscrowParams (used in createEscrowSigned)
    bytes32 public constant CREATE_ESCROW_TYPEHASH = keccak256(
        "CreateEscrowParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount,uint256 nonce)"
    );

    /// @notice Sentinel address representing native ETH in escrow operations
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //////////////////////////////////
    //////////////////////////////////
    ////// State Variables ///////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Reference implementation of EscrowVault for cloning
    address public immutable i_escrowImplementation;

    /// @notice Mapping of token addresses to their whitelist status
    /// @dev true = whitelisted, false = not whitelisted
    mapping(address => bool) public s_whitelistedTokens;

    /// @notice Mapping tracking all deployed escrow addresses to prevent duplicates
    /// @dev Ensures deterministic addresses are only used once
    mapping(address => bool) public s_deployedEscrows;

    /// @notice Monotonically increasing nonce per creator for EIP-712 signed escrow creation
    /// @dev Prevents signature replay and allows creators to invalidate pending signatures
    mapping(address => uint256) public s_nonces;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Events ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Emitted when a new escrow is created
    /// @param escrowAddress Address of the newly created escrow
    /// @param creator Address of the escrow creator
    /// @param token Address of the ERC20 token for the escrow
    /// @param recipient Address that can claim by revealing commitment
    /// @param commitmentHash Hash that must be revealed to claim
    /// @param expiryBlocks Number of blocks until the escrow expires
    /// @param amount Token amount deposited into the escrow
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed creator,
        address indexed token,
        address recipient,
        bytes32 commitmentHash,
        uint256 expiryBlocks,
        uint256 amount
    );

    /// @notice Emitted when a token is added to the whitelist
    /// @param tokenAddress Address of the token
    event TokenWhitelisted(address indexed tokenAddress);

    /// @notice Emitted when a token is removed from the whitelist
    /// @param tokenAddress Address of the token
    event TokenDelisted(address indexed tokenAddress);

    //////////////////////////////////
    //////////////////////////////////
    /////// Modifers /////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Validates common parameters across escrow creation functions
    /// @param creator Address initiating the escrow
    /// @param recipient Address receiving the escrow assets
    /// @param expiryBlocks Block count before the escrow expires
    /// @param amount Token amount to be deposited
    modifier safeParams(address creator, address recipient, uint256 expiryBlocks, uint256 amount) {
        _safeParams(creator, recipient, expiryBlocks, amount);
        _;
    }

    function _safeParams(address creator, address recipient, uint256 expiryBlocks, uint256 amount) internal pure {
        require(
            recipient != address(0) && creator != address(0) && creator != recipient,
            EscrowFactory__InvalidAddressParameters()
        );
        require(expiryBlocks > 0, EscrowFactory__ZeroExpiryBlocks());
        require(amount > 0, EscrowFactory__ZeroAmount());
    }

    //////////////////////////////////
    //////////////////////////////////
    /////// Constructor //////////////
    //////////////////////////////////
    //////////////////////////////////

    constructor(address _owner) EIP712("EscrowFactory", "1.0.0") Ownable(_owner) {
        i_escrowImplementation = address(new EscrowVault());
    }

    //////////////////////////////////
    //////////////////////////////////
    ////////// Functions /////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Pauses all escrow creation operations
    /// @dev Only callable by contract owner. Does not affect existing escrow claim/refund.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses escrow creation operations
    /// @dev Only callable by contract owner
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Increments the caller's nonce, invalidating all pending EIP-712 signatures
    /// @dev Useful for creators who want to cancel outstanding signed escrow authorizations
    function incrementNonce() external {
        s_nonces[msg.sender]++;
    }

    /// @notice Adds a token to the whitelist for escrow usage
    /// @param _tokenAddress The ERC20 token contract address to whitelist
    /// @dev Only callable by contract owner
    function whitelistToken(address _tokenAddress) external onlyOwner {
        s_whitelistedTokens[_tokenAddress] = true;
        emit TokenWhitelisted(_tokenAddress);
    }

    /// @notice Removes a token from the whitelist
    /// @param _tokenAddress The ERC20 token contract address to delist
    /// @dev Only callable by contract owner
    function delistToken(address _tokenAddress) external onlyOwner {
        s_whitelistedTokens[_tokenAddress] = false;
        emit TokenDelisted(_tokenAddress);
    }

    /// @notice Creates a new deterministic escrow vault
    /// @param token Address of the ERC20 token to deposit (must be whitelisted)
    /// @param creator Address of the escrow creator/initiator
    /// @param recipient Address that will receive the escrow assets
    /// @param expiryBlocks Number of blocks until the escrow expires
    /// @param commitmentHash Hash of the escrow commitment/terms
    /// @param amount Minimum token amount required in the escrow
    /// @return Address of the newly created escrow
    /// @dev The escrow address is deterministic and based on all parameters
    /// @dev Creator must pre-fund the predicted escrow address with tokens before calling
    function createEscrow(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) external whenNotPaused safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(s_whitelistedTokens[token], EscrowFactory__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);

        address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedEscrows[addr], EscrowFactory__EscrowAlreadyDeployed());

        if (token == NATIVE_TOKEN) {
            require(address(addr).balance >= amount, EscrowFactory__InsufficientFundsDeposited());
        } else {
            require(IERC20(token).balanceOf(addr) >= amount, EscrowFactory__InsufficientFundsDeposited());
        }

        _deployEscrow(encodedArgs, salt, amount);
        return addr;
    }

    /// @notice Creates multiple pre-funded escrows in a single transaction
    /// @param params Array of EscrowParams structs, one per escrow
    /// @return escrows Array of deployed escrow addresses
    /// @dev Each escrow must be pre-funded at its predicted address before calling
    /// @dev Reverts entirely if any single escrow in the batch fails
    function createEscrowBatch(EscrowParams[] calldata params)
        external
        whenNotPaused
        returns (address[] memory escrows)
    {
        uint256 length = params.length;
        require(length > 0, EscrowFactory__EmptyBatch());

        escrows = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            EscrowParams calldata p = params[i];

            _safeParams(p.creator, p.recipient, p.expiryBlocks, p.amount);
            require(s_whitelistedTokens[p.token], EscrowFactory__TokenNotAccepted());

            (bytes memory encodedArgs, bytes32 salt) =
                _getEscrowArgsAndSalt(p.token, p.creator, p.recipient, p.expiryBlocks, p.commitmentHash);

            address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

            require(!s_deployedEscrows[addr], EscrowFactory__EscrowAlreadyDeployed());

            if (p.token == NATIVE_TOKEN) {
                require(address(addr).balance >= p.amount, EscrowFactory__InsufficientFundsDeposited());
            } else {
                require(IERC20(p.token).balanceOf(addr) >= p.amount, EscrowFactory__InsufficientFundsDeposited());
            }

            _deployEscrow(encodedArgs, salt, p.amount);
            escrows[i] = addr;
        }
    }

    /// @notice Creates a new deterministic escrow for native ETH in one tx
    /// @param token Address of the ERC20 token to deposit (must be whitelisted)
    /// @param creator Address of the escrow creator/initiator
    /// @param recipient Address that will receive the escrow assets
    /// @param expiryBlocks Number of blocks until the escrow expires
    /// @param commitmentHash Hash of the escrow commitment/terms
    /// @param amount Minimum token amount required in the escrow
    /// @return Address of the newly created escrow
    /// @dev The escrow address is deterministic and based on all parameters
    /// @dev Creator must pre-fund the predicted escrow address with tokens before calling
    function createEscrowNative(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) external payable whenNotPaused safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(token == NATIVE_TOKEN, EscrowFactory__OnlyNativeTokenAllowed());
        require(msg.value == amount, EscrowFactory__MsgValueAmountMismatch());
        require(s_whitelistedTokens[token], EscrowFactory__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);

        address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        {
            require(!s_deployedEscrows[addr], EscrowFactory__EscrowAlreadyDeployed());
            (bool success,) = addr.call{value: amount, gas: 10000}("");
            require(success, EscrowFactory__NativeDepositFailed());
        }

        _deployEscrow(encodedArgs, salt, amount);
        return addr;
    }

    /// @notice Creates a deterministic ERC20 escrow in one tx using EIP-2612 permit (no prior approve needed)
    /// @param token ERC20 token with permit support (must be whitelisted)
    /// @param creator Escrow creator who signs the permit
    /// @param recipient Address that will receive the escrow assets
    /// @param expiryBlocks Number of blocks until the escrow expires
    /// @param commitmentHash Hash of the escrow commitment/terms
    /// @param amount Token amount to deposit
    /// @param deadline Permit signature deadline (unix timestamp)
    /// @return Address of the newly created escrow
    function createEscrowPermit(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(token != NATIVE_TOKEN, EscrowFactory__OnlyERC20Allowed());
        require(s_whitelistedTokens[token], EscrowFactory__TokenNotAccepted());

        _executePermit(token, creator, amount, deadline, signature);

        return _createErc20EscrowFromCreator(token, creator, recipient, expiryBlocks, commitmentHash, amount);
    }

    /// @notice Creates a deterministic ERC20 escrow using EIP-712 signed authorization (relayer can submit)
    /// @dev Creator must have approved this factory to spend tokens before calling
    /// @param token ERC20 token (must be whitelisted)
    /// @param creator Escrow creator who signed the params
    /// @param recipient Address that will receive the escrow assets
    /// @param expiryBlocks Number of blocks until the escrow expires
    /// @param commitmentHash Hash of the escrow commitment/terms
    /// @param amount Token amount to deposit
    /// @param signature EIP-712 signature over CreateEscrowParams
    /// @return Address of the newly created escrow
    function createEscrowSigned(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        bytes calldata signature
    ) external whenNotPaused safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(token != NATIVE_TOKEN, EscrowFactory__OnlyERC20Allowed());
        require(s_whitelistedTokens[token], EscrowFactory__TokenNotAccepted());

        _verifyCreateEscrowSignature(token, creator, recipient, expiryBlocks, commitmentHash, amount, signature);

        return _createErc20EscrowFromCreator(token, creator, recipient, expiryBlocks, commitmentHash, amount);
    }

    /// @notice Predicts the deterministic escrow address without creating it
    /// @param token Address of the ERC20 token for the escrow
    /// @param creator Address of the escrow creator
    /// @param recipient Address receiving the escrow assets
    /// @param expiryBlocks Number of blocks until expiry
    /// @param commitmentHash Hash of the escrow commitment
    /// @param amount Minimum required token amount
    /// @return Address where the escrow would be deployed
    /// @dev Useful for off-chain calculation of escrow address before funding
    /// @dev Reverts if escrow already exists at predicted address
    function getEscrowAddress(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) external view safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(s_whitelistedTokens[token], EscrowFactory__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);
        address predictedAddr =
            i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedEscrows[predictedAddr], EscrowFactory__EscrowAlreadyDeployed());

        return predictedAddr;
    }

    //////////////////////////////////
    //////////////////////////////////
    //////// Internal Functions ///////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Verifies EIP-712 signature for createEscrowSigned and increments nonce
    function _verifyCreateEscrowSignature(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        bytes calldata signature
    ) internal {
        uint256 nonce = s_nonces[creator]++;
        bytes32 structHash = keccak256(
            abi.encode(CREATE_ESCROW_TYPEHASH, token, creator, recipient, expiryBlocks, commitmentHash, amount, nonce)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == creator, EscrowFactory__InvalidSignature());
    }

    /// @notice Pulls ERC20 from creator to escrow address and deploys escrow
    function _createErc20EscrowFromCreator(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) internal returns (address) {
        (bytes memory encodedArgs, bytes32 salt) =
            _getEscrowArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);
        address addr = i_escrowImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedEscrows[addr], EscrowFactory__EscrowAlreadyDeployed());

        IERC20(token).safeTransferFrom(creator, addr, amount);
        require(IERC20(token).balanceOf(addr) >= amount, EscrowFactory__InsufficientFundsDeposited());

        _deployEscrow(encodedArgs, salt, amount);
        return addr;
    }

    /// @notice Executes EIP-2612 permit, reverting with PermitFailed on any failure
    function _executePermit(address token, address creator, uint256 amount, uint256 deadline, bytes calldata signature)
        internal
    {
        (uint8 v, bytes32 r, bytes32 s) = ECDSA.parseCalldata(signature);
        try IERC20Permit(token).permit(creator, address(this), amount, deadline, v, r, s) {}
        catch {
            revert EscrowFactory__PermitFailed();
        }
    }

    /// @notice Deploys escrow clone, initializes it, and marks as deployed
    /// @param encodedArgs ABI-encoded escrow params (token, creator, recipient, expiryBlocks, commitmentHash)
    /// @param salt Deterministic deployment salt
    /// @param amount Token amount deposited into the escrow
    function _deployEscrow(bytes memory encodedArgs, bytes32 salt, uint256 amount) internal {
        address escrow = i_escrowImplementation.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
        escrow.functionCall(abi.encodeCall(EscrowVault.initialize, ()));
        (address token, address creator, address recipient, uint256 expiryBlocks, bytes32 commitmentHash) =
            abi.decode(encodedArgs, (address, address, address, uint256, bytes32));
        emit EscrowCreated(escrow, creator, token, recipient, commitmentHash, expiryBlocks, amount);
        s_deployedEscrows[escrow] = true;
    }

    /// @notice Encodes escrow params and generates deterministic deployment salt
    /// @param token Token address
    /// @param creator Creator address
    /// @param recipient Recipient address
    /// @param expiryBlocks Block expiry count
    /// @param commitmentHash Escrow commitment hash
    /// @return encodedArgs ABI-encoded immutable arguments for cloning
    /// @return salt Keccak256 hash of chain-scoped parameters for deterministic deployment
    function _getEscrowArgsAndSalt(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash
    ) internal view returns (bytes memory encodedArgs, bytes32 salt) {
        require(commitmentHash != bytes32(0), EscrowFactory__InvalidCommitmentHash());
        encodedArgs = abi.encode(token, creator, recipient, expiryBlocks, commitmentHash);
        salt = keccak256(abi.encode(block.chainid, token, creator, recipient, expiryBlocks, commitmentHash));
    }
}

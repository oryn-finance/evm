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

import {TokenDepositVault} from "./TokenDepositVault.sol";
import {Clones} from "../lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @author Oryn Finance
/// @title SwapRegistry
/// @notice Factory for creating deterministic token deposit vaults that allow seamless atomic swaps
contract SwapRegistry is Ownable, EIP712 {
    using Clones for address;
    using Address for address;
    using SafeERC20 for IERC20;

    //////////////////////////////////
    //////////////////////////////////
    ////////// Errors ////////////////
    //////////////////////////////////
    //////////////////////////////////
    // 0xd6e2de8f
    error SwapRegistry__InvalidAddressParameters();
    // 0x2515eed4
    error SwapRegistry__ZeroExpiryBlocks();
    // 0x7510a9d5
    error SwapRegistry__ZeroAmount();
    // 0x65db15b5
    error SwapRegistry__InsufficientFundsDeposited();
    // 0xcd1f0e00
    error SwapRegistry__TokenNotAccepted();
    // 0x769f851d
    error SwapRegistry__VaultAlreadyDeployed();
    // 0x784f0cfd
    error SwapRegistry__MsgValueAmountMismatch();
    // 0xc7104a3a
    error SwapRegistry__NativeDepositFailed();
    // 0xd1494aa7
    error SwapRegistry__OnlyNativeTokenAllowed();
    // 0xcd33b650
    error SwapRegistry__OnlyERC20Allowed();
    // 0x29265638
    error SwapRegistry__InvalidSignature();
    // 0xed772378
    error SwapRegistry__PermitFailed();

    //////////////////////////////////
    //////////////////////////////////
    ////////// Events ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Emitted when a new token vault is created
    /// @param vaultAddress Address of the newly created vault
    /// @param creator Address of the vault creator
    /// @param token Address of the ERC20 token for the vault
    event VaultCreated(address indexed vaultAddress, address indexed creator, address indexed token);

    /// @notice Emitted when a token is whitelisted or blacklisted
    /// @param tokenAddress Address of the token
    event WhitelistedToken(address indexed tokenAddress);

    //////////////////////////////////
    //////////////////////////////////
    /////// Constants ////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice EIP-712 typehash for CreateVaultParams (used in createTokenSwapVaultSigned)
    bytes32 public constant CREATE_VAULT_TYPEHASH = keccak256(
        "CreateVaultParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount)"
    );

    /// @notice Sentinel address representing native ETH in swap operations
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //////////////////////////////////
    //////////////////////////////////
    ////// State Variables ///////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Reference implementation of TokenDepositVault for cloning
    address public immutable i_tokenVaultImplementation;

    /// @notice Mapping of token addresses to their whitelist status
    /// @dev true = whitelisted, false = not whitelisted
    mapping(address => bool) public s_whitelistedTokens;

    /// @notice Mapping tracking all deployed vault addresses to prevent duplicates
    /// @dev Ensures deterministic addresses are only used once
    mapping(address => bool) public s_deployedVaults;

    //////////////////////////////////
    //////////////////////////////////
    /////// Constructor //////////////
    //////////////////////////////////
    //////////////////////////////////

    constructor(address _owner) EIP712("SwapRegistry", "1.0.0") Ownable(_owner) {
        i_tokenVaultImplementation = address(new TokenDepositVault());
    }

    //////////////////////////////////
    //////////////////////////////////
    /////// Modifers /////////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Validates common parameters across vault creation functions
    /// @param creator Address initiating the swap
    /// @param recipient Address receiving the swap assets
    /// @param expiryBlocks Block count before the vault expires
    /// @param amount Token amount to be deposited
    modifier safeParams(address creator, address recipient, uint256 expiryBlocks, uint256 amount) {
        require(
            recipient != address(0) && creator != address(0) && creator != recipient,
            SwapRegistry__InvalidAddressParameters()
        );
        require(expiryBlocks > 0, SwapRegistry__ZeroExpiryBlocks());
        require(amount > 0, SwapRegistry__ZeroAmount());
        _;
    }

    //////////////////////////////////
    //////////////////////////////////
    ////////// Functions /////////////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Whitelists or blacklists an ERC20 token for swap usage
    /// @param _tokenAddress The ERC20 token contract address to modify
    /// @param _status True to whitelist, false to blacklist the token
    /// @dev Only callable by contract owner
    function whitelistToken(address _tokenAddress, bool _status) external onlyOwner {
        s_whitelistedTokens[_tokenAddress] = _status;
        emit WhitelistedToken(_tokenAddress);
    }

    /// @notice Creates a new deterministic token deposit vault
    /// @param token Address of the ERC20 token to deposit (must be whitelisted)
    /// @param creator Address of the vault creator/initiator
    /// @param recipient Address that will receive the swap
    /// @param expiryBlocks Number of blocks until the vault expires
    /// @param commitmentHash Hash of the swap commitment/terms
    /// @param amount Minimum token amount required in the vault
    /// @return Address of the newly created vault
    /// @dev The vault address is deterministic and based on all parameters
    /// @dev Creator must pre-fund the predicted vault address with tokens before calling
    function createTokenSwapVault(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) external safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getVaultArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);

        address addr = i_tokenVaultImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedVaults[addr], SwapRegistry__VaultAlreadyDeployed());

        if (token == NATIVE_TOKEN) {
            require(address(addr).balance >= amount, SwapRegistry__InsufficientFundsDeposited());
        } else {
            require(IERC20(token).balanceOf(addr) >= amount, SwapRegistry__InsufficientFundsDeposited());
        }

        _deployVault(encodedArgs, salt);
        return addr;
    }

    /// @notice Creates a new deterministic token deposit vault for native ETH in one tx
    /// @param token Address of the ERC20 token to deposit (must be whitelisted)
    /// @param creator Address of the vault creator/initiator
    /// @param recipient Address that will receive the swap
    /// @param expiryBlocks Number of blocks until the vault expires
    /// @param commitmentHash Hash of the swap commitment/terms
    /// @param amount Minimum token amount required in the vault
    /// @return Address of the newly created vault
    /// @dev The vault address is deterministic and based on all parameters
    /// @dev Creator must pre-fund the predicted vault address with tokens before calling
    function createTokenSwapVaultNativeCall(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) external payable safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(token == NATIVE_TOKEN, SwapRegistry__OnlyNativeTokenAllowed());
        require(msg.value == amount, SwapRegistry__MsgValueAmountMismatch());
        require(s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getVaultArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);

        address addr = i_tokenVaultImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        {
            require(!s_deployedVaults[addr], SwapRegistry__VaultAlreadyDeployed());
            (bool success,) = addr.call{value: amount, gas: 10000}("");
            require(success, SwapRegistry__NativeDepositFailed());
        }

        _deployVault(encodedArgs, salt);
        return addr;
    }

    /// @notice Creates a deterministic ERC20 vault in one tx using EIP-2612 permit (no prior approve needed)
    /// @param token ERC20 token with permit support (must be whitelisted)
    /// @param creator Vault creator who signs the permit
    /// @param recipient Address that will receive the swap
    /// @param expiryBlocks Number of blocks until the vault expires
    /// @param commitmentHash Hash of the swap commitment/terms
    /// @param amount Token amount to deposit
    /// @param deadline Permit signature deadline (unix timestamp)
    /// @return Address of the newly created vault
    function createTokenSwapVaultPermit(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(token != NATIVE_TOKEN, SwapRegistry__OnlyERC20Allowed());
        require(s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());

        _executePermit(token, creator, amount, deadline, signature);

        return _createERC20VaultFromCreator(token, creator, recipient, expiryBlocks, commitmentHash, amount);
    }

    /// @notice Creates a deterministic ERC20 vault using EIP-712 signed authorization (relayer can submit)
    /// @dev Creator must have approved this registry to spend tokens before calling
    /// @param token ERC20 token (must be whitelisted)
    /// @param creator Vault creator who signed the params
    /// @param recipient Address that will receive the swap
    /// @param expiryBlocks Number of blocks until the vault expires
    /// @param commitmentHash Hash of the swap commitment/terms
    /// @param amount Token amount to deposit
    /// @param signature EIP-712 signature over CreateVaultParams
    /// @return Address of the newly created vault
    function createTokenSwapVaultSigned(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        bytes calldata signature
    ) external safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(token != NATIVE_TOKEN, SwapRegistry__OnlyERC20Allowed());
        require(s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());

        _verifyCreateVaultSignature(token, creator, recipient, expiryBlocks, commitmentHash, amount, signature);

        return _createERC20VaultFromCreator(token, creator, recipient, expiryBlocks, commitmentHash, amount);
    }

    /// @notice Verifies EIP-712 signature for createTokenSwapVaultSigned
    function _verifyCreateVaultSignature(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(CREATE_VAULT_TYPEHASH, token, creator, recipient, expiryBlocks, commitmentHash, amount)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == creator, SwapRegistry__InvalidSignature());
    }

    /// @notice Pulls ERC20 from creator to vault address and deploys vault
    function _createERC20VaultFromCreator(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) internal returns (address) {
        (bytes memory encodedArgs, bytes32 salt) =
            _getVaultArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);
        address addr = i_tokenVaultImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedVaults[addr], SwapRegistry__VaultAlreadyDeployed());

        IERC20(token).safeTransferFrom(creator, addr, amount);
        require(IERC20(token).balanceOf(addr) >= amount, SwapRegistry__InsufficientFundsDeposited());

        _deployVault(encodedArgs, salt);
        return addr;
    }

    /// @notice Predicts the deterministic vault address without creating it
    /// @param token Address of the ERC20 token for the vault
    /// @param creator Address of the vault creator
    /// @param recipient Address receiving the swap
    /// @param expiryBlocks Number of blocks until expiry
    /// @param commitmentHash Hash of the swap commitment
    /// @param amount Minimum required token amount
    /// @return Address where the vault would be deployed
    /// @dev Useful for off-chain calculation of vault address before funding
    /// @dev Reverts if vault already exists at predicted address
    function getTokenVaultAddress(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) external view safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());

        (bytes memory encodedArgs, bytes32 salt) =
            _getVaultArgsAndSalt(token, creator, recipient, expiryBlocks, commitmentHash);
        address predictedAddr =
            i_tokenVaultImplementation.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedVaults[predictedAddr], SwapRegistry__VaultAlreadyDeployed());

        return predictedAddr;
    }

    //////////////////////////////////
    //////////////////////////////////
    //////// Internal Functions ///////
    //////////////////////////////////
    //////////////////////////////////

    /// @notice Executes EIP-2612 permit, reverting with PermitFailed on any failure
    function _executePermit(address token, address creator, uint256 amount, uint256 deadline, bytes calldata signature)
        internal
    {
        (uint8 v, bytes32 r, bytes32 s) = ECDSA.parseCalldata(signature);
        try IERC20Permit(token).permit(creator, address(this), amount, deadline, v, r, s) {}
        catch {
            revert SwapRegistry__PermitFailed();
        }
    }

    /// @notice Deploys vault clone, initializes it, and marks as deployed
    /// @param encodedArgs ABI-encoded vault params (token, creator, recipient, expiryBlocks, commitmentHash)
    /// @param salt Deterministic deployment salt
    function _deployVault(bytes memory encodedArgs, bytes32 salt) internal {
        address vault = i_tokenVaultImplementation.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
        vault.functionCall(abi.encodeCall(TokenDepositVault.initialize, ()));
        (address token, address creator,,,) = abi.decode(encodedArgs, (address, address, address, uint256, bytes32));
        emit VaultCreated(vault, creator, token);
        s_deployedVaults[vault] = true;
    }

    /// @notice Encodes vault params and generates deterministic deployment salt
    /// @param token Token address
    /// @param creator Creator address
    /// @param recipient Recipient address
    /// @param expiryBlocks Block expiry count
    /// @param commitmentHash Swap commitment hash
    /// @return encodedArgs ABI-encoded immutable arguments for cloning
    /// @return salt Keccak256 hash of chain-scoped parameters for deterministic deployment
    function _getVaultArgsAndSalt(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash
    ) internal view returns (bytes memory encodedArgs, bytes32 salt) {
        encodedArgs = abi.encode(token, creator, recipient, expiryBlocks, commitmentHash);
        salt = keccak256(abi.encode(block.chainid, token, creator, recipient, expiryBlocks, commitmentHash));
    }
}

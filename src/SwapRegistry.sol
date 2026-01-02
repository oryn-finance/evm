// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenDepositVault} from "./TokenDepositVault.sol";
import {Clones} from "../lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @author Oryn Finance
/// @title SwapRegistry
/// @notice Factory for creating deterministic token deposit vaults that allow seamless atomic swaps
contract SwapRegistry is Ownable {
    using Clones for address;
    using Address for address;

    // 0xd6e2de8f
    error SwapRegistry__InvalidAddressParameters();
    // 0x2515eed4
    error SwapRegistry__ZeroExpiryBlocks();
    // 0x7510a9d5
    error SwapRegistry__ZeroAmount();
    // 0x2441e34b
    error SwapRegistry__InvalidAddress();
    // 0x65db15b5
    error SwapRegistry__InsufficientFundsDeposited();
    // 0xcd1f0e00
    error SwapRegistry__TokenNotAccepted();
    // 0x769f851d
    error SwapRegistry__VaultAlreadyDeployed();

    /// @notice Emitted when a new token vault is created
    /// @param vaultAddress Address of the newly created vault
    /// @param creator Address of the vault creator
    /// @param token Address of the ERC20 token for the vault
    event TokenVaultCreated(address indexed vaultAddress, address indexed creator, address indexed token);

    /// @notice Emitted when a new native ETH vault is created
    /// @param vaultAddress Address of the newly created vault
    /// @param creator Address of the vault creator
    event NativeVaultCreated(address indexed vaultAddress, address indexed creator);

    /// @notice Emitted when a token is whitelisted or blacklisted
    /// @param tokenAddress Address of the token
    event WhitelistedToken(address indexed tokenAddress);

    /// @notice Sentinel address representing native ETH in swap operations
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Reference implementation of TokenDepositVault for cloning
    address public immutable i_tokenVaultImplementation;

    /// @notice Mapping of token addresses to their whitelist status
    /// @dev true = whitelisted, false = not whitelisted
    mapping(address => bool) public s_whitelistedTokens;

    /// @notice Mapping tracking all deployed vault addresses to prevent duplicates
    /// @dev Ensures deterministic addresses are only used once
    mapping(address => bool) public s_deployedVaults;

    constructor(address _owner) Ownable(_owner) {
        i_tokenVaultImplementation = address(new TokenDepositVault());
    }

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

        bytes memory encodedArgs = _getAbiEncodedTokenVaultArgs(token, creator, recipient, expiryBlocks, commitmentHash);

        bytes32 salt = _getSaltForTokenVault(token, creator, recipient, expiryBlocks, commitmentHash);

        address _tokenVaultImpl = i_tokenVaultImplementation;

        address addr = _tokenVaultImpl.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedVaults[addr], SwapRegistry__VaultAlreadyDeployed());

        // Verify the predicted address has been funded with the required tokens by the creator
        if (token == NATIVE_TOKEN) {
            require(address(addr).balance >= amount, SwapRegistry__InsufficientFundsDeposited());
        } else {
            require(IERC20(token).balanceOf(addr) >= amount, SwapRegistry__InsufficientFundsDeposited());
        }

        address vault = _tokenVaultImpl.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
        emit TokenVaultCreated(address(vault), address(creator), token);

        vault.functionCall(abi.encodeCall(TokenDepositVault.initialize, ()));

        // Mark vault as deployed to prevent re-creation
        s_deployedVaults[addr] = true;

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

        address predictedAddr = i_tokenVaultImplementation.predictDeterministicAddressWithImmutableArgs(
            _getAbiEncodedTokenVaultArgs(token, creator, recipient, expiryBlocks, commitmentHash),
            _getSaltForTokenVault(token, creator, recipient, expiryBlocks, commitmentHash)
        );

        require(!s_deployedVaults[predictedAddr], SwapRegistry__VaultAlreadyDeployed());

        return predictedAddr;
    }

    /// @notice Encodes vault initialization parameters for cloning
    /// @param token Token address
    /// @param creator Creator address
    /// @param recipient Recipient address
    /// @param expiryBlocks Block expiry count
    /// @param commitmentHash Swap commitment hash
    /// @return Encoded bytes for immutable arguments
    /// @dev Used internally to prepare data for deterministic cloning
    function _getAbiEncodedTokenVaultArgs(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash
    ) internal pure returns (bytes memory) {
        return abi.encode(token, creator, recipient, expiryBlocks, commitmentHash);
    }

    /// @notice Generates deterministic salt for vault deployment
    /// @param token Token address
    /// @param creator Creator address
    /// @param recipient Recipient address
    /// @param expiryBlocks Block expiry count
    /// @param commitmentHash Swap commitment hash
    /// @return Keccak256 hash of encoded parameters serving as the deployment salt
    /// @dev Ensures same parameters always produce the same vault address
    function _getSaltForTokenVault(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid,token, creator, recipient, expiryBlocks, commitmentHash));
    }
}

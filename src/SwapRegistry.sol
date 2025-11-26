// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenDepositVault} from "./TokenDepositVault.sol";
import {Clones} from "../lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract SwapRegistry is Ownable {
    using Clones for address;
    using Address for address;

    error SwapRegistry__InvalidAddressParameters();
    error SwapRegistry__ZeroExpiryBlocks();
    error SwapRegistry__ZeroAmount();
    error SwapRegistry__InvalidAddress();
    error SwapRegistry__InsufficientFundsDeposited();
    error SwapRegistry__TokenNotAccepted();
    error SwapRegistry__VaultAlreadyDeployed();

    event TokenVaultCreated(address indexed vaultAddress, address indexed creator, address indexed token);
    event NativeVaultCreated(address indexed vaultAddress, address indexed creator);
    event WhitelistedToken(address indexed tokenAddress);

    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public immutable i_tokenVaultImplementation;
    mapping(address => bool) public s_whitelistedTokens;
    mapping(address => bool) public s_deployedVaults;

    constructor() Ownable(msg.sender) {
        i_tokenVaultImplementation = address(new TokenDepositVault());
    }

    modifier safeParams(address creator, address recipient, uint256 expiryBlocks, uint256 amount) {
        require(
            recipient != address(0) && creator != address(0) && creator != recipient,
            SwapRegistry__InvalidAddressParameters()
        );
        require(expiryBlocks > 0, SwapRegistry__ZeroExpiryBlocks());
        require(amount > 0, SwapRegistry__ZeroAmount());
        _;
    }

    /// @notice Whitelists an ERC20 token to allow usage in swaps
    /// @param _tokenAddress The ERC20 token contract address to whitelist
    function whitelistToken(address _tokenAddress) external onlyOwner {
        s_whitelistedTokens[_tokenAddress] = true;
        emit WhitelistedToken(_tokenAddress);
    }

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

        // getting the TokenSwapVault address
        address addr = _tokenVaultImpl.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        require(!s_deployedVaults[addr], SwapRegistry__VaultAlreadyDeployed());

        // Check if predicted address has been funded by user
        if (token == NATIVE_TOKEN) {
            require(address(addr).balance >= amount, SwapRegistry__InsufficientFundsDeposited());
        } else {
            require(IERC20(token).balanceOf(addr) >= amount, SwapRegistry__InsufficientFundsDeposited());
        }

        address vault = _tokenVaultImpl.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
        emit TokenVaultCreated(address(vault), address(creator), token);
        vault.functionCall(abi.encodeCall(TokenDepositVault.initialize, ()));

        s_deployedVaults[addr] = true;

        return addr;
    }

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

    function _getAbiEncodedTokenVaultArgs(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash
    ) internal pure returns (bytes memory) {
        return abi.encode(token, creator, recipient, expiryBlocks, commitmentHash);
    }

    function _getSaltForTokenVault(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, creator, recipient, expiryBlocks, commitmentHash));
    }
}

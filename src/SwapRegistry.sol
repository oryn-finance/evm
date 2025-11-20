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
    error SwapRegistry__CommitmentHashAlreadyUsed();

    event TokenVaultCreated(address indexed vaultAddress, address indexed creator, address indexed token);
    event NativeVaultCreated(address indexed vaultAddress, address indexed creator);
    event WhitelistedToken(address indexed tokenAddress);

    string public constant NAME = "SwapRegistry";
    string public constant VERSION = "1.0.0";
    address public immutable i_tokenVaultImplementation;
    mapping(address => bool) public s_whitelistedTokens;
    mapping(bytes32 => bool) public s_usedCommitmentHashes;

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
        uint256 srcChainId,
        uint256 amount
    ) external safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(!s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());
        require(!s_usedCommitmentHashes[commitmentHash], SwapRegistry__CommitmentHashAlreadyUsed());

        bytes memory encodedArgs = _getAbiEncodedTokenVaultArgs(token, creator, recipient, expiryBlocks, commitmentHash, srcChainId);

        bytes32 salt = _getSaltForTokenVault(token, creator, recipient, expiryBlocks, commitmentHash, srcChainId);

        address _tokenVaultImpl = i_tokenVaultImplementation;

        // getting the TokenSwapVault address
        address addr = _tokenVaultImpl.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);

        if (token == address(0)) {
            require(address(addr).balance >= amount, SwapRegistry__InsufficientFundsDeposited());
        } else {
            require(IERC20(token).balanceOf(addr) >= amount, SwapRegistry__InsufficientFundsDeposited());
        }

        if (addr.code.length == 0) {
            address vault = _tokenVaultImpl.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
            emit TokenVaultCreated(address(vault), address(creator), token);
            vault.functionCall(abi.encodeCall(TokenDepositVault.initialize, ()));
        }
        s_usedCommitmentHashes[commitmentHash] = true;

        return addr;
    }

    function getTokenVaultAddress(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 srcChainId,
        uint256 amount
    ) external view safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
        require(!s_whitelistedTokens[token], SwapRegistry__TokenNotAccepted());
        require(!s_usedCommitmentHashes[commitmentHash], SwapRegistry__CommitmentHashAlreadyUsed());

        return i_tokenVaultImplementation.predictDeterministicAddressWithImmutableArgs(
            _getAbiEncodedTokenVaultArgs(token, creator, recipient, expiryBlocks, commitmentHash, srcChainId),
            _getSaltForTokenVault(token, creator, recipient, expiryBlocks, commitmentHash, srcChainId)
        );
    }

    function _getAbiEncodedTokenVaultArgs(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 srcChainId
    ) internal pure returns (bytes memory) {
        return abi.encode(token, creator, recipient, expiryBlocks, commitmentHash, srcChainId);
    }

    function _getSaltForTokenVault(
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 srcChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, creator, recipient, expiryBlocks, commitmentHash, srcChainId));
    }

    // function createNativeSwapVault(
    //     address creator,
    //     address recipient,
    //     uint256 expiryBlocks,
    //     uint256 amount,
    //     bytes32 commitmentHash
    // ) external returns (address) {
    //     require(nativeEscrowContract != address(0), SwapRegistry__NoNativeEscrowFound());
    //     bytes memory encodedArgs =
    //         abi.encode(nativeEscrowContract, creator, recipient, expiryBlocks, commitmentHash, amount);
    //     bytes32 salt = keccak256(abi.encodePacked(creator, recipient, expiryBlocks, commitmentHash, amount));
    //     address _nativeVaultImpl = nativeVaultImplementation;

    //     // getting Native swap vault address
    //     address addr = _nativeVaultImpl.predictDeterministicAddressWithImmutableArgs(encodedArgs, salt);
    //     require(address(addr).balance >= amount, SwapRegistry__InsufficientFundsDeposited());

    //     if (addr.code.length == 0) {
    //         address nativeVault = _nativeVaultImpl.cloneDeterministicWithImmutableArgs(encodedArgs, salt);
    //         emit NativeVaultCreated(address(nativeVault), address(creator));
    //         nativeVault.functionCall(abi.encodeCall(NativeDepositVault.initialize, ()));
    //     }
    //     return addr;
    // }

    // function getNativeVaultAddress(
    //     address creator,
    //     address recipient,
    //     uint256 expiryBlocks,
    //     uint256 amount,
    //     bytes32 commitmentHash
    // ) external view safeParams(creator, recipient, expiryBlocks, amount) returns (address) {
    //     require(nativeEscrowContract != address(0), SwapRegistry__NoNativeEscrowFound());
    //     return nativeVaultImplementation.predictDeterministicAddressWithImmutableArgs(
    //         abi.encode(nativeEscrowContract, creator, recipient, expiryBlocks, commitmentHash, amount),
    //         keccak256(abi.encodePacked(creator, recipient, expiryBlocks, commitmentHash, amount))
    //     );
    // }
}

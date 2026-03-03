// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapRegistry} from "../src/SwapRegistry.sol";
import {TokenDepositVault} from "../src/TokenDepositVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ERC20Impl is ERC20 {
    constructor(string memory name, string memory symbol, address mintTo) ERC20(name, symbol) {
        _mint(mintTo, 100_000_000 * 10 ** decimals());
    }
}

contract ERC20PermitImpl is ERC20Permit {
    constructor(string memory name, string memory symbol, address mintTo) ERC20Permit(name) ERC20(name, symbol) {
        _mint(mintTo, 100_000_000 * 10 ** decimals());
    }
}

/// @notice Contract with no receive/fallback - rejects ETH transfers (for coverage: NativeDepositFailed)
contract NoReceive {
    // no receive, no fallback - .call{value}("") will fail

    }

/// @notice Fee-on-transfer token: 10% fee on every transfer (recipient gets 90%)
contract ERC20FeeOnTransfer is ERC20 {
    constructor(string memory name, string memory symbol, address mintTo) ERC20(name, symbol) {
        _mint(mintTo, 100_000_000 * 10 ** decimals());
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && from != address(0)) {
            uint256 fee = value / 10;
            uint256 net = value - fee;
            super._update(from, to, net);
            super._update(from, address(this), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract RegistryAndVaultTest is Test {
    event VaultCreated(
        address indexed vaultAddress,
        address indexed creator,
        address indexed token,
        address recipient,
        bytes32 commitmentHash,
        uint256 expiryBlocks,
        uint256 amount
    );

    SwapRegistry registry;
    ERC20Impl token1;
    ERC20Impl token2;
    ERC20PermitImpl permitToken;
    ERC20FeeOnTransfer feeToken;

    // addresses (alice uses known pk for permit/signed tests)
    uint256 constant ALICE_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address bob = makeAddr("bob");
    address alice;
    address charlie = makeAddr("charlie");

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        vm.startPrank(bob);
        token1 = new ERC20Impl("TestCoin1", "TC1", bob);
        token2 = new ERC20Impl("TestCoin2", "TC2", bob);
        permitToken = new ERC20PermitImpl("PermitCoin", "PC", alice);
        feeToken = new ERC20FeeOnTransfer("FeeCoin", "FC", bob);

        registry = new SwapRegistry(bob);

        registry.whitelistToken(address(token1));
        registry.whitelistToken(address(token2));
        registry.whitelistToken(address(permitToken));
        registry.whitelistToken(address(feeToken));

        vm.stopPrank();
    }

    // ========== Helper to build EIP-712 domain separator ==========

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _signCreateVault(
        uint256 pk,
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.CREATE_VAULT_TYPEHASH(), token, creator, recipient, expiryBlocks, commitmentHash, amount, nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash));
        return abi.encodePacked(r, s, v);
    }

    function _signPermit(uint256 pk, address owner, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(registry),
                amount,
                permitToken.nonces(owner),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toTypedDataHash(permitToken.DOMAIN_SEPARATOR(), structHash));
        return abi.encodePacked(r, s, v);
    }

    // ========== Whitelist & Owner ==========

    function test_WhitelistAndOwner() public view {
        assertTrue(registry.s_whitelistedTokens(address(token1)));
        assertTrue(registry.s_whitelistedTokens(address(token2)));
        assertEq(registry.owner(), bob);
    }

    function test_whitelistToken_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.whitelistToken(address(token1));
    }

    function test_delistToken_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.delistToken(address(token1));
    }

    function test_whitelistToken_EmitsTokenWhitelisted() public {
        vm.prank(bob);
        vm.expectEmit(true, false, false, false);
        emit SwapRegistry.TokenWhitelisted(address(token1));
        registry.whitelistToken(address(token1));
    }

    function test_delistToken_Success() public {
        vm.prank(bob);
        vm.expectEmit(true, false, false, false);
        emit SwapRegistry.TokenDelisted(address(token1));
        registry.delistToken(address(token1));

        assertFalse(registry.s_whitelistedTokens(address(token1)));

        bytes32 h = sha256("x");
        vm.expectRevert(SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);
    }

    // ========== getTokenVaultAddress checks ==========

    function test_getDeployAddressChecks() public {
        bytes32 h = sha256(abi.encode(0x1232));

        vm.expectRevert(SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        registry.getTokenVaultAddress(address(123), bob, alice, 10, h, 120);

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.getTokenVaultAddress(address(token1), bob, bob, 10, h, 120);

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.getTokenVaultAddress(address(token1), address(0), alice, 10, h, 120);

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.getTokenVaultAddress(address(token1), bob, address(0), 10, h, 120);

        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroExpiryBlocks.selector);
        registry.getTokenVaultAddress(address(token1), bob, alice, 0, h, 120);

        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroAmount.selector);
        registry.getTokenVaultAddress(address(token1), bob, alice, 100, h, 0);

        address nativeToken = registry.NATIVE_TOKEN();
        vm.expectRevert(SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        registry.createTokenSwapVault(nativeToken, bob, alice, 100, h, 1000);

        address x = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);
        assertFalse(registry.s_deployedVaults(x));
    }

    function test_getTokenVaultAddress_ReturnsWhenNotDeployed() public view {
        bytes32 h = sha256("x");
        address predicted = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);
        assertTrue(predicted != address(0));
        assertFalse(registry.s_deployedVaults(predicted));
    }

    function test_getTokenVaultAddress_RevertsOnZeroCommitmentHash() public {
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidCommitmentHash.selector);
        registry.getTokenVaultAddress(address(token1), bob, alice, 10, bytes32(0), 120);
    }

    // ========== createTokenSwapVault (pre-fund flow) ==========

    function test_getVaultAddressButFundWrongAsset() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);

        vm.prank(bob);
        assertTrue(token2.transfer(vault, 120));

        vm.expectRevert(SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);

        vm.expectRevert(SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        registry.createTokenSwapVault(address(token2), bob, alice, 10, h, 120);
    }

    function test_depositintoCorrectVault() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);

        assertEq(block.number, 1);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));

        vm.roll(block.number + 10);

        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);

        assertEq(block.number, TokenDepositVault(vault).s_depositedAt());
    }

    function test_createTokenSwapVault_ReturnsCorrectAddress() public {
        bytes32 h = sha256("x");
        address predicted = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(predicted, 120));
        address returned = registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);
        assertEq(returned, predicted);
    }

    function test_createTokenSwapVault_RevertsOnZeroCommitmentHash() public {
        vm.prank(bob);
        assertTrue(token1.transfer(alice, 120));

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidCommitmentHash.selector);
        registry.createTokenSwapVault(address(token1), bob, alice, 10, bytes32(0), 120);
    }

    // ========== Withdraw (ERC20) ==========

    function test_withdrawVault() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);

        uint256 beforebalance = token1.balanceOf(bob);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));

        assertEq(token1.balanceOf(bob), beforebalance - 120);

        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        TokenDepositVault(vault).withdraw(abi.encode(commitment));
        assertEq(token1.balanceOf(alice), 120);
    }

    function test_withdraw_RevertInvalidCommitment() public {
        bytes32 commitment = sha256("secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(alice);
        vm.expectRevert(TokenDepositVault.TokenDepositVault__InvalidCommitment.selector);
        TokenDepositVault(vault).withdraw(abi.encode("wrong-preimage"));
    }

    function test_witdrawShouldFailIfInCorrectCommitment() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);
        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        vm.expectRevert();
        TokenDepositVault(predictedAddr).withdraw(abi.encode(commitment, "1"));
    }

    // ========== Cancel (ERC20) ==========

    function test_CancelBeforetimelockNotAllowed() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);

        uint256 beforebalance = token1.balanceOf(bob);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));

        assertEq(token1.balanceOf(bob), beforebalance - 120);

        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);

        vm.expectRevert(TokenDepositVault.TokenDepositVault__SwapNotExpired.selector);
        TokenDepositVault(vault).cancelSwap();

        vm.roll(12);
        TokenDepositVault(vault).cancelSwap();

        assertEq(token1.balanceOf(bob), beforebalance);
    }

    // ========== Native ETH (pre-fund flow) ==========

    function test_depositNativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);

        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        assertEq(bob.balance, 0);

        TokenDepositVault(predictedAddr).withdraw(abi.encode(commitment));

        assertEq(bob.balance, 1000);
    }

    function test_cancelNativeEscrow() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);

        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        vm.roll(102);

        assertEq(alice.balance, 0);

        TokenDepositVault(predictedAddr).cancelSwap();

        assertEq(alice.balance, 1000);
    }

    function test_shouldntAllowSameAddressVault() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr = registry.getTokenVaultAddress(nativeToken, alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);
        registry.createTokenSwapVault(nativeToken, alice, bob, 100, commitmentHash, 1000);

        vm.expectRevert(SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        registry.createTokenSwapVault(nativeToken, alice, bob, 100, commitmentHash, 1000);

        vm.expectRevert(SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        registry.getTokenVaultAddress(nativeToken, alice, bob, 100, commitmentHash, 1000);
    }

    function test_withdrawAndRefundWillFailIfTheyAreContractWIthOutReceiveOrFallBack() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr = registry.getTokenVaultAddress(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmentHash, 1000
        );

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);

        registry.createTokenSwapVault(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmentHash, 1000
        );

        vm.expectRevert(TokenDepositVault.TokenDepositVault__NativeWithdrawFailed.selector);
        TokenDepositVault(predictedAddr).withdraw(abi.encode(commitment));

        assertEq(predictedAddr.balance, 1000);

        vm.roll(103);
        vm.expectRevert(TokenDepositVault.TokenDepositVault__NativeWithdrawFailed.selector);
        TokenDepositVault(predictedAddr).cancelSwap();
    }

    function test_NativeVaultWontBeCreatedWithOutBalance() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(nativeToken, address(token1), address(token2), 100, commitmentHash, 1000);

        assertEq(predictedAddr.balance, 0);

        vm.expectRevert(SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        registry.createTokenSwapVault(nativeToken, address(token1), address(token2), 100, commitmentHash, 1000);
    }

    // ========== createTokenSwapVaultNativeCall ==========

    function test_createTokenSwapVaultNativeCall_Success() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1 ether;

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount);

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );

        assertEq(vault, predictedAddr);
        assertTrue(registry.s_deployedVaults(vault));
        assertEq(vault.balance, amount);
        assertEq(TokenDepositVault(vault).s_depositedAt(), block.number);
    }

    function test_createTokenSwapVaultNativeCall_WithdrawWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 2 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 50, commitmentHash, amount
        );

        uint256 bobBefore = bob.balance;
        TokenDepositVault(vault).withdraw(abi.encode(commitment));
        assertEq(bob.balance, bobBefore + amount);
        assertEq(vault.balance, 0);
    }

    function test_createTokenSwapVaultNativeCall_CancelAfterExpiryWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitmentHash = sha256(abi.encodePacked("any"));
        uint256 amount = 1 ether;
        uint256 expiryBlocks = 10;

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, charlie, expiryBlocks, commitmentHash, amount
        );

        vm.roll(block.number + expiryBlocks + 1);
        uint256 aliceBefore = alice.balance;
        TokenDepositVault(vault).cancelSwap();
        assertEq(alice.balance, aliceBefore + amount);
        assertEq(vault.balance, 0);
    }

    function test_createTokenSwapVaultNativeCall_ReturnsCorrectAddress() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();
        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        address predicted =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount);
        vm.deal(alice, amount);
        vm.prank(alice);
        address returned = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );
        assertEq(returned, predicted);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenTokenNotNative() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__OnlyNativeTokenAllowed.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(address(token1), alice, bob, 100, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenMsgValueMismatch() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__MsgValueAmountMismatch.selector);
        registry.createTokenSwapVaultNativeCall{value: 500}(nativeToken, alice, bob, 100, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenNativeNotWhitelisted() public {
        address nativeToken = registry.NATIVE_TOKEN();
        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, bob, 100, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenVaultAlreadyDeployed() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount * 2);

        vm.prank(alice);
        registry.createTokenSwapVaultNativeCall{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        registry.createTokenSwapVaultNativeCall{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenNativeDepositFailed() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount);

        address predicted = registry.getTokenVaultAddress(nativeToken, alice, bob, 100, commitmentHash, amount);
        NoReceive noReceive = new NoReceive();
        vm.etch(predicted, address(noReceive).code);

        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__NativeDepositFailed.selector);
        registry.createTokenSwapVaultNativeCall{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenCreatorZero() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, address(0), bob, 100, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenRecipientZero() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, address(0), 100, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenCreatorEqualsRecipient() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, alice, 100, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenZeroExpiryBlocks() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroExpiryBlocks.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, bob, 0, h, 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenZeroAmount() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroAmount.selector);
        registry.createTokenSwapVaultNativeCall{value: 0}(nativeToken, alice, bob, 100, h, 0);
    }

    function test_createTokenSwapVaultNativeCall_RevertsOnZeroCommitmentHash() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        hoax(alice, 1 ether);
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidCommitmentHash.selector);
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, bob, 100, bytes32(0), 1 ether);
    }

    function test_createTokenSwapVaultNativeCall_EmitsTokenVaultCreated() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount);

        address predicted = registry.getTokenVaultAddress(nativeToken, alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit VaultCreated(predicted, alice, nativeToken, bob, commitmentHash, 100, amount);
        registry.createTokenSwapVaultNativeCall{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }

    // ========== createTokenSwapVaultPermit ==========

    function test_createTokenSwapVaultPermit_Success() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("permit-secret"));
        uint256 amount = 500;
        uint256 deadline = block.timestamp + 3600;

        bytes memory signature = _signPermit(ALICE_PK, alice, amount, deadline);

        address predicted = registry.getTokenVaultAddress(address(permitToken), alice, bob, 100, commitmentHash, amount);

        address vault = registry.createTokenSwapVaultPermit(
            address(permitToken), alice, bob, 100, commitmentHash, amount, deadline, signature
        );

        assertEq(vault, predicted);
        assertTrue(registry.s_deployedVaults(vault));
        assertEq(permitToken.balanceOf(vault), amount);
        assertEq(permitToken.balanceOf(alice), 100_000_000 * 10 ** 18 - amount);
    }

    function test_createTokenSwapVaultPermit_RevertWhenNativeToken() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert(SwapRegistry.SwapRegistry__OnlyERC20Allowed.selector);
        registry.createTokenSwapVaultPermit(nativeToken, alice, bob, 100, h, 100, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertWhenPermitExpired() public {
        bytes32 h = sha256("x");
        uint256 amount = 100;
        uint256 deadline = block.timestamp - 1;

        bytes memory signature = _signPermit(ALICE_PK, alice, amount, deadline);

        vm.expectRevert(SwapRegistry.SwapRegistry__PermitFailed.selector);
        registry.createTokenSwapVaultPermit(address(permitToken), alice, bob, 100, h, amount, deadline, signature);
    }

    function test_createTokenSwapVaultPermit_RevertWhenPermitFailsNonPermitToken() public {
        bytes32 h = sha256("x");
        uint256 amount = 100;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(bob);
        assertTrue(token1.transfer(alice, 200));
        vm.prank(alice);
        assertTrue(token1.approve(address(registry), 100));

        vm.expectRevert(SwapRegistry.SwapRegistry__PermitFailed.selector);
        registry.createTokenSwapVaultPermit(address(token1), alice, bob, 100, h, amount, deadline, sig);
    }

    function test_createTokenSwapVaultPermit_RevertWhenTokenNotWhitelisted() public {
        vm.prank(bob);
        ERC20Impl unlistedToken = new ERC20Impl("Unlisted", "UL", alice);
        vm.prank(alice);
        assertTrue(unlistedToken.approve(address(registry), 100));

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert(SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        registry.createTokenSwapVaultPermit(address(unlistedToken), alice, bob, 100, h, 100, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertsWithFeeOnTransferToken() public {
        vm.prank(bob);
        assertTrue(feeToken.transfer(alice, 1000));

        bytes32 h = sha256(abi.encodePacked("permit-fee"));
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert(SwapRegistry.SwapRegistry__PermitFailed.selector);
        registry.createTokenSwapVaultPermit(address(feeToken), alice, bob, 100, h, 500, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertsOnZeroCreator() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultPermit(address(permitToken), address(0), bob, 100, h, 100, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertsOnZeroRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultPermit(address(permitToken), alice, address(0), 100, h, 100, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertsOnCreatorEqualsRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultPermit(address(permitToken), alice, alice, 100, h, 100, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertsOnZeroExpiryBlocks() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroExpiryBlocks.selector);
        registry.createTokenSwapVaultPermit(address(permitToken), alice, bob, 0, h, 100, dl, sig);
    }

    function test_createTokenSwapVaultPermit_RevertsOnZeroAmount() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroAmount.selector);
        registry.createTokenSwapVaultPermit(address(permitToken), alice, bob, 100, h, 0, dl, sig);
    }

    // ========== createTokenSwapVaultSigned ==========

    function test_createTokenSwapVaultSigned_Success() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("signed-secret"));
        uint256 amount = 300;

        bytes memory signature =
            _signCreateVault(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount, 0);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        address predicted = registry.getTokenVaultAddress(address(permitToken), alice, bob, 100, commitmentHash, amount);

        address vault = registry.createTokenSwapVaultSigned(
            address(permitToken), alice, bob, 100, commitmentHash, amount, signature
        );

        assertEq(vault, predicted);
        assertTrue(registry.s_deployedVaults(vault));
        assertEq(permitToken.balanceOf(vault), amount);
        assertEq(registry.s_nonces(alice), 1);
    }

    function test_createTokenSwapVaultSigned_RevertWhenInvalidSignature() public {
        bytes32 commitmentHash = sha256("x");
        uint256 amount = 100;

        uint256 bobPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        // Bob signs for himself as creator, but call passes alice as creator
        bytes memory signature = _signCreateVault(bobPk, address(permitToken), bob, bob, 100, commitmentHash, amount, 0);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidSignature.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);
    }

    function test_createTokenSwapVaultSigned_RevertWhenNativeToken() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.expectRevert(SwapRegistry.SwapRegistry__OnlyERC20Allowed.selector);
        registry.createTokenSwapVaultSigned(nativeToken, alice, bob, 100, h, 100, sig);
    }

    function test_createTokenSwapVaultSigned_RevertWhenVaultAlreadyDeployed() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("signed-secret"));
        uint256 amount = 300;

        bytes memory signature =
            _signCreateVault(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount, 0);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);

        // Sign with nonce 1 for second attempt (same params -> VaultAlreadyDeployed)
        bytes memory signature2 =
            _signCreateVault(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount, 1);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        vm.expectRevert(SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature2);
    }

    function test_createTokenSwapVaultSigned_RevertWhenTokenNotWhitelisted() public {
        vm.prank(bob);
        ERC20Impl unlistedToken = new ERC20Impl("Unlisted", "UL", alice);
        vm.prank(alice);
        assertTrue(unlistedToken.approve(address(registry), 100));

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 100;

        bytes memory signature = _signCreateVault(
            ALICE_PK, address(unlistedToken), alice, bob, 100, commitmentHash, amount, registry.s_nonces(alice)
        );

        vm.expectRevert(SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        registry.createTokenSwapVaultSigned(address(unlistedToken), alice, bob, 100, commitmentHash, amount, signature);
    }

    function test_createTokenSwapVaultSigned_RevertWhenInsufficientFundsAfterTransfer() public {
        vm.prank(bob);
        assertTrue(feeToken.transfer(alice, 200));
        vm.prank(alice);
        assertTrue(feeToken.approve(address(registry), 100));

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 100;

        bytes memory signature = _signCreateVault(
            ALICE_PK, address(feeToken), alice, bob, 100, commitmentHash, amount, registry.s_nonces(alice)
        );

        vm.expectRevert(SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        registry.createTokenSwapVaultSigned(address(feeToken), alice, bob, 100, commitmentHash, amount, signature);
    }

    function test_createTokenSwapVaultSigned_RevertsOnZeroCreator() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), address(0), bob, 100, h, 100, sig);
    }

    function test_createTokenSwapVaultSigned_RevertsOnZeroRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, address(0), 100, h, 100, sig);
    }

    function test_createTokenSwapVaultSigned_RevertsOnCreatorEqualsRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, alice, 100, h, 100, sig);
    }

    function test_createTokenSwapVaultSigned_RevertsOnZeroExpiryBlocks() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroExpiryBlocks.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 0, h, 100, sig);
    }

    function test_createTokenSwapVaultSigned_RevertsOnZeroAmount() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(SwapRegistry.SwapRegistry__ZeroAmount.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, h, 0, sig);
    }

    // ========== Constants ==========

    function test_Constants() public view {
        assertEq(
            registry.CREATE_VAULT_TYPEHASH(),
            keccak256(
                "CreateVaultParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount,uint256 nonce)"
            )
        );
        assertEq(registry.NATIVE_TOKEN(), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    // ========== s_settled — double withdraw / cancel / cross-call ==========

    function test_withdraw_RevertsOnDoubleWithdraw_ERC20() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        TokenDepositVault(vault).withdraw(abi.encode(commitment));
        assertEq(token1.balanceOf(alice), 120);
        assertTrue(TokenDepositVault(vault).s_settled());

        vm.expectRevert(TokenDepositVault.TokenDepositVault__VaultAlreadySettled.selector);
        TokenDepositVault(vault).withdraw(abi.encode(commitment));
    }

    function test_cancel_RevertsOnDoubleCancel_ERC20() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.roll(12);
        TokenDepositVault(vault).cancelSwap();
        assertTrue(TokenDepositVault(vault).s_settled());

        vm.expectRevert(TokenDepositVault.TokenDepositVault__VaultAlreadySettled.selector);
        TokenDepositVault(vault).cancelSwap();
    }

    function test_cancel_RevertsAfterWithdraw() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        TokenDepositVault(vault).withdraw(abi.encode(commitment));

        vm.roll(12);
        vm.expectRevert(TokenDepositVault.TokenDepositVault__VaultAlreadySettled.selector);
        TokenDepositVault(vault).cancelSwap();
    }

    function test_withdraw_RevertsAfterCancel() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.roll(12);
        TokenDepositVault(vault).cancelSwap();

        vm.expectRevert(TokenDepositVault.TokenDepositVault__VaultAlreadySettled.selector);
        TokenDepositVault(vault).withdraw(abi.encode(commitment));
    }

    function test_withdraw_RevertsOnDoubleWithdraw_NativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );

        TokenDepositVault(vault).withdraw(abi.encode(commitment));
        assertTrue(TokenDepositVault(vault).s_settled());

        vm.expectRevert(TokenDepositVault.TokenDepositVault__VaultAlreadySettled.selector);
        TokenDepositVault(vault).withdraw(abi.encode(commitment));
    }

    function test_cancel_RevertsOnDoubleCancel_NativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitmentHash = sha256(abi.encodePacked("any"));
        uint256 amount = 1 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, charlie, 10, commitmentHash, amount
        );

        vm.roll(block.number + 11);
        TokenDepositVault(vault).cancelSwap();
        assertTrue(TokenDepositVault(vault).s_settled());

        vm.expectRevert(TokenDepositVault.TokenDepositVault__VaultAlreadySettled.selector);
        TokenDepositVault(vault).cancelSwap();
    }

    // ========== Third-party caller — funds go to recipient ==========

    function test_withdraw_ThirdPartyCallerFundsGoToRecipient_ERC20() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(charlie);
        TokenDepositVault(vault).withdraw(abi.encode(commitment));

        assertEq(token1.balanceOf(alice), 120);
        assertEq(token1.balanceOf(charlie), 0);
    }

    function test_withdraw_ThirdPartyCallerFundsGoToRecipient_NativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );

        uint256 bobBefore = bob.balance;
        vm.prank(charlie);
        TokenDepositVault(vault).withdraw(abi.encode(commitment));

        assertEq(bob.balance, bobBefore + amount);
    }

    // ========== Event emission assertions ==========

    function test_withdraw_EmitsWithdrawEvent() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.expectEmit(true, false, false, true, vault);
        emit TokenDepositVault.Withdraw(alice, abi.encode(commitment));
        TokenDepositVault(vault).withdraw(abi.encode(commitment));
    }

    function test_cancelSwap_EmitsCancelEvent() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.roll(12);

        vm.expectEmit(true, false, false, true, vault);
        emit TokenDepositVault.Cancel(bob, commitmentHash);
        TokenDepositVault(vault).cancelSwap();
    }

    // ========== Signature replay with old nonce ==========

    function test_createTokenSwapVaultSigned_RevertOnReplayWithOldNonce() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("replay-test"));
        uint256 amount = 200;

        bytes memory signature =
            _signCreateVault(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount, 0);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);
        assertEq(registry.s_nonces(alice), 1);

        // Replay with same signature (nonce 0) on different params — should fail
        bytes32 commitmentHash2 = sha256(abi.encodePacked("replay-test-2"));

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidSignature.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, commitmentHash2, amount, signature);
    }

    // ========== getSwapParameters public getter ==========

    function test_getSwapParameters_ReturnsCorrectValues() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 expiryBlocks = 50;

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, expiryBlocks, commitmentHash, 120);

        (address token, address creator, address recipient, uint256 expiry, bytes32 storedHash) =
            TokenDepositVault(vault).getSwapParameters();

        assertEq(token, address(token1));
        assertEq(creator, bob);
        assertEq(recipient, alice);
        assertEq(expiry, expiryBlocks);
        assertEq(storedHash, commitmentHash);
    }

    // ========== Fuzz tests ==========

    function testFuzz_createAndWithdraw_ERC20(uint256 amount, uint256 expiryBlocks) public {
        amount = bound(amount, 1, 1_000_000 * 10 ** 18);
        expiryBlocks = bound(expiryBlocks, 1, 1_000_000);

        bytes32 commitment = sha256("fuzz-secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, amount));

        registry.createTokenSwapVault(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        assertTrue(registry.s_deployedVaults(vault));
        assertEq(token1.balanceOf(vault), amount);

        TokenDepositVault(vault).withdraw(abi.encode(commitment));

        assertEq(token1.balanceOf(alice), amount);
        assertEq(token1.balanceOf(vault), 0);
        assertTrue(TokenDepositVault(vault).s_settled());
    }

    function testFuzz_createAndCancel_ERC20(uint256 amount, uint256 expiryBlocks) public {
        amount = bound(amount, 1, 1_000_000 * 10 ** 18);
        expiryBlocks = bound(expiryBlocks, 1, 1_000_000);

        bytes32 commitmentHash = sha256(abi.encodePacked("fuzz-cancel"));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        uint256 bobBefore = token1.balanceOf(bob);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, amount));

        registry.createTokenSwapVault(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        uint256 depositedAt = TokenDepositVault(vault).s_depositedAt();
        vm.roll(depositedAt + expiryBlocks + 1);

        TokenDepositVault(vault).cancelSwap();

        assertEq(token1.balanceOf(bob), bobBefore);
        assertTrue(TokenDepositVault(vault).s_settled());
    }

    function testFuzz_createAndWithdraw_NativeETH(uint256 amount, uint256 expiryBlocks) public {
        amount = bound(amount, 1, 100 ether);
        expiryBlocks = bound(expiryBlocks, 1, 1_000_000);

        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("fuzz-native");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        vm.deal(alice, amount);
        vm.prank(alice);
        address vault = registry.createTokenSwapVaultNativeCall{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, expiryBlocks, commitmentHash, amount
        );

        assertEq(vault.balance, amount);

        uint256 bobBefore = bob.balance;
        TokenDepositVault(vault).withdraw(abi.encode(commitment));

        assertEq(bob.balance, bobBefore + amount);
        assertEq(vault.balance, 0);
        assertTrue(TokenDepositVault(vault).s_settled());
    }

    function testFuzz_cancelBeforeExpiry_Reverts(uint256 expiryBlocks) public {
        expiryBlocks = bound(expiryBlocks, 2, 1_000_000);

        bytes32 commitmentHash = sha256(abi.encodePacked("fuzz-expiry"));
        uint256 amount = 100;

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, amount));
        registry.createTokenSwapVault(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        uint256 depositedAt = TokenDepositVault(vault).s_depositedAt();

        // Roll to exactly expiry boundary — should still revert (need >)
        vm.roll(depositedAt + expiryBlocks);
        vm.expectRevert(TokenDepositVault.TokenDepositVault__SwapNotExpired.selector);
        TokenDepositVault(vault).cancelSwap();

        // Roll past expiry — should succeed
        vm.roll(depositedAt + expiryBlocks + 1);
        TokenDepositVault(vault).cancelSwap();
    }

    function testFuzz_invalidCommitment_Reverts(bytes memory wrongPreimage) public {
        bytes32 commitment = sha256("correct-secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        // Skip if the wrong preimage accidentally matches
        vm.assume(sha256(wrongPreimage) != commitmentHash);

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.expectRevert(TokenDepositVault.TokenDepositVault__InvalidCommitment.selector);
        TokenDepositVault(vault).withdraw(wrongPreimage);
    }

    // ========== Pausable ==========

    function test_pause_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.pause();
    }

    function test_unpause_RevertsWhenNotOwner() public {
        vm.prank(bob);
        registry.pause();

        vm.prank(alice);
        vm.expectRevert();
        registry.unpause();
    }

    function test_pause_BlocksCreateTokenSwapVault() public {
        vm.prank(bob);
        registry.pause();

        bytes32 h = sha256("x");
        vm.expectRevert();
        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);
    }

    function test_pause_BlocksCreateTokenSwapVaultNativeCall() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        registry.pause();
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, bob, 100, h, 1 ether);
    }

    function test_pause_BlocksCreateTokenSwapVaultPermit() public {
        vm.prank(bob);
        registry.pause();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert();
        registry.createTokenSwapVaultPermit(address(permitToken), alice, bob, 100, h, 100, dl, sig);
    }

    function test_pause_BlocksCreateTokenSwapVaultSigned() public {
        vm.prank(bob);
        registry.pause();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.expectRevert();
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, h, 100, sig);
    }

    function test_unpause_AllowsVaultCreation() public {
        vm.startPrank(bob);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        bytes32 h = sha256("x");
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);
        assertTrue(registry.s_deployedVaults(vault));
    }

    function test_pause_DoesNotBlockWithdraw() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(bob);
        registry.pause();

        TokenDepositVault(vault).withdraw(abi.encode(commitment));
        assertEq(token1.balanceOf(alice), 120);
    }

    function test_pause_DoesNotBlockCancel() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, 120);

        vm.prank(bob);
        assertTrue(token1.transfer(vault, 120));
        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, 120);

        vm.prank(bob);
        registry.pause();

        vm.roll(12);
        TokenDepositVault(vault).cancelSwap();
        assertEq(token1.balanceOf(bob), 100_000_000 * 10 ** 18);
    }

    // ========== incrementNonce ==========

    function test_incrementNonce_BumpsNonce() public {
        assertEq(registry.s_nonces(alice), 0);

        vm.prank(alice);
        registry.incrementNonce();
        assertEq(registry.s_nonces(alice), 1);

        vm.prank(alice);
        registry.incrementNonce();
        assertEq(registry.s_nonces(alice), 2);
    }

    function test_incrementNonce_InvalidatesPendingSignature() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("nonce-cancel"));
        uint256 amount = 300;

        // Sign with nonce 0
        bytes memory signature =
            _signCreateVault(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount, 0);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        // Creator bumps nonce to invalidate the signature
        vm.prank(alice);
        registry.incrementNonce();
        assertEq(registry.s_nonces(alice), 1);

        // Now the signature (signed with nonce 0) should fail since contract expects nonce 1
        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidSignature.selector);
        registry.createTokenSwapVaultSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);
    }

    // ========== Batch vault creation ==========

    function test_createTokenSwapVaultBatch_Success() public {
        bytes32 h1 = sha256("batch-1");
        bytes32 h2 = sha256("batch-2");
        uint256 amount = 500;

        // Predict addresses
        address v1 = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h1, amount);
        address v2 = registry.getTokenVaultAddress(address(token1), bob, charlie, 20, h2, amount);

        // Pre-fund both vaults
        vm.startPrank(bob);
        assertTrue(token1.transfer(v1, amount));
        assertTrue(token1.transfer(v2, amount));
        vm.stopPrank();

        // Build batch params
        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](2);
        params[0] = SwapRegistry.VaultParams(address(token1), bob, alice, 10, h1, amount);
        params[1] = SwapRegistry.VaultParams(address(token1), bob, charlie, 20, h2, amount);

        address[] memory vaults = registry.createTokenSwapVaultBatch(params);

        assertEq(vaults.length, 2);
        assertEq(vaults[0], v1);
        assertEq(vaults[1], v2);
        assertTrue(registry.s_deployedVaults(v1));
        assertTrue(registry.s_deployedVaults(v2));
        assertEq(token1.balanceOf(v1), amount);
        assertEq(token1.balanceOf(v2), amount);
    }

    function test_createTokenSwapVaultBatch_RevertsOnEmptyArray() public {
        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](0);

        vm.expectRevert(SwapRegistry.SwapRegistry__EmptyBatch.selector);
        registry.createTokenSwapVaultBatch(params);
    }

    function test_createTokenSwapVaultBatch_RevertsIfAnyVaultFails() public {
        bytes32 h1 = sha256("batch-ok");
        bytes32 h2 = sha256("batch-fail");
        uint256 amount = 500;

        // Only fund the first vault, not the second
        address v1 = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h1, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(v1, amount));

        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](2);
        params[0] = SwapRegistry.VaultParams(address(token1), bob, alice, 10, h1, amount);
        params[1] = SwapRegistry.VaultParams(address(token1), bob, charlie, 20, h2, amount);

        vm.expectRevert(SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        registry.createTokenSwapVaultBatch(params);

        // First vault should NOT be deployed since entire tx reverted
        assertFalse(registry.s_deployedVaults(v1));
    }

    function test_createTokenSwapVaultBatch_RevertsWhenPaused() public {
        vm.prank(bob);
        registry.pause();

        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](1);
        params[0] = SwapRegistry.VaultParams(address(token1), bob, alice, 10, sha256("x"), 100);

        vm.expectRevert();
        registry.createTokenSwapVaultBatch(params);
    }

    function test_createTokenSwapVaultBatch_WithdrawFromBatchVault() public {
        bytes32 commitment = sha256("batch-secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1000;

        address v1 = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmentHash, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(v1, amount));

        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](1);
        params[0] = SwapRegistry.VaultParams(address(token1), bob, alice, 10, commitmentHash, amount);

        address[] memory vaults = registry.createTokenSwapVaultBatch(params);

        TokenDepositVault(vaults[0]).withdraw(abi.encode(commitment));
        assertEq(token1.balanceOf(alice), amount);
    }

    function test_createTokenSwapVaultBatch_NativeETH() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h1 = sha256("batch-native-1");
        bytes32 h2 = sha256("batch-native-2");
        uint256 amount = 1 ether;

        address v1 = registry.getTokenVaultAddress(nativeToken, alice, bob, 10, h1, amount);
        address v2 = registry.getTokenVaultAddress(nativeToken, alice, charlie, 20, h2, amount);

        // Pre-fund both predicted addresses with ETH
        vm.deal(alice, amount * 2);
        vm.startPrank(alice);
        (bool s1,) = payable(v1).call{value: amount}("");
        assertTrue(s1);
        (bool s2,) = payable(v2).call{value: amount}("");
        assertTrue(s2);
        vm.stopPrank();

        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](2);
        params[0] = SwapRegistry.VaultParams(nativeToken, alice, bob, 10, h1, amount);
        params[1] = SwapRegistry.VaultParams(nativeToken, alice, charlie, 20, h2, amount);

        address[] memory vaults = registry.createTokenSwapVaultBatch(params);

        assertEq(vaults[0], v1);
        assertEq(vaults[1], v2);
        assertEq(v1.balance, amount);
        assertEq(v2.balance, amount);
    }

    function test_createTokenSwapVaultBatch_EmitsEventsForEachVault() public {
        bytes32 h1 = sha256("batch-event-1");
        bytes32 h2 = sha256("batch-event-2");
        uint256 amount = 200;

        address v1 = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h1, amount);
        address v2 = registry.getTokenVaultAddress(address(token1), bob, charlie, 20, h2, amount);

        vm.startPrank(bob);
        assertTrue(token1.transfer(v1, amount));
        assertTrue(token1.transfer(v2, amount));
        vm.stopPrank();

        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](2);
        params[0] = SwapRegistry.VaultParams(address(token1), bob, alice, 10, h1, amount);
        params[1] = SwapRegistry.VaultParams(address(token1), bob, charlie, 20, h2, amount);

        vm.expectEmit(true, true, true, true);
        emit VaultCreated(v1, bob, address(token1), alice, h1, 10, amount);
        vm.expectEmit(true, true, true, true);
        emit VaultCreated(v2, bob, address(token1), charlie, h2, 20, amount);
        registry.createTokenSwapVaultBatch(params);
    }

    function test_createTokenSwapVaultBatch_RevertsOnInvalidParams() public {
        SwapRegistry.VaultParams[] memory params = new SwapRegistry.VaultParams[](1);
        // creator == recipient
        params[0] = SwapRegistry.VaultParams(address(token1), bob, bob, 10, sha256("x"), 100);

        vm.expectRevert(SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        registry.createTokenSwapVaultBatch(params);
    }

    // ========== Richer VaultCreated event ==========

    function test_createTokenSwapVault_EmitsRichVaultCreatedEvent() public {
        bytes32 h = sha256("x");
        uint256 amount = 120;
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, h, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(vault, amount));

        vm.expectEmit(true, true, true, true);
        emit VaultCreated(vault, bob, address(token1), alice, h, 10, amount);
        registry.createTokenSwapVault(address(token1), bob, alice, 10, h, amount);
    }
}

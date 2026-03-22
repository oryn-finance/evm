// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
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
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed creator,
        address indexed token,
        address recipient,
        bytes32 commitmentHash,
        uint256 expiryBlocks,
        uint256 amount
    );

    EscrowFactory registry;
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

        registry = new EscrowFactory(bob);

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

    function _signCreateEscrow(
        uint256 pk,
        address token,
        address creator,
        address recipient,
        uint256 expiryBlocks,
        bytes32 commitmentHash,
        uint256 amount
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.CREATE_ESCROW_TYPEHASH(), token, creator, recipient, expiryBlocks, commitmentHash, amount
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
        emit EscrowFactory.TokenWhitelisted(address(token1));
        registry.whitelistToken(address(token1));
    }

    function test_delistToken_Success() public {
        vm.prank(bob);
        vm.expectEmit(true, false, false, false);
        emit EscrowFactory.TokenDelisted(address(token1));
        registry.delistToken(address(token1));

        assertFalse(registry.s_whitelistedTokens(address(token1)));

        bytes32 h = sha256("x");
        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);
    }

    // ========== getEscrowAddress checks ==========

    function test_getDeployAddressChecks() public {
        bytes32 h = sha256(abi.encode(0x1232));

        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.getEscrowAddress(address(123), bob, alice, 10, h, 120);

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.getEscrowAddress(address(token1), bob, bob, 10, h, 120);

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.getEscrowAddress(address(token1), address(0), alice, 10, h, 120);

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.getEscrowAddress(address(token1), bob, address(0), 10, h, 120);

        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroExpiryBlocks.selector);
        registry.getEscrowAddress(address(token1), bob, alice, 0, h, 120);

        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroAmount.selector);
        registry.getEscrowAddress(address(token1), bob, alice, 100, h, 0);

        address nativeToken = registry.NATIVE_TOKEN();
        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.createEscrow(nativeToken, bob, alice, 100, h, 1000);

        address x = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);
        assertFalse(registry.s_deployedEscrows(x));
    }

    function test_getEscrowAddress_ReturnsWhenNotDeployed() public view {
        bytes32 h = sha256("x");
        address predicted = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);
        assertTrue(predicted != address(0));
        assertFalse(registry.s_deployedEscrows(predicted));
    }

    function test_getEscrowAddress_RevertsOnZeroCommitmentHash() public {
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidCommitmentHash.selector);
        registry.getEscrowAddress(address(token1), bob, alice, 10, bytes32(0), 120);
    }

    // ========== createEscrow (pre-fund flow) ==========

    function test_createEscrow_RevertsWhenFundedWithWrongAsset() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);

        vm.prank(bob);
        assertTrue(token2.transfer(escrow, 120));

        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrow(address(token1), bob, alice, 10, h, 120);

        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrow(address(token2), bob, alice, 10, h, 120);
    }

    function test_depositIntoCorrectEscrow() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);

        assertEq(block.number, 1);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));

        vm.roll(block.number + 10);

        registry.createEscrow(address(token1), bob, alice, 10, h, 120);

        assertEq(block.number, EscrowVault(escrow).s_depositedAt());
    }

    function test_createEscrow_ReturnsCorrectAddress() public {
        bytes32 h = sha256("x");
        address predicted = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(predicted, 120));
        address returned = registry.createEscrow(address(token1), bob, alice, 10, h, 120);
        assertEq(returned, predicted);
    }

    function test_createEscrow_RevertsOnZeroCommitmentHash() public {
        vm.prank(bob);
        assertTrue(token1.transfer(alice, 120));

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidCommitmentHash.selector);
        registry.createEscrow(address(token1), bob, alice, 10, bytes32(0), 120);
    }

    // ========== Claim (ERC20) ==========

    function test_claim_Success() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);

        uint256 beforebalance = token1.balanceOf(bob);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));

        assertEq(token1.balanceOf(bob), beforebalance - 120);

        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        EscrowVault(escrow).claim(commitment);
        assertEq(token1.balanceOf(alice), 120);
    }

    function test_claim_RevertsOnInvalidCommitment() public {
        bytes32 commitment = sha256("secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(alice);
        vm.expectRevert(EscrowVault.EscrowVault__InvalidCommitment.selector);
        EscrowVault(escrow).claim(keccak256("wrong-preimage"));
    }

    function test_claim_RevertsOnIncorrectCommitmentNativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getEscrowAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);
        registry.createEscrow(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        vm.expectRevert();
        EscrowVault(predictedAddr).claim(keccak256(abi.encode(commitment, "1")));
    }

    // ========== Refund (ERC20) ==========

    function test_refund_RevertsBeforeExpiry() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);

        uint256 beforebalance = token1.balanceOf(bob);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));

        assertEq(token1.balanceOf(bob), beforebalance - 120);

        registry.createEscrow(address(token1), bob, alice, 10, h, 120);

        vm.expectRevert(EscrowVault.EscrowVault__EscrowNotExpired.selector);
        EscrowVault(escrow).refund();

        vm.roll(12);
        EscrowVault(escrow).refund();

        assertEq(token1.balanceOf(bob), beforebalance);
    }

    // ========== Native ETH (pre-fund flow) ==========

    function test_createEscrow_NativeETHClaimWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getEscrowAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);

        registry.createEscrow(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        assertEq(bob.balance, 0);

        EscrowVault(predictedAddr).claim(commitment);

        assertEq(bob.balance, 1000);
    }

    function test_createEscrow_NativeETHRefundWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getEscrowAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);

        registry.createEscrow(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, 1000);

        vm.roll(102);

        assertEq(alice.balance, 0);

        EscrowVault(predictedAddr).refund();

        assertEq(alice.balance, 1000);
    }

    function test_createEscrow_RevertsOnDuplicateEscrow() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr = registry.getEscrowAddress(nativeToken, alice, bob, 100, commitmentHash, 1000);

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);
        registry.createEscrow(nativeToken, alice, bob, 100, commitmentHash, 1000);

        vm.expectRevert(EscrowFactory.EscrowFactory__EscrowAlreadyDeployed.selector);
        registry.createEscrow(nativeToken, alice, bob, 100, commitmentHash, 1000);

        vm.expectRevert(EscrowFactory.EscrowFactory__EscrowAlreadyDeployed.selector);
        registry.getEscrowAddress(nativeToken, alice, bob, 100, commitmentHash, 1000);
    }

    function test_nativeETH_RevertsWhenRecipientHasNoReceive() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr = registry.getEscrowAddress(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmentHash, 1000
        );

        hoax(alice, 1000);
        (bool sent,) = payable(predictedAddr).call{value: 1000}("");
        assertTrue(sent);

        assertEq(predictedAddr.balance, 1000);

        registry.createEscrow(registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmentHash, 1000);

        vm.expectRevert(EscrowVault.EscrowVault__NativeTransferFailed.selector);
        EscrowVault(predictedAddr).claim(commitment);

        assertEq(predictedAddr.balance, 1000);

        vm.roll(103);
        vm.expectRevert(EscrowVault.EscrowVault__NativeTransferFailed.selector);
        EscrowVault(predictedAddr).refund();
    }

    function test_createEscrow_RevertsOnUnfundedNativeEscrow() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getEscrowAddress(nativeToken, address(token1), address(token2), 100, commitmentHash, 1000);

        assertEq(predictedAddr.balance, 0);

        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrow(nativeToken, address(token1), address(token2), 100, commitmentHash, 1000);
    }

    // ========== createEscrowNative ==========

    function test_createEscrowNative_Success() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1 ether;

        address predictedAddr =
            registry.getEscrowAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount);

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );

        assertEq(escrow, predictedAddr);
        assertTrue(registry.s_deployedEscrows(escrow));
        assertEq(escrow.balance, amount);
        assertEq(EscrowVault(escrow).s_depositedAt(), block.number);
    }

    function test_createEscrowNative_ClaimWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 2 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow =
            registry.createEscrowNative{value: amount}(registry.NATIVE_TOKEN(), alice, bob, 50, commitmentHash, amount);

        uint256 bobBefore = bob.balance;
        EscrowVault(escrow).claim(commitment);
        assertEq(bob.balance, bobBefore + amount);
        assertEq(escrow.balance, 0);
    }

    function test_createEscrowNative_RefundAfterExpiryWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitmentHash = sha256(abi.encodePacked("any"));
        uint256 amount = 1 ether;
        uint256 expiryBlocks = 10;

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, charlie, expiryBlocks, commitmentHash, amount
        );

        vm.roll(block.number + expiryBlocks + 1);
        uint256 aliceBefore = alice.balance;
        EscrowVault(escrow).refund();
        assertEq(alice.balance, aliceBefore + amount);
        assertEq(escrow.balance, 0);
    }

    function test_createEscrowNative_ReturnsCorrectAddress() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();
        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        address predicted = registry.getEscrowAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount);
        vm.deal(alice, amount);
        vm.prank(alice);
        address returned = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );
        assertEq(returned, predicted);
    }

    function test_createEscrowNative_RevertsWhenTokenNotNative() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__OnlyNativeTokenAllowed.selector);
        registry.createEscrowNative{value: 1 ether}(address(token1), alice, bob, 100, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenMsgValueMismatch() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__MsgValueAmountMismatch.selector);
        registry.createEscrowNative{value: 500}(nativeToken, alice, bob, 100, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenNativeNotWhitelisted() public {
        address nativeToken = registry.NATIVE_TOKEN();
        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.createEscrowNative{value: 1 ether}(nativeToken, alice, bob, 100, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenEscrowAlreadyDeployed() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount * 2);

        vm.prank(alice);
        registry.createEscrowNative{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__EscrowAlreadyDeployed.selector);
        registry.createEscrowNative{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }

    function test_createEscrowNative_RevertsWhenNativeDepositFailed() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount);

        address predicted = registry.getEscrowAddress(nativeToken, alice, bob, 100, commitmentHash, amount);
        NoReceive noReceive = new NoReceive();
        vm.etch(predicted, address(noReceive).code);

        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__NativeDepositFailed.selector);
        registry.createEscrowNative{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }

    function test_createEscrowNative_RevertsWhenCreatorZero() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowNative{value: 1 ether}(nativeToken, address(0), bob, 100, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenRecipientZero() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowNative{value: 1 ether}(nativeToken, alice, address(0), 100, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenCreatorEqualsRecipient() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowNative{value: 1 ether}(nativeToken, alice, alice, 100, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenZeroExpiryBlocks() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroExpiryBlocks.selector);
        registry.createEscrowNative{value: 1 ether}(nativeToken, alice, bob, 0, h, 1 ether);
    }

    function test_createEscrowNative_RevertsWhenZeroAmount() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroAmount.selector);
        registry.createEscrowNative{value: 0}(nativeToken, alice, bob, 100, h, 0);
    }

    function test_createEscrowNative_RevertsOnZeroCommitmentHash() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        hoax(alice, 1 ether);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidCommitmentHash.selector);
        registry.createEscrowNative{value: 1 ether}(nativeToken, alice, bob, 100, bytes32(0), 1 ether);
    }

    function test_createEscrowNative_EmitsEscrowCreated() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount);

        address predicted = registry.getEscrowAddress(nativeToken, alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(predicted, alice, nativeToken, bob, commitmentHash, 100, amount);
        registry.createEscrowNative{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }

    // ========== createEscrowPermit ==========

    function test_createEscrowPermit_Success() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("permit-secret"));
        uint256 amount = 500;
        uint256 deadline = block.timestamp + 3600;

        bytes memory signature = _signPermit(ALICE_PK, alice, amount, deadline);

        address predicted = registry.getEscrowAddress(address(permitToken), alice, bob, 100, commitmentHash, amount);

        address escrow = registry.createEscrowPermit(
            address(permitToken), alice, bob, 100, commitmentHash, amount, deadline, signature
        );

        assertEq(escrow, predicted);
        assertTrue(registry.s_deployedEscrows(escrow));
        assertEq(permitToken.balanceOf(escrow), amount);
        assertEq(permitToken.balanceOf(alice), 100_000_000 * 10 ** 18 - amount);
    }

    function test_createEscrowPermit_RevertsWhenNativeToken() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert(EscrowFactory.EscrowFactory__OnlyERC20Allowed.selector);
        registry.createEscrowPermit(nativeToken, alice, bob, 100, h, 100, dl, sig);
    }

    function test_createEscrowPermit_RevertsWhenPermitExpired() public {
        bytes32 h = sha256("x");
        uint256 amount = 100;
        uint256 deadline = block.timestamp - 1;

        bytes memory signature = _signPermit(ALICE_PK, alice, amount, deadline);

        vm.expectRevert(EscrowFactory.EscrowFactory__PermitFailed.selector);
        registry.createEscrowPermit(address(permitToken), alice, bob, 100, h, amount, deadline, signature);
    }

    function test_createEscrowPermit_RevertsWhenPermitFailsNonPermitToken() public {
        bytes32 h = sha256("x");
        uint256 amount = 100;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(bob);
        assertTrue(token1.transfer(alice, 200));
        vm.prank(alice);
        assertTrue(token1.approve(address(registry), 100));

        vm.expectRevert(EscrowFactory.EscrowFactory__PermitFailed.selector);
        registry.createEscrowPermit(address(token1), alice, bob, 100, h, amount, deadline, sig);
    }

    function test_createEscrowPermit_RevertsWhenTokenNotWhitelisted() public {
        vm.prank(bob);
        ERC20Impl unlistedToken = new ERC20Impl("Unlisted", "UL", alice);
        vm.prank(alice);
        assertTrue(unlistedToken.approve(address(registry), 100));

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.createEscrowPermit(address(unlistedToken), alice, bob, 100, h, 100, dl, sig);
    }

    function test_createEscrowPermit_RevertsWithFeeOnTransferToken() public {
        vm.prank(bob);
        assertTrue(feeToken.transfer(alice, 1000));

        bytes32 h = sha256(abi.encodePacked("permit-fee"));
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert(EscrowFactory.EscrowFactory__PermitFailed.selector);
        registry.createEscrowPermit(address(feeToken), alice, bob, 100, h, 500, dl, sig);
    }

    function test_createEscrowPermit_RevertsOnZeroCreator() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowPermit(address(permitToken), address(0), bob, 100, h, 100, dl, sig);
    }

    function test_createEscrowPermit_RevertsOnZeroRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowPermit(address(permitToken), alice, address(0), 100, h, 100, dl, sig);
    }

    function test_createEscrowPermit_RevertsOnCreatorEqualsRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowPermit(address(permitToken), alice, alice, 100, h, 100, dl, sig);
    }

    function test_createEscrowPermit_RevertsOnZeroExpiryBlocks() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroExpiryBlocks.selector);
        registry.createEscrowPermit(address(permitToken), alice, bob, 0, h, 100, dl, sig);
    }

    function test_createEscrowPermit_RevertsOnZeroAmount() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        uint256 dl = block.timestamp + 3600;
        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroAmount.selector);
        registry.createEscrowPermit(address(permitToken), alice, bob, 100, h, 0, dl, sig);
    }

    // ========== createEscrowSigned ==========

    function test_createEscrowSigned_Success() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("signed-secret"));
        uint256 amount = 300;

        bytes memory signature =
            _signCreateEscrow(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        address predicted = registry.getEscrowAddress(address(permitToken), alice, bob, 100, commitmentHash, amount);

        address escrow =
            registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);

        assertEq(escrow, predicted);
        assertTrue(registry.s_deployedEscrows(escrow));
        assertEq(permitToken.balanceOf(escrow), amount);
    }

    function test_createEscrowSigned_RevertsWhenInvalidSignature() public {
        bytes32 commitmentHash = sha256("x");
        uint256 amount = 100;

        uint256 bobPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        // Bob signs for himself as creator, but call passes alice as creator
        bytes memory signature = _signCreateEscrow(bobPk, address(permitToken), bob, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidSignature.selector);
        registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);
    }

    function test_createEscrowSigned_RevertsWhenNativeToken() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.expectRevert(EscrowFactory.EscrowFactory__OnlyERC20Allowed.selector);
        registry.createEscrowSigned(nativeToken, alice, bob, 100, h, 100, sig);
    }

    function test_createEscrowSigned_RevertsWhenEscrowAlreadyDeployed() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("signed-secret"));
        uint256 amount = 300;

        bytes memory signature =
            _signCreateEscrow(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);

        // Sign with same signature for second attempt (same params -> EscrowAlreadyDeployed)
        bytes memory signature2 =
            _signCreateEscrow(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        vm.expectRevert(EscrowFactory.EscrowFactory__EscrowAlreadyDeployed.selector);
        registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature2);
    }

    function test_createEscrowSigned_RevertsWhenTokenNotWhitelisted() public {
        vm.prank(bob);
        ERC20Impl unlistedToken = new ERC20Impl("Unlisted", "UL", alice);
        vm.prank(alice);
        assertTrue(unlistedToken.approve(address(registry), 100));

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 100;

        bytes memory signature =
            _signCreateEscrow(ALICE_PK, address(unlistedToken), alice, bob, 100, commitmentHash, amount);

        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.createEscrowSigned(address(unlistedToken), alice, bob, 100, commitmentHash, amount, signature);
    }

    // NOTE: Fee-on-transfer tokens are not supported by this escrow system
    // The contract does not check balance after transfer, so fee-on-transfer tokens
    // should not be whitelisted. This test is kept commented for reference.
    /*
    function test_createEscrowSigned_RevertsWhenInsufficientFundsAfterTransfer() public {
        vm.prank(bob);
        assertTrue(feeToken.transfer(alice, 200));
        vm.prank(alice);
        assertTrue(feeToken.approve(address(registry), 100));

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 100;

        bytes memory signature = _signCreateEscrow(
            ALICE_PK, address(feeToken), alice, bob, 100, commitmentHash, amount
        );

        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrowSigned(address(feeToken), alice, bob, 100, commitmentHash, amount, signature);
    }
    */

    function test_createEscrowSigned_RevertsOnZeroCreator() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowSigned(address(permitToken), address(0), bob, 100, h, 100, sig);
    }

    function test_createEscrowSigned_RevertsOnZeroRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowSigned(address(permitToken), alice, address(0), 100, h, 100, sig);
    }

    function test_createEscrowSigned_RevertsOnCreatorEqualsRecipient() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowSigned(address(permitToken), alice, alice, 100, h, 100, sig);
    }

    function test_createEscrowSigned_RevertsOnZeroExpiryBlocks() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroExpiryBlocks.selector);
        registry.createEscrowSigned(address(permitToken), alice, bob, 0, h, 100, sig);
    }

    function test_createEscrowSigned_RevertsOnZeroAmount() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes32 h = sha256("x");
        vm.expectRevert(EscrowFactory.EscrowFactory__ZeroAmount.selector);
        registry.createEscrowSigned(address(permitToken), alice, bob, 100, h, 0, sig);
    }

    // ========== Constants ==========

    function test_Constants() public view {
        assertEq(
            registry.CREATE_ESCROW_TYPEHASH(),
            keccak256(
                "CreateEscrowParams(address token,address creator,address recipient,uint256 expiryBlocks,bytes32 commitmentHash,uint256 amount)"
            )
        );
        assertEq(registry.NATIVE_TOKEN(), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    // ========== s_settled — double claim / refund / cross-call ==========

    function test_claim_RevertsOnDoubleClaim_ERC20() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        EscrowVault(escrow).claim(commitment);
        assertEq(token1.balanceOf(alice), 120);
        assertTrue(EscrowVault(escrow).s_settled());

        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(escrow).claim(commitment);
    }

    function test_refund_RevertsOnDoubleRefund_ERC20() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.roll(12);
        EscrowVault(escrow).refund();
        assertTrue(EscrowVault(escrow).s_settled());

        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(escrow).refund();
    }

    function test_refund_RevertsAfterClaim() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        EscrowVault(escrow).claim(commitment);

        vm.roll(12);
        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(escrow).refund();
    }

    function test_claim_RevertsAfterRefund() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.roll(12);
        EscrowVault(escrow).refund();

        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(escrow).claim(commitment);
    }

    function test_claim_RevertsOnDoubleClaim_NativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );

        EscrowVault(escrow).claim(commitment);
        assertTrue(EscrowVault(escrow).s_settled());

        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(escrow).claim(commitment);
    }

    function test_refund_RevertsOnDoubleRefund_NativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitmentHash = sha256(abi.encodePacked("any"));
        uint256 amount = 1 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, charlie, 10, commitmentHash, amount
        );

        vm.roll(block.number + 11);
        EscrowVault(escrow).refund();
        assertTrue(EscrowVault(escrow).s_settled());

        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(escrow).refund();
    }

    // ========== Third-party caller — funds go to recipient ==========

    function test_claim_ThirdPartyCallerFundsGoToRecipient_ERC20() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(charlie);
        EscrowVault(escrow).claim(commitment);

        assertEq(token1.balanceOf(alice), 120);
        assertEq(token1.balanceOf(charlie), 0);
    }

    function test_claim_ThirdPartyCallerFundsGoToRecipient_NativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1 ether;

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, 100, commitmentHash, amount
        );

        uint256 bobBefore = bob.balance;
        vm.prank(charlie);
        EscrowVault(escrow).claim(commitment);

        assertEq(bob.balance, bobBefore + amount);
    }

    // ========== Event emission assertions ==========

    function test_claim_EmitsClaimedEvent() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.expectEmit(true, false, false, true, escrow);
        emit EscrowVault.Claimed(alice, commitment);
        EscrowVault(escrow).claim(commitment);
    }

    function test_refund_EmitsRefundedEvent() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.roll(12);

        vm.expectEmit(true, false, false, true, escrow);
        emit EscrowVault.Refunded(bob, commitmentHash);
        EscrowVault(escrow).refund();
    }

    // ========== Signature replay with old nonce ==========

    function test_createEscrowSigned_RevertsOnReplayWithOldNonce() public {
        bytes32 commitmentHash = sha256(abi.encodePacked("replay-test"));
        uint256 amount = 200;

        bytes memory signature =
            _signCreateEscrow(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);

        // Replay with same signature on different params — should fail
        bytes32 commitmentHash2 = sha256(abi.encodePacked("replay-test-2"));

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidSignature.selector);
        registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash2, amount, signature);
    }

    // ========== getEscrowParameters public getter ==========

    function test_getEscrowParameters_ReturnsCorrectValues() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 expiryBlocks = 50;

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, expiryBlocks, commitmentHash, 120);

        (address token, address creator, address recipient, uint256 expiry, bytes32 storedHash) =
            EscrowVault(escrow).getEscrowParameters();

        assertEq(token, address(token1));
        assertEq(creator, bob);
        assertEq(recipient, alice);
        assertEq(expiry, expiryBlocks);
        assertEq(storedHash, commitmentHash);
    }

    // ========== Fuzz tests ==========

    function testFuzz_createAndClaim_ERC20(uint256 amount, uint256 expiryBlocks) public {
        amount = bound(amount, 1, 1_000_000 * 10 ** 18);
        expiryBlocks = bound(expiryBlocks, 1, 1_000_000);

        bytes32 commitment = sha256("fuzz-secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, amount));

        registry.createEscrow(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        assertTrue(registry.s_deployedEscrows(escrow));
        assertEq(token1.balanceOf(escrow), amount);

        EscrowVault(escrow).claim(commitment);

        assertEq(token1.balanceOf(alice), amount);
        assertEq(token1.balanceOf(escrow), 0);
        assertTrue(EscrowVault(escrow).s_settled());
    }

    function testFuzz_createAndRefund_ERC20(uint256 amount, uint256 expiryBlocks) public {
        amount = bound(amount, 1, 1_000_000 * 10 ** 18);
        expiryBlocks = bound(expiryBlocks, 1, 1_000_000);

        bytes32 commitmentHash = sha256(abi.encodePacked("fuzz-cancel"));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        uint256 bobBefore = token1.balanceOf(bob);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, amount));

        registry.createEscrow(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        uint256 depositedAt = EscrowVault(escrow).s_depositedAt();
        vm.roll(depositedAt + expiryBlocks + 1);

        EscrowVault(escrow).refund();

        assertEq(token1.balanceOf(bob), bobBefore);
        assertTrue(EscrowVault(escrow).s_settled());
    }

    function testFuzz_createAndClaim_NativeETH(uint256 amount, uint256 expiryBlocks) public {
        amount = bound(amount, 1, 100 ether);
        expiryBlocks = bound(expiryBlocks, 1, 1_000_000);

        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN());
        vm.stopPrank();

        bytes32 commitment = sha256("fuzz-native");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        vm.deal(alice, amount);
        vm.prank(alice);
        address escrow = registry.createEscrowNative{value: amount}(
            registry.NATIVE_TOKEN(), alice, bob, expiryBlocks, commitmentHash, amount
        );

        assertEq(escrow.balance, amount);

        uint256 bobBefore = bob.balance;
        EscrowVault(escrow).claim(commitment);

        assertEq(bob.balance, bobBefore + amount);
        assertEq(escrow.balance, 0);
        assertTrue(EscrowVault(escrow).s_settled());
    }

    function testFuzz_refundBeforeExpiry_Reverts(uint256 expiryBlocks) public {
        expiryBlocks = bound(expiryBlocks, 2, 1_000_000);

        bytes32 commitmentHash = sha256(abi.encodePacked("fuzz-expiry"));
        uint256 amount = 100;

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, amount));
        registry.createEscrow(address(token1), bob, alice, expiryBlocks, commitmentHash, amount);

        uint256 depositedAt = EscrowVault(escrow).s_depositedAt();

        // One block before expiry — should revert (>= semantics: need block.number >= depositedAt + expiryBlocks)
        vm.roll(depositedAt + expiryBlocks - 1);
        vm.expectRevert(EscrowVault.EscrowVault__EscrowNotExpired.selector);
        EscrowVault(escrow).refund();

        // At exactly expiry boundary — should succeed (>= means this block is eligible)
        vm.roll(depositedAt + expiryBlocks);
        EscrowVault(escrow).refund();
    }

    function testFuzz_invalidCommitment_Reverts(bytes32 wrongPreimage) public {
        bytes32 commitment = sha256("correct-secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        // Skip if the wrong preimage accidentally matches
        vm.assume(sha256(abi.encodePacked(wrongPreimage)) != commitmentHash);

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.expectRevert(EscrowVault.EscrowVault__InvalidCommitment.selector);
        EscrowVault(escrow).claim(wrongPreimage);
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

    function test_pause_BlocksCreateEscrow() public {
        vm.prank(bob);
        registry.pause();

        bytes32 h = sha256("x");
        vm.expectRevert();
        registry.createEscrow(address(token1), bob, alice, 10, h, 120);
    }

    function test_pause_BlocksCreateEscrowNative() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        registry.pause();
        vm.stopPrank();

        bytes32 h = sha256("x");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        registry.createEscrowNative{value: 1 ether}(nativeToken, alice, bob, 100, h, 1 ether);
    }

    function test_pause_BlocksCreateEscrowPermit() public {
        vm.prank(bob);
        registry.pause();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 dl = block.timestamp + 3600;

        vm.expectRevert();
        registry.createEscrowPermit(address(permitToken), alice, bob, 100, h, 100, dl, sig);
    }

    function test_pause_BlocksCreateEscrowSigned() public {
        vm.prank(bob);
        registry.pause();

        bytes32 h = sha256("x");
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.expectRevert();
        registry.createEscrowSigned(address(permitToken), alice, bob, 100, h, 100, sig);
    }

    function test_unpause_AllowsEscrowCreation() public {
        vm.startPrank(bob);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        bytes32 h = sha256("x");
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, h, 120);
        assertTrue(registry.s_deployedEscrows(escrow));
    }

    function test_pause_DoesNotBlockClaim() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));

        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, 120);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, commitmentHash, 120);

        vm.prank(bob);
        registry.pause();

        EscrowVault(escrow).claim(commitment);
        assertEq(token1.balanceOf(alice), 120);
    }

    function test_pause_DoesNotBlockRefund() public {
        bytes32 h = sha256(abi.encode(0x1232));
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, h, 120);

        vm.prank(bob);
        assertTrue(token1.transfer(escrow, 120));
        registry.createEscrow(address(token1), bob, alice, 10, h, 120);

        vm.prank(bob);
        registry.pause();

        vm.roll(12);
        EscrowVault(escrow).refund();
        assertEq(token1.balanceOf(bob), 100_000_000 * 10 ** 18);
    }

    // ========== incrementNonce ==========
    // NOTE: Nonce functionality has been removed from EscrowFactory
    // These tests are commented out until/unless nonce support is re-added

    /*
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
            _signCreateEscrow(ALICE_PK, address(permitToken), alice, bob, 100, commitmentHash, amount, 0);

        vm.prank(alice);
        assertTrue(permitToken.approve(address(registry), amount));

        // Creator bumps nonce to invalidate the signature
        vm.prank(alice);
        registry.incrementNonce();
        assertEq(registry.s_nonces(alice), 1);

        // Now the signature (signed with nonce 0) should fail since contract expects nonce 1
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidSignature.selector);
        registry.createEscrowSigned(address(permitToken), alice, bob, 100, commitmentHash, amount, signature);
    }
    */

    // ========== Batch escrow creation ==========

    function test_createEscrowBatch_Success() public {
        bytes32 h1 = sha256("batch-1");
        bytes32 h2 = sha256("batch-2");
        uint256 amount = 500;

        // Predict addresses
        address v1 = registry.getEscrowAddress(address(token1), bob, alice, 10, h1, amount);
        address v2 = registry.getEscrowAddress(address(token1), bob, charlie, 20, h2, amount);

        // Pre-fund both escrows
        vm.startPrank(bob);
        assertTrue(token1.transfer(v1, amount));
        assertTrue(token1.transfer(v2, amount));
        vm.stopPrank();

        // Build batch params
        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](2);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, h1, amount);
        params[1] = EscrowFactory.EscrowParams(address(token1), bob, charlie, 20, h2, amount);

        address[] memory escrows = registry.createEscrowBatch(params);

        assertEq(escrows.length, 2);
        assertEq(escrows[0], v1);
        assertEq(escrows[1], v2);
        assertTrue(registry.s_deployedEscrows(v1));
        assertTrue(registry.s_deployedEscrows(v2));
        assertEq(token1.balanceOf(v1), amount);
        assertEq(token1.balanceOf(v2), amount);
    }

    function test_createEscrowBatch_RevertsOnEmptyArray() public {
        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](0);

        vm.expectRevert(EscrowFactory.EscrowFactory__EmptyBatch.selector);
        registry.createEscrowBatch(params);
    }

    function test_createEscrowBatch_RevertsIfAnyEscrowFails() public {
        bytes32 h1 = sha256("batch-ok");
        bytes32 h2 = sha256("batch-fail");
        uint256 amount = 500;

        // Only fund the first escrow, not the second
        address v1 = registry.getEscrowAddress(address(token1), bob, alice, 10, h1, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(v1, amount));

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](2);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, h1, amount);
        params[1] = EscrowFactory.EscrowParams(address(token1), bob, charlie, 20, h2, amount);

        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrowBatch(params);

        // First escrow should NOT be deployed since entire tx reverted
        assertFalse(registry.s_deployedEscrows(v1));
    }

    function test_createEscrowBatch_RevertsWhenPaused() public {
        vm.prank(bob);
        registry.pause();

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](1);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, sha256("x"), 100);

        vm.expectRevert();
        registry.createEscrowBatch(params);
    }

    function test_createEscrowBatch_ClaimFromBatchEscrow() public {
        bytes32 commitment = sha256("batch-secret");
        bytes32 commitmentHash = sha256(abi.encodePacked(commitment));
        uint256 amount = 1000;

        address v1 = registry.getEscrowAddress(address(token1), bob, alice, 10, commitmentHash, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(v1, amount));

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](1);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, commitmentHash, amount);

        address[] memory escrows = registry.createEscrowBatch(params);

        EscrowVault(escrows[0]).claim(commitment);
        assertEq(token1.balanceOf(alice), amount);
    }

    function test_createEscrowBatch_NativeETH() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.startPrank(bob);
        registry.whitelistToken(nativeToken);
        vm.stopPrank();

        bytes32 h1 = sha256("batch-native-1");
        bytes32 h2 = sha256("batch-native-2");
        uint256 amount = 1 ether;

        address v1 = registry.getEscrowAddress(nativeToken, alice, bob, 10, h1, amount);
        address v2 = registry.getEscrowAddress(nativeToken, alice, charlie, 20, h2, amount);

        // Pre-fund both predicted addresses with ETH
        vm.deal(alice, amount * 2);
        vm.startPrank(alice);
        (bool s1,) = payable(v1).call{value: amount}("");
        assertTrue(s1);
        (bool s2,) = payable(v2).call{value: amount}("");
        assertTrue(s2);
        vm.stopPrank();

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](2);
        params[0] = EscrowFactory.EscrowParams(nativeToken, alice, bob, 10, h1, amount);
        params[1] = EscrowFactory.EscrowParams(nativeToken, alice, charlie, 20, h2, amount);

        address[] memory escrows = registry.createEscrowBatch(params);

        assertEq(escrows[0], v1);
        assertEq(escrows[1], v2);
        assertEq(v1.balance, amount);
        assertEq(v2.balance, amount);
    }

    function test_createEscrowBatch_EmitsEventsForEachEscrow() public {
        bytes32 h1 = sha256("batch-event-1");
        bytes32 h2 = sha256("batch-event-2");
        uint256 amount = 200;

        address v1 = registry.getEscrowAddress(address(token1), bob, alice, 10, h1, amount);
        address v2 = registry.getEscrowAddress(address(token1), bob, charlie, 20, h2, amount);

        vm.startPrank(bob);
        assertTrue(token1.transfer(v1, amount));
        assertTrue(token1.transfer(v2, amount));
        vm.stopPrank();

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](2);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, h1, amount);
        params[1] = EscrowFactory.EscrowParams(address(token1), bob, charlie, 20, h2, amount);

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(v1, bob, address(token1), alice, h1, 10, amount);
        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(v2, bob, address(token1), charlie, h2, 20, amount);
        registry.createEscrowBatch(params);
    }

    function test_createEscrowBatch_RevertsOnInvalidParams() public {
        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](1);
        // creator == recipient
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, bob, 10, sha256("x"), 100);

        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidAddressParameters.selector);
        registry.createEscrowBatch(params);
    }

    // ========== Richer EscrowCreated event ==========

    function test_createEscrow_EmitsRichEscrowCreatedEvent() public {
        bytes32 h = sha256("x");
        uint256 amount = 120;
        address escrow = registry.getEscrowAddress(address(token1), bob, alice, 10, h, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(escrow, amount));

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(escrow, bob, address(token1), alice, h, 10, amount);
        registry.createEscrow(address(token1), bob, alice, 10, h, amount);
    }

    // ========== createEscrowBatch uncovered branches ==========

    /// @dev Covers branch: require(s_whitelistedTokens[p.token]) inside createEscrowBatch
    function test_createEscrowBatch_RevertsOnNonWhitelistedToken() public {
        ERC20Impl unlistedToken = new ERC20Impl("Unlisted", "UL", bob);

        address v1 = registry.getEscrowAddress(address(token1), bob, alice, 10, sha256("ok"), 100);
        vm.prank(bob);
        assertTrue(token1.transfer(v1, 100));

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](2);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, sha256("ok"), 100);
        // second entry uses a non-whitelisted token → should revert
        params[1] = EscrowFactory.EscrowParams(address(unlistedToken), bob, charlie, 10, sha256("bad"), 100);

        vm.expectRevert(EscrowFactory.EscrowFactory__TokenNotAccepted.selector);
        registry.createEscrowBatch(params);
    }

    /// @dev Covers branch: require(!s_deployedEscrows[addr]) inside createEscrowBatch
    function test_createEscrowBatch_RevertsOnAlreadyDeployedEscrow() public {
        bytes32 h = sha256("already-deployed");
        uint256 amount = 100;

        // First deploy it normally
        address v1 = registry.getEscrowAddress(address(token1), bob, alice, 10, h, amount);
        vm.prank(bob);
        assertTrue(token1.transfer(v1, amount));
        registry.createEscrow(address(token1), bob, alice, 10, h, amount);
        assertTrue(registry.s_deployedEscrows(v1));

        // Now try to batch-create the same escrow (already deployed)
        vm.prank(bob);
        assertTrue(token1.transfer(v1, amount)); // pre-fund again (irrelevant, will revert)

        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](1);
        params[0] = EscrowFactory.EscrowParams(address(token1), bob, alice, 10, h, amount);

        vm.expectRevert(EscrowFactory.EscrowFactory__EscrowAlreadyDeployed.selector);
        registry.createEscrowBatch(params);
    }

    /// @dev Covers branch: require(address(addr).balance >= p.amount) — native ETH path inside createEscrowBatch
    function test_createEscrowBatch_RevertsOnInsufficientNativeETH() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.prank(bob);
        registry.whitelistToken(nativeToken);

        bytes32 h = sha256("batch-native-insufficient");
        uint256 amount = 1 ether;

        // deliberately do NOT pre-fund the predicted address
        EscrowFactory.EscrowParams[] memory params = new EscrowFactory.EscrowParams[](1);
        params[0] = EscrowFactory.EscrowParams(nativeToken, alice, bob, 10, h, amount);

        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrowBatch(params);
    }

    /// @dev Covers branch: require(IERC20(token).balanceOf(addr) >= amount) in _createErc20EscrowFromCreator
    ///      A fee-on-transfer token delivers only 90% of `amount` to the escrow address,
    ///      so the post-transfer balance check fails.
    function test_createEscrowSigned_RevertsOnFeeOnTransferToken() public {
        // Transfer enough so alice can send `amount` in full (fee deducted from alice, not escrow)
        // safeTransferFrom(alice, escrow, amount) → escrow receives amount*0.9 < amount → revert
        uint256 amount = 900; // escrow will receive 810 (90%), which is < 900
        vm.prank(bob);
        // Give alice 1000 so she can afford the full `amount` debit (900 debit + 100 fee = 1000 total)
        assertTrue(feeToken.transfer(alice, 1100)); // alice receives 990 after 10% fee

        vm.prank(alice);
        assertTrue(feeToken.approve(address(registry), amount));

        bytes32 commitmentHash = sha256(abi.encodePacked("fee-token-test"));

        bytes memory signature = _signCreateEscrow(ALICE_PK, address(feeToken), alice, bob, 10, commitmentHash, amount);

        // safeTransferFrom succeeds (alice has enough), but escrow only receives 810 < 900
        // → require(IERC20(token).balanceOf(addr) >= amount) reverts
        vm.expectRevert(EscrowFactory.EscrowFactory__InsufficientFundsDeposited.selector);
        registry.createEscrowSigned(address(feeToken), alice, bob, 10, commitmentHash, amount, signature);
    }
}

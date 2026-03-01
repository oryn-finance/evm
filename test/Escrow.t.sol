// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SwapRegistry} from "../src/SwapRegistry.sol";
import {TokenDepositVault} from "../src/TokenDepositVault.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20Impl is ERC20 {
    constructor(string memory name, string memory symbol, address mintTo) ERC20(name, symbol) {
        _mint(mintTo, 100_000_000 * 10 ** decimals());
    }
}

contract RegistryAndVaultTest is Test {
    event TokenVaultCreated(address indexed vaultAddress, address indexed creator, address indexed token);

    SwapRegistry registry;
    ERC20Impl token1;
    ERC20Impl token2;

    // addresses
    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address charlie = makeAddr("charlie");

    function setUp() public {
        vm.startPrank(bob);
        token1 = new ERC20Impl("TestCoin1", "TC1", bob);
        token2 = new ERC20Impl("TestCoin2", "TC2", bob);

        registry = new SwapRegistry(bob);

        registry.whitelistToken(address(token1), true);
        registry.whitelistToken(address(token2), true);

        vm.stopPrank();
    }

    function test_WhitelistAndOwner() public view {
        bool flag = registry.s_whitelistedTokens(address(token1));
        bool flag2 = registry.s_whitelistedTokens(address(token2));

        assert(flag == true);
        assert(flag2 == true);

        assertEq(registry.owner(), bob);
    }

    function test_getDeployAddressChecks() public {
        try registry.getTokenVaultAddress(address(123), bob, alice, 10, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        }

        try registry.getTokenVaultAddress(address(token1), bob, bob, 10, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        }

        try registry.getTokenVaultAddress(address(token1), address(0), alice, 10, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        }

        try registry.getTokenVaultAddress(address(token1), bob, address(0), 10, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        }

        try registry.getTokenVaultAddress(address(token1), bob, alice, 0, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__ZeroExpiryBlocks.selector);
        }

        try registry.getTokenVaultAddress(address(token1), bob, alice, 100, sha256(abi.encode(0x1232)), 0) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__ZeroAmount.selector);
        }

        try registry.createTokenSwapVault(
            address(registry.NATIVE_TOKEN()), bob, alice, 100, sha256(abi.encode(0x1232)), 1000
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        }

        address x = registry.getTokenVaultAddress(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120);
        assert(registry.s_deployedVaults(x) == false);
    }

    function test_getVaultAddressButFundWrongAsset() public {
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120);

        vm.prank(bob);
        token2.transfer(vault, 120);

        try registry.createTokenSwapVault(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        }

        // address vault2 = registry.createTokenSwapVault(address(token2), bob, alice, 10, sha256(abi.encode(0x1232)), 120);
        // assert(vault != vault2);

        try registry.createTokenSwapVault(address(token2), bob, alice, 10, sha256(abi.encode(0x1232)), 120) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        }
    }

    function test_depositintoCorrectVault() public {
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120);

        assert(block.number == 1);
        console.log("the current block number ", block.number);

        vm.prank(bob);
        token1.transfer(vault, 120);

        vm.roll(block.number + 10);

        registry.createTokenSwapVault(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120);

        assert(block.number == TokenDepositVault(vault).s_depositedAt());
    }

    function test_CancelBeforetimelockNotAllowed() public {
        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120);

        uint256 beforebalance = token1.balanceOf(bob);

        vm.prank(bob);
        token1.transfer(vault, 120);

        assert(token1.balanceOf(bob) == beforebalance - 120);

        registry.createTokenSwapVault(address(token1), bob, alice, 10, sha256(abi.encode(0x1232)), 120);

        vm.expectRevert(TokenDepositVault.TokenDepositVault__SwapNotExpired.selector);
        TokenDepositVault(vault).cancelSwap();

        vm.roll(12);
        TokenDepositVault(vault).cancelSwap();

        assert(token1.balanceOf(bob) == beforebalance);
    }

    function test_withdrawVault() public {
        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address vault = registry.getTokenVaultAddress(address(token1), bob, alice, 10, commitmenthash, 120);

        uint256 beforebalance = token1.balanceOf(bob);

        vm.prank(bob);
        token1.transfer(vault, 120);

        assert(token1.balanceOf(bob) == beforebalance - 120);

        registry.createTokenSwapVault(address(token1), bob, alice, 10, commitmenthash, 120);

        TokenDepositVault(vault).withdraw(abi.encode(commitment));
        assert(token1.balanceOf(alice) == 120);
    }

    function test_depositNativeETH() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        hoax(alice, 1000);
        payable(predictedAddr).call{value: 1000}("");

        assert(predictedAddr.balance == 1000);

        // vm.prank(bob);
        // token1.transfer(predictedAddr, 1000);

        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        assert(bob.balance == 0);

        TokenDepositVault(predictedAddr).withdraw(abi.encode(commitment));

        assert(bob.balance == 1000);
    }

    function test_cancelNativeEscrow() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        hoax(alice, 1000);
        payable(predictedAddr).call{value: 1000}("");

        assert(predictedAddr.balance == 1000);

        // vm.prank(bob);
        // token1.transfer(predictedAddr, 1000);

        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        vm.roll(102);

        assert(alice.balance == 0);

        TokenDepositVault(predictedAddr).cancelSwap();

        assert(alice.balance == 1000);
    }

    function test_witdrawShouldFailIfInCorrectCommitment() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        hoax(alice, 1000);
        payable(predictedAddr).call{value: 1000}("");

        assert(predictedAddr.balance == 1000);
        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        vm.expectRevert();
        TokenDepositVault(predictedAddr).withdraw(abi.encode(commitment, "1"));
    }

    function test_shouldntAllowSameAddressVault() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address predictedAddr =
            registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        hoax(alice, 1000);
        payable(predictedAddr).call{value: 1000}("");

        assert(predictedAddr.balance == 1000);
        registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000);

        try registry.createTokenSwapVault(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        }

        try registry.getTokenVaultAddress(registry.NATIVE_TOKEN(), alice, bob, 100, commitmenthash, 1000) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        }
    }

    function test_withdrawAndRefundWillFailIfTheyAreContractWIthOutReceiveOrFallBack() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address predictedAddr = registry.getTokenVaultAddress(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmenthash, 1000
        );

        hoax(alice, 1000);
        payable(predictedAddr).call{value: 1000}("");

        assert(predictedAddr.balance == 1000);

        registry.createTokenSwapVault(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmenthash, 1000
        );

        try TokenDepositVault(predictedAddr).withdraw(abi.encode(commitment)) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == TokenDepositVault.TokenDepositVault__NativeWithdrawFailed.selector);
        }

        assert(predictedAddr.balance == 1000);

        vm.roll(103);
        try TokenDepositVault(predictedAddr).cancelSwap() {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == TokenDepositVault.TokenDepositVault__NativeWithdrawFailed.selector);
        }
    }

    function test_NativeVaultWontBeCreatedWithOutBalance() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        bytes32 commitment = sha256("hello");
        bytes32 commitmenthash = sha256(abi.encodePacked(commitment));

        address predictedAddr = registry.getTokenVaultAddress(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmenthash, 1000
        );

        assert(predictedAddr.balance == 0);

        try registry.createTokenSwapVault(
            registry.NATIVE_TOKEN(), address(token1), address(token2), 100, commitmenthash, 1000
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InsufficientFundsDeposited.selector);
        }
    }

    // ========== createTokenSwapVaultNativeCall tests ==========

    function test_createTokenSwapVaultNativeCall_Success() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
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

        assertEq(vault, predictedAddr, "returned address should match predicted");
        assertTrue(registry.s_deployedVaults(vault), "vault should be marked deployed");
        assertEq(vault.balance, amount, "vault should hold the sent ETH");
        assertEq(TokenDepositVault(vault).s_depositedAt(), block.number, "depositedAt should be set");
    }

    function test_createTokenSwapVaultNativeCall_WithdrawWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
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
        assertEq(bob.balance, bobBefore + amount, "recipient should receive ETH");
        assertEq(vault.balance, 0, "vault should be empty after withdraw");
    }

    function test_createTokenSwapVaultNativeCall_CancelAfterExpiryWorks() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
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
        assertEq(alice.balance, aliceBefore + amount, "creator should get refund");
        assertEq(vault.balance, 0, "vault should be empty after cancel");
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenTokenNotNative() public {
        vm.startPrank(bob);
        registry.whitelistToken(registry.NATIVE_TOKEN(), true);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 1 ether}(
            address(token1), alice, bob, 100, sha256("x"), 1 ether
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__OnlyNativeTokenAllowed.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenMsgValueMismatch() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 500}(nativeToken, alice, bob, 100, sha256("x"), 1 ether) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__MsgValueAmountMismatch.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenNativeNotWhitelisted() public {
        address nativeToken = registry.NATIVE_TOKEN();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 1 ether}(
            nativeToken, alice, bob, 100, sha256("x"), 1 ether
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__TokenNotAccepted.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenVaultAlreadyDeployed() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount * 2);

        vm.prank(alice);
        registry.createTokenSwapVaultNativeCall{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: amount}(
            nativeToken, alice, bob, 100, commitmentHash, amount
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__VaultAlreadyDeployed.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenCreatorZero() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 1 ether}(
            nativeToken, address(0), bob, 100, sha256("x"), 1 ether
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenRecipientZero() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 1 ether}(
            nativeToken, alice, address(0), 100, sha256("x"), 1 ether
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenCreatorEqualsRecipient() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 1 ether}(
            nativeToken, alice, alice, 100, sha256("x"), 1 ether
        ) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__InvalidAddressParameters.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenZeroExpiryBlocks() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 1 ether}(nativeToken, alice, bob, 0, sha256("x"), 1 ether) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__ZeroExpiryBlocks.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_RevertWhenZeroAmount() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        try registry.createTokenSwapVaultNativeCall{value: 0}(nativeToken, alice, bob, 100, sha256("x"), 0) {
            assert(false);
        } catch (bytes memory e) {
            assert(bytes32(e) == SwapRegistry.SwapRegistry__ZeroAmount.selector);
        }
    }

    function test_createTokenSwapVaultNativeCall_EmitsTokenVaultCreated() public {
        vm.startPrank(bob);
        address nativeToken = registry.NATIVE_TOKEN();
        registry.whitelistToken(nativeToken, true);
        vm.stopPrank();

        bytes32 commitmentHash = sha256("x");
        uint256 amount = 1 ether;
        vm.deal(alice, amount);

        address predicted = registry.getTokenVaultAddress(nativeToken, alice, bob, 100, commitmentHash, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit TokenVaultCreated(predicted, alice, nativeToken);
        registry.createTokenSwapVaultNativeCall{value: amount}(nativeToken, alice, bob, 100, commitmentHash, amount);
    }
}

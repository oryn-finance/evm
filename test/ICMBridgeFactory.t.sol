// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICMBridgeFactory} from "../src/ICMBridgeFactory.sol";
import {ITokenTransferrer, SendTokensInput} from "../src/interfaces/IICTT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

//////////////////////////////////////////////////////////////////////////////
// Test helpers
//////////////////////////////////////////////////////////////////////////////

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, address mintTo_) ERC20(name_, symbol_) {
        _mint(mintTo_, 10_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Records the most recent call to send() so tests can inspect params.
contract MockTokenTransferrer is ITokenTransferrer {
    SendTokensInput private _lastInput;
    uint256 public lastAmount;
    uint256 public sendCallCount;

    bool private _shouldRevert;

    function send(SendTokensInput calldata input, uint256 amount) external override {
        if (_shouldRevert) revert("MockTransferrer: forced revert");
        _lastInput = input;
        lastAmount = amount;
        sendCallCount++;
    }

    function setShouldRevert(bool flag) external {
        _shouldRevert = flag;
    }

    /// @notice Returns the full SendTokensInput from the last send() call.
    function getLastInput() external view returns (SendTokensInput memory) {
        return _lastInput;
    }
}

//////////////////////////////////////////////////////////////////////////////
// Main test contract
//////////////////////////////////////////////////////////////////////////////

contract ICMBridgeFactoryTest is Test {
    // Mirror events for expectEmit
    event RouteRegistered(
        address indexed token,
        bytes32 indexed destBlockchainId,
        address tokenTransferrer,
        address destTransferrer,
        uint256 requiredGasLimit
    );
    event RouteUpdated(
        address indexed token,
        bytes32 indexed destBlockchainId,
        address tokenTransferrer,
        address destTransferrer,
        uint256 requiredGasLimit
    );
    event RouteDeregistered(address indexed token, bytes32 indexed destBlockchainId);
    event BridgeSent(
        address indexed token,
        bytes32 indexed destBlockchainId,
        address indexed sender,
        address recipient,
        uint256 amount,
        uint256 relayerFee
    );

    ICMBridgeFactory factory;
    MockERC20 token;
    MockERC20 feeToken;
    MockTokenTransferrer transferrer;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant DEST_CHAIN_A =
        bytes32(uint256(0xabc1230000000000000000000000000000000000000000000000000000000000));
    bytes32 constant DEST_CHAIN_B =
        bytes32(uint256(0xdef4560000000000000000000000000000000000000000000000000000000000));
    address constant DEST_TRANSFERRER = address(0xdead000000000000000000000000000000000001);
    uint256 constant GAS_LIMIT = 250_000;

    function setUp() public {
        vm.prank(owner);
        factory = new ICMBridgeFactory(owner);

        token = new MockERC20("BridgeToken", "BT", alice);
        feeToken = new MockERC20("FeeToken", "FT", alice);
        transferrer = new MockTokenTransferrer();

        vm.startPrank(alice);
        token.approve(address(factory), type(uint256).max);
        feeToken.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////////////////
    // Helpers
    //////////////////////////////////////////////////////////////////////////

    function _registerRoute() internal {
        vm.prank(owner);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    //////////////////////////////////////////////////////////////////////////
    // registerRoute
    //////////////////////////////////////////////////////////////////////////

    function test_registerRoute_success() public {
        vm.expectEmit(true, true, false, true);
        emit RouteRegistered(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);

        _registerRoute();

        ICMBridgeFactory.BridgeRoute memory route = factory.getRoute(address(token), DEST_CHAIN_A);
        assertEq(route.tokenTransferrer, address(transferrer));
        assertEq(route.destTransferrer, DEST_TRANSFERRER);
        assertEq(route.requiredGasLimit, GAS_LIMIT);
        assertTrue(route.active);
    }

    function test_registerRoute_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_registerRoute_revert_zeroToken() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAddress.selector);
        factory.registerRoute(address(0), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_registerRoute_revert_zeroTokenTransferrer() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAddress.selector);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(0), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_registerRoute_revert_zeroDestTransferrer() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAddress.selector);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), address(0), GAS_LIMIT);
    }

    function test_registerRoute_revert_zeroGasLimit() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroGasLimit.selector);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, 0);
    }

    function test_registerRoute_revert_zeroBlockchainId() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__InvalidBlockchainId.selector);
        factory.registerRoute(address(token), bytes32(0), address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_registerRoute_revert_alreadyRegistered() public {
        _registerRoute();
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__RouteAlreadyRegistered.selector);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_registerRoute_multipleTokensSameChain() public {
        MockERC20 token2 = new MockERC20("Token2", "T2", alice);

        vm.startPrank(owner);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
        factory.registerRoute(address(token2), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
        factory.registerRoute(address(token), DEST_CHAIN_B, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
        vm.stopPrank();

        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_A));
        assertTrue(factory.isRouteActive(address(token2), DEST_CHAIN_A));
        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_B));
        // Cross-check: token2 on chain B is not registered
        assertFalse(factory.isRouteActive(address(token2), DEST_CHAIN_B));
    }

    //////////////////////////////////////////////////////////////////////////
    // updateRoute
    //////////////////////////////////////////////////////////////////////////

    function test_updateRoute_success() public {
        _registerRoute();

        address newTransferrer = makeAddr("newTransferrer");
        address newDestTransferrer = makeAddr("newDestTransferrer");
        uint256 newGasLimit = 500_000;

        vm.expectEmit(true, true, false, true);
        emit RouteUpdated(address(token), DEST_CHAIN_A, newTransferrer, newDestTransferrer, newGasLimit);

        vm.prank(owner);
        factory.updateRoute(address(token), DEST_CHAIN_A, newTransferrer, newDestTransferrer, newGasLimit);

        ICMBridgeFactory.BridgeRoute memory route = factory.getRoute(address(token), DEST_CHAIN_A);
        assertEq(route.tokenTransferrer, newTransferrer);
        assertEq(route.destTransferrer, newDestTransferrer);
        assertEq(route.requiredGasLimit, newGasLimit);
        assertTrue(route.active);
    }

    function test_updateRoute_revert_nonOwner() public {
        _registerRoute();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_updateRoute_revert_routeNotFound() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__RouteNotFound.selector);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_updateRoute_revert_zeroGasLimit() public {
        _registerRoute();
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroGasLimit.selector);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, 0);
    }

    function test_updateRoute_revert_zeroTransferrer() public {
        _registerRoute();
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAddress.selector);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(0), DEST_TRANSFERRER, GAS_LIMIT);
    }

    function test_updateRoute_revert_zeroDestTransferrer() public {
        _registerRoute();
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAddress.selector);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), address(0), GAS_LIMIT);
    }

    function test_updateRoute_preservesActiveFlag() public {
        _registerRoute();
        vm.prank(owner);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, 300_000);
        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_A));
    }

    //////////////////////////////////////////////////////////////////////////
    // deregisterRoute
    //////////////////////////////////////////////////////////////////////////

    function test_deregisterRoute_success() public {
        _registerRoute();

        vm.expectEmit(true, true, false, false);
        emit RouteDeregistered(address(token), DEST_CHAIN_A);

        vm.prank(owner);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);

        assertFalse(factory.isRouteActive(address(token), DEST_CHAIN_A));
        ICMBridgeFactory.BridgeRoute memory route = factory.getRoute(address(token), DEST_CHAIN_A);
        assertEq(route.tokenTransferrer, address(0));
        assertEq(route.destTransferrer, address(0));
        assertEq(route.requiredGasLimit, 0);
        assertFalse(route.active);
    }

    function test_deregisterRoute_revert_nonOwner() public {
        _registerRoute();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
    }

    function test_deregisterRoute_revert_routeNotFound() public {
        vm.prank(owner);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__RouteNotFound.selector);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
    }

    function test_deregisterRoute_revert_alreadyDeregistered() public {
        _registerRoute();
        vm.startPrank(owner);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__RouteNotFound.selector);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        vm.stopPrank();
    }

    function test_deregisterRoute_thenReregister_success() public {
        _registerRoute();
        vm.prank(owner);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        // Can register again after deregistering
        _registerRoute();
        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_A));
    }

    function test_deregisterRoute_onlyAffectsTargetRoute() public {
        vm.startPrank(owner);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
        factory.registerRoute(address(token), DEST_CHAIN_B, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        vm.stopPrank();

        assertFalse(factory.isRouteActive(address(token), DEST_CHAIN_A));
        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_B));
    }

    //////////////////////////////////////////////////////////////////////////
    // pause / unpause
    //////////////////////////////////////////////////////////////////////////

    function test_pause_success() public {
        vm.prank(owner);
        factory.pause();
        assertTrue(factory.paused());
    }

    function test_unpause_success() public {
        vm.startPrank(owner);
        factory.pause();
        factory.unpause();
        vm.stopPrank();
        assertFalse(factory.paused());
    }

    function test_pause_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.pause();
    }

    function test_unpause_revert_nonOwner() public {
        vm.prank(owner);
        factory.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.unpause();
    }

    function test_bridge_revert_whenPaused() public {
        _registerRoute();
        vm.prank(owner);
        factory.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);
    }

    function test_adminActions_allowedWhilePaused() public {
        _registerRoute();
        vm.startPrank(owner);
        factory.pause();
        // Admin route management still works when paused
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        factory.registerRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, GAS_LIMIT);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, 300_000);
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////////////////
    // bridge — happy paths
    //////////////////////////////////////////////////////////////////////////

    function test_bridge_noFee_pullsTokensAndCallsSend() public {
        _registerRoute();
        uint256 amount = 100e18;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit BridgeSent(address(token), DEST_CHAIN_A, alice, bob, amount, 0);

        vm.prank(alice);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(0), 0);

        // Alice's balance reduced by exact bridge amount
        assertEq(token.balanceOf(alice), aliceBefore - amount);
        // send() called exactly once
        assertEq(transferrer.sendCallCount(), 1);
        assertEq(transferrer.lastAmount(), amount);
    }

    function test_bridge_noFee_sendInputParams() public {
        _registerRoute();

        vm.prank(alice);
        factory.bridge(address(token), 50e18, DEST_CHAIN_A, bob, address(0), 0);

        SendTokensInput memory inp = transferrer.getLastInput();
        assertEq(inp.destinationBlockchainID, DEST_CHAIN_A);
        assertEq(inp.destinationTokenTransferrerAddress, DEST_TRANSFERRER);
        assertEq(inp.recipient, bob);
        assertEq(inp.primaryFeeTokenAddress, address(0));
        assertEq(inp.primaryRelayerFee, 0);
        assertEq(inp.secondaryRelayerFee, 0);
        assertEq(inp.requiredGasLimit, GAS_LIMIT);
        assertEq(inp.multiHopFallback, address(0));
    }

    function test_bridge_separateFeeToken_pullsBothTokens() public {
        _registerRoute();
        uint256 amount = 100e18;
        uint256 fee = 1e18;
        uint256 aliceTokenBefore = token.balanceOf(alice);
        uint256 aliceFeeBefore = feeToken.balanceOf(alice);

        vm.prank(alice);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(feeToken), fee);

        assertEq(token.balanceOf(alice), aliceTokenBefore - amount);
        assertEq(feeToken.balanceOf(alice), aliceFeeBefore - fee);
        assertEq(transferrer.lastAmount(), amount);

        SendTokensInput memory inp = transferrer.getLastInput();
        assertEq(inp.primaryFeeTokenAddress, address(feeToken));
        assertEq(inp.primaryRelayerFee, fee);
    }

    function test_bridge_feeInBridgeToken_pullsCombinedAmount() public {
        _registerRoute();
        uint256 amount = 100e18;
        uint256 fee = 2e18;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(token), fee);

        // Alice loses amount + fee
        assertEq(token.balanceOf(alice), aliceBefore - amount - fee);
        // ICTT send() receives net amount only
        assertEq(transferrer.lastAmount(), amount);

        SendTokensInput memory inp = transferrer.getLastInput();
        assertEq(inp.primaryFeeTokenAddress, address(token));
        assertEq(inp.primaryRelayerFee, fee);
    }

    function test_bridge_zeroRelayerFee_doesNotPullFeeToken() public {
        _registerRoute();
        uint256 aliceFeeBefore = feeToken.balanceOf(alice);

        vm.prank(alice);
        // relayerFee == 0 even though feeToken address is given — should not pull feeToken
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(feeToken), 0);

        assertEq(feeToken.balanceOf(alice), aliceFeeBefore);
    }

    function test_bridge_multipleBridgesAccumulateSendCalls() public {
        _registerRoute();

        vm.startPrank(alice);
        factory.bridge(address(token), 10e18, DEST_CHAIN_A, bob, address(0), 0);
        factory.bridge(address(token), 20e18, DEST_CHAIN_A, bob, address(0), 0);
        factory.bridge(address(token), 30e18, DEST_CHAIN_A, bob, address(0), 0);
        vm.stopPrank();

        assertEq(transferrer.sendCallCount(), 3);
    }

    function test_bridge_usesUpdatedRouteGasLimit() public {
        _registerRoute();
        uint256 newGas = 400_000;
        vm.prank(owner);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, newGas);

        vm.prank(alice);
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);

        assertEq(transferrer.getLastInput().requiredGasLimit, newGas);
    }

    //////////////////////////////////////////////////////////////////////////
    // bridge — approval mechanics
    //////////////////////////////////////////////////////////////////////////

    function test_bridge_approvesExactAmountToTransferrer() public {
        _registerRoute();
        uint256 amount = 50e18;

        vm.prank(alice);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(0), 0);

        // MockTransferrer doesn't consume approval — factory's allowance should equal the approved amount
        assertEq(token.allowance(address(factory), address(transferrer)), amount);
    }

    function test_bridge_feeInBridgeToken_approvesCombinedAmount() public {
        _registerRoute();
        uint256 amount = 50e18;
        uint256 fee = 5e18;

        vm.prank(alice);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(token), fee);

        assertEq(token.allowance(address(factory), address(transferrer)), amount + fee);
    }

    function test_bridge_separateFeeToken_approvesEachTokenCorrectly() public {
        _registerRoute();
        uint256 amount = 50e18;
        uint256 fee = 3e18;

        vm.prank(alice);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(feeToken), fee);

        assertEq(token.allowance(address(factory), address(transferrer)), amount);
        assertEq(feeToken.allowance(address(factory), address(transferrer)), fee);
    }

    function test_bridge_subsequentCallResetsApprovalToNewAmount() public {
        _registerRoute();

        vm.startPrank(alice);
        factory.bridge(address(token), 100e18, DEST_CHAIN_A, bob, address(0), 0);
        factory.bridge(address(token), 200e18, DEST_CHAIN_A, bob, address(0), 0);
        vm.stopPrank();

        // forceApprove resets then sets — last call wins
        assertEq(token.allowance(address(factory), address(transferrer)), 200e18);
    }

    //////////////////////////////////////////////////////////////////////////
    // bridge — reverts
    //////////////////////////////////////////////////////////////////////////

    function test_bridge_revert_zeroAmount() public {
        _registerRoute();
        vm.prank(alice);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAmount.selector);
        factory.bridge(address(token), 0, DEST_CHAIN_A, bob, address(0), 0);
    }

    function test_bridge_revert_zeroRecipient() public {
        _registerRoute();
        vm.prank(alice);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__ZeroAddress.selector);
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, address(0), address(0), 0);
    }

    function test_bridge_revert_routeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__RouteNotFound.selector);
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);
    }

    function test_bridge_revert_routeDeregistered() public {
        _registerRoute();
        vm.prank(owner);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        vm.prank(alice);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__RouteNotFound.selector);
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);
    }

    function test_bridge_revert_feeNonZeroButFeeTokenZero() public {
        _registerRoute();
        vm.prank(alice);
        vm.expectRevert(ICMBridgeFactory.ICMBridgeFactory__InvalidFeeParameters.selector);
        // fee > 0 but feeToken == address(0) is invalid
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 1e17);
    }

    function test_bridge_revert_insufficientAllowance() public {
        _registerRoute();
        // Revoke approval
        vm.prank(alice);
        token.approve(address(factory), 0);

        vm.prank(alice);
        vm.expectRevert();
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);
    }

    function test_bridge_revert_insufficientBalance() public {
        _registerRoute();
        address poorUser = makeAddr("poor");
        // poorUser has no tokens, approve factory
        vm.prank(poorUser);
        token.approve(address(factory), type(uint256).max);

        vm.prank(poorUser);
        vm.expectRevert();
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);
    }

    function test_bridge_revert_transferrerReverts() public {
        _registerRoute();
        transferrer.setShouldRevert(true);

        vm.prank(alice);
        vm.expectRevert("MockTransferrer: forced revert");
        factory.bridge(address(token), 1e18, DEST_CHAIN_A, bob, address(0), 0);
    }

    //////////////////////////////////////////////////////////////////////////
    // view functions
    //////////////////////////////////////////////////////////////////////////

    function test_getRoute_returnsZeroRouteWhenUnregistered() public view {
        ICMBridgeFactory.BridgeRoute memory route = factory.getRoute(address(token), DEST_CHAIN_A);
        assertFalse(route.active);
        assertEq(route.tokenTransferrer, address(0));
        assertEq(route.destTransferrer, address(0));
        assertEq(route.requiredGasLimit, 0);
    }

    function test_getRoute_returnsCorrectDataAfterRegistration() public {
        _registerRoute();
        ICMBridgeFactory.BridgeRoute memory route = factory.getRoute(address(token), DEST_CHAIN_A);
        assertEq(route.tokenTransferrer, address(transferrer));
        assertEq(route.destTransferrer, DEST_TRANSFERRER);
        assertEq(route.requiredGasLimit, GAS_LIMIT);
        assertTrue(route.active);
    }

    function test_isRouteActive_falseBeforeRegistration() public view {
        assertFalse(factory.isRouteActive(address(token), DEST_CHAIN_A));
    }

    function test_isRouteActive_trueAfterRegistration() public {
        _registerRoute();
        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_A));
    }

    function test_isRouteActive_falseAfterDeregistration() public {
        _registerRoute();
        vm.prank(owner);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        assertFalse(factory.isRouteActive(address(token), DEST_CHAIN_A));
    }

    function test_isRouteActive_trueAfterReregistration() public {
        _registerRoute();
        vm.prank(owner);
        factory.deregisterRoute(address(token), DEST_CHAIN_A);
        _registerRoute();
        assertTrue(factory.isRouteActive(address(token), DEST_CHAIN_A));
    }

    //////////////////////////////////////////////////////////////////////////
    // Fuzz
    //////////////////////////////////////////////////////////////////////////

    function testFuzz_bridge_amountRange(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 5_000_000 * 1e18);
        _registerRoute();
        token.mint(alice, amount);

        vm.startPrank(alice);
        token.approve(address(factory), amount);
        factory.bridge(address(token), amount, DEST_CHAIN_A, bob, address(0), 0);
        vm.stopPrank();

        assertEq(transferrer.lastAmount(), amount);
    }

    function testFuzz_registerRoute_variousBlockchainIds(bytes32 chainId, uint256 gasLimit) public {
        vm.assume(chainId != bytes32(0));
        vm.assume(gasLimit > 0 && gasLimit <= 10_000_000);

        vm.prank(owner);
        factory.registerRoute(address(token), chainId, address(transferrer), DEST_TRANSFERRER, gasLimit);

        assertTrue(factory.isRouteActive(address(token), chainId));
        assertEq(factory.getRoute(address(token), chainId).requiredGasLimit, gasLimit);
    }

    function testFuzz_bridge_feeInBridgeToken(uint128 amount, uint128 fee) public {
        vm.assume(amount > 0);
        vm.assume(fee > 0);
        // Use uint128 to prevent overflow when adding amount + fee
        _registerRoute();
        uint256 total = uint256(amount) + uint256(fee);
        token.mint(alice, total);

        vm.startPrank(alice);
        token.approve(address(factory), total);
        factory.bridge(address(token), uint256(amount), DEST_CHAIN_A, bob, address(token), uint256(fee));
        vm.stopPrank();

        assertEq(transferrer.lastAmount(), uint256(amount));
        assertEq(transferrer.getLastInput().primaryRelayerFee, uint256(fee));
    }

    function testFuzz_bridge_separateFeeToken(uint128 amount, uint128 fee) public {
        vm.assume(amount > 0);
        vm.assume(fee > 0);
        _registerRoute();
        token.mint(alice, uint256(amount));
        feeToken.mint(alice, uint256(fee));

        vm.startPrank(alice);
        token.approve(address(factory), uint256(amount));
        feeToken.approve(address(factory), uint256(fee));
        factory.bridge(address(token), uint256(amount), DEST_CHAIN_A, bob, address(feeToken), uint256(fee));
        vm.stopPrank();

        assertEq(transferrer.lastAmount(), uint256(amount));
    }

    function testFuzz_updateRoute_gasLimitInRange(uint256 newGas) public {
        vm.assume(newGas > 0 && newGas <= 10_000_000);
        _registerRoute();

        vm.prank(owner);
        factory.updateRoute(address(token), DEST_CHAIN_A, address(transferrer), DEST_TRANSFERRER, newGas);

        assertEq(factory.getRoute(address(token), DEST_CHAIN_A).requiredGasLimit, newGas);
    }
}

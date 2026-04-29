// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {AvalancheEscrowFactory} from "../src/AvalancheEscrows/AvalancheEscrowFactory.sol";
import {AvalancheEscrowVault} from "../src/AvalancheEscrows/AvalancheEscrowVault.sol";
import {IICMBridgeFactory} from "../src/interfaces/IICMBridgeFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract XRayToken is ERC20 {
    constructor() ERC20("XRayToken", "XRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract XRayBridgeFactory is IICMBridgeFactory {
    address public lastToken;
    uint256 public lastAmount;
    bytes32 public lastDestBlockchainId;
    address public lastRecipient;
    address public lastFeeToken;
    uint256 public lastRelayerFee;

    function bridge(
        address token,
        uint256 amount,
        bytes32 destBlockchainId,
        address recipient,
        address primaryFeeToken,
        uint256 primaryRelayerFee
    ) external {
        lastToken = token;
        lastAmount = amount;
        lastDestBlockchainId = destBlockchainId;
        lastRecipient = recipient;
        lastFeeToken = primaryFeeToken;
        lastRelayerFee = primaryRelayerFee;

        uint256 pull = primaryFeeToken == token && primaryRelayerFee > 0 ? amount + primaryRelayerFee : amount;
        IERC20(token).transferFrom(msg.sender, address(this), pull);
    }
}

contract XRayInvariantsTest is Test {
    EscrowFactory standardFactory;
    AvalancheEscrowFactory avalancheFactory;
    XRayToken token;
    XRayBridgeFactory bridgeFactory;

    uint256 constant RECIPIENT_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    bytes32 constant DEST_CHAIN_ID =
        bytes32(uint256(0xabc1230000000000000000000000000000000000000000000000000000000000));

    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address recipient;
    address hopRecipient = makeAddr("hopRecipient");

    function setUp() public {
        recipient = vm.addr(RECIPIENT_PK);

        standardFactory = new EscrowFactory(owner);
        avalancheFactory = new AvalancheEscrowFactory(owner);
        token = new XRayToken();
        bridgeFactory = new XRayBridgeFactory();

        vm.startPrank(owner);
        standardFactory.whitelistToken(address(token));
        standardFactory.whitelistToken(standardFactory.NATIVE_TOKEN());
        avalancheFactory.whitelistToken(address(token));
        avalancheFactory.whitelistToken(avalancheFactory.NATIVE_TOKEN());
        vm.stopPrank();
    }

    function test_xrayStandardStateMachineAndEconomicInvariant() public {
        bytes32 preimage = bytes32("standard-secret");
        uint256 amount = 100 ether;
        uint256 donation = 7 ether;
        address vault = _createStandardErc20(preimage, 1 days, amount);

        token.mint(vault, donation);

        uint256 recipientBefore = token.balanceOf(recipient);
        EscrowVault(vault).claim(preimage);

        assertTrue(EscrowVault(vault).s_settled());
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(recipient), recipientBefore + amount + donation);

        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(vault).claim(preimage);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(EscrowVault.EscrowVault__EscrowAlreadySettled.selector);
        EscrowVault(vault).refund();
    }

    function test_xrayStandardTemporalRefundInvariant() public {
        bytes32 preimage = bytes32("standard-timeout");
        uint256 duration = 1 days;
        address vault = _createStandardErc20(preimage, duration, 100 ether);

        vm.expectRevert(EscrowVault.EscrowVault__EscrowNotExpired.selector);
        EscrowVault(vault).refund();

        uint256 creatorBefore = token.balanceOf(creator);
        vm.warp(EscrowVault(vault).s_depositedAt() + duration);
        EscrowVault(vault).refund();

        assertTrue(EscrowVault(vault).s_settled());
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(creator), creatorBefore + 100 ether);
    }

    function test_xrayOversizedDurationCanOverflowRefundDeadline() public {
        bytes32 preimage = bytes32("overflow-duration");
        address standardVault = _createStandardErc20(preimage, type(uint256).max, 1 ether);

        vm.expectRevert(stdError.arithmeticError);
        EscrowVault(standardVault).refund();

        address avalancheVault = _createAvalancheErc20(bytes32("avax-overflow"), type(uint256).max, 1 ether, false);

        vm.expectRevert(stdError.arithmeticError);
        AvalancheEscrowVault(avalancheVault).refund();
    }

    function test_xrayAmountIsNotPartOfDeterministicIdentity() public view {
        bytes32 commitmentHash = sha256(abi.encodePacked(bytes32("same-terms")));

        address standardSmall =
            standardFactory.getEscrowAddress(address(token), creator, recipient, 1 days, commitmentHash, 1);
        address standardLarge =
            standardFactory.getEscrowAddress(address(token), creator, recipient, 1 days, commitmentHash, 100 ether);
        assertEq(standardSmall, standardLarge);

        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: address(token),
            creator: creator,
            recipient: recipient,
            escrowDuration: 1 days,
            commitmentHash: commitmentHash,
            amount: 1,
            l1Hop: false
        });
        address avalancheSmall = avalancheFactory.getEscrowAddress(p);

        p.amount = 100 ether;
        address avalancheLarge = avalancheFactory.getEscrowAddress(p);
        assertEq(avalancheSmall, avalancheLarge);
    }

    function test_xrayAvalancheHopStateMachineAndSignedBridgeFactoryInvariant() public {
        bytes32 preimage = bytes32("hop-secret");
        uint256 amount = 100 ether;
        address vault = _createAvalancheErc20(preimage, 1 days, amount, true);

        AvalancheEscrowVault.HopData memory hopData = AvalancheEscrowVault.HopData({
            bridgeFactory: address(bridgeFactory),
            destBlockchainId: DEST_CHAIN_ID,
            recipient: hopRecipient,
            primaryFeeToken: address(0),
            primaryRelayerFee: 0
        });

        bytes memory signature = _signHopData(vault, sha256(abi.encodePacked(preimage)), hopData);
        AvalancheEscrowVault(vault).claimHop(preimage, signature, hopData);

        assertTrue(AvalancheEscrowVault(vault).s_settled());
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(address(bridgeFactory)), amount);
        assertEq(bridgeFactory.lastToken(), address(token));
        assertEq(bridgeFactory.lastDestBlockchainId(), DEST_CHAIN_ID);
        assertEq(bridgeFactory.lastRecipient(), hopRecipient);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        AvalancheEscrowVault(vault).claim(preimage);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        AvalancheEscrowVault(vault).refund();
    }

    function test_xrayAvalancheNativeTemporalAndEconomicInvariant() public {
        bytes32 preimage = bytes32("avax-native");
        uint256 amount = 10 ether;
        uint256 duration = 1 days;
        address vault = _createAvalancheNative(preimage, duration, amount);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowNotExpired.selector);
        AvalancheEscrowVault(vault).refund();

        uint256 creatorBefore = creator.balance;
        vm.warp(AvalancheEscrowVault(vault).s_depositedAt() + duration);
        AvalancheEscrowVault(vault).refund();

        assertTrue(AvalancheEscrowVault(vault).s_settled());
        assertEq(vault.balance, 0);
        assertEq(creator.balance, creatorBefore + amount);
    }

    function _createStandardErc20(bytes32 preimage, uint256 duration, uint256 amount) internal returns (address vault) {
        bytes32 commitmentHash = sha256(abi.encodePacked(preimage));
        vault = standardFactory.getEscrowAddress(address(token), creator, recipient, duration, commitmentHash, amount);

        token.mint(creator, amount);
        vm.prank(creator);
        token.transfer(vault, amount);

        standardFactory.createEscrow(address(token), creator, recipient, duration, commitmentHash, amount);
    }

    function _createAvalancheErc20(bytes32 preimage, uint256 duration, uint256 amount, bool l1Hop)
        internal
        returns (address vault)
    {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: address(token),
            creator: creator,
            recipient: recipient,
            escrowDuration: duration,
            commitmentHash: sha256(abi.encodePacked(preimage)),
            amount: amount,
            l1Hop: l1Hop
        });
        vault = avalancheFactory.getEscrowAddress(p);

        token.mint(creator, amount);
        vm.prank(creator);
        token.transfer(vault, amount);

        avalancheFactory.createEscrow(p);
    }

    function _createAvalancheNative(bytes32 preimage, uint256 duration, uint256 amount)
        internal
        returns (address vault)
    {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: avalancheFactory.NATIVE_TOKEN(),
            creator: creator,
            recipient: recipient,
            escrowDuration: duration,
            commitmentHash: sha256(abi.encodePacked(preimage)),
            amount: amount,
            l1Hop: false
        });

        vm.deal(creator, amount);
        vm.prank(creator);
        vault = avalancheFactory.createEscrowNative{value: amount}(p);
    }

    function _signHopData(address vault, bytes32 commitmentHash, AvalancheEscrowVault.HopData memory hopData)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 hash = keccak256(
            abi.encode(
                AvalancheEscrowVault(vault).HOP_AUTHORIZATION_TYPEHASH(),
                block.chainid,
                vault,
                commitmentHash,
                hopData.bridgeFactory,
                hopData.destBlockchainId,
                hopData.recipient,
                hopData.primaryFeeToken,
                hopData.primaryRelayerFee
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RECIPIENT_PK, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }
}

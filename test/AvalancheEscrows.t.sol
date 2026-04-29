// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AvalancheEscrowFactory} from "../src/AvalancheEscrows/AvalancheEscrowFactory.sol";
import {AvalancheEscrowVault} from "../src/AvalancheEscrows/AvalancheEscrowVault.sol";
import {IICMBridgeFactory} from "../src/interfaces/IICMBridgeFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

//////////////////////////////////////////////////////////////////////////////
// Test helpers
//////////////////////////////////////////////////////////////////////////////

contract ERC20Impl is ERC20 {
    constructor(string memory name, string memory symbol, address mintTo) ERC20(name, symbol) {
        _mint(mintTo, 100_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC20PermitImpl is ERC20Permit {
    constructor(string memory name, string memory symbol, address mintTo) ERC20Permit(name) ERC20(name, symbol) {
        _mint(mintTo, 100_000_000 * 1e18);
    }
}

/// @notice Contract with no receive/fallback to force native deposit failures.
contract AvalancheNoReceive {}

/// @notice Fee-on-transfer token used to cover post-transfer balance checks.
contract AvalancheFeeOnTransferToken is ERC20 {
    constructor(address mintTo) ERC20("AvalancheFeeToken", "AFT") {
        _mint(mintTo, 100_000_000 * 1e18);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 10;
            super._update(from, to, value - fee);
            super._update(from, address(this), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Records every bridge() call and actually pulls tokens to simulate real factory
contract MockICMBridgeFactory is IICMBridgeFactory {
    address public lastToken;
    uint256 public lastAmount;
    bytes32 public lastDestChain;
    address public lastRecipient;
    address public lastFeeToken;
    uint256 public lastRelayerFee;
    uint256 public callCount;

    bool private _shouldRevert;

    function bridge(
        address token,
        uint256 amount,
        bytes32 destBlockchainId,
        address recipient,
        address primaryFeeToken,
        uint256 primaryRelayerFee
    ) external override {
        if (_shouldRevert) revert("MockBridge: forced revert");

        lastToken = token;
        lastAmount = amount;
        lastDestChain = destBlockchainId;
        lastRecipient = recipient;
        lastFeeToken = primaryFeeToken;
        lastRelayerFee = primaryRelayerFee;
        callCount++;

        // Simulate ICMBridgeFactory pulling tokens from the vault
        uint256 pull = (primaryFeeToken == token && primaryRelayerFee > 0) ? amount + primaryRelayerFee : amount;
        IERC20(token).transferFrom(msg.sender, address(this), pull);
    }

    function setShouldRevert(bool flag) external {
        _shouldRevert = flag;
    }
}

//////////////////////////////////////////////////////////////////////////////
// Main test
//////////////////////////////////////////////////////////////////////////////

contract AvalancheEscrowsTest is Test {
    // Mirror factory event
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed creator,
        address indexed token,
        address recipient,
        bytes32 commitmentHash,
        uint256 escrowDuration,
        uint256 amount,
        bool l1Hop
    );

    // Mirror vault events
    event Claimed(address indexed recipient, bytes32 commitment);
    event ClaimedHop(
        bytes32 commitment, bytes32 indexed destBlockchainId, address indexed hopRecipient, uint256 amount
    );
    event Refunded(address indexed creator, bytes32 commitmentHash);

    AvalancheEscrowFactory factory;
    ERC20Impl token;
    ERC20PermitImpl permitToken;
    MockICMBridgeFactory mockBridge;

    address owner = makeAddr("owner");

    // alice has a known private key for permit / signed tests (creator)
    uint256 constant ALICE_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address alice;

    // bob has a known private key for hop-sig tests (recipient / redeemer)
    uint256 constant BOB_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address bob;

    // hop constants
    bytes32 constant L1_CHAIN_ID = bytes32(uint256(0xabc1230000000000000000000000000000000000000000000000000000000000));
    address constant L1_RECIPIENT = address(0xcafE000000000000000000000000000000000001);

    // HTLC constants
    bytes32 constant PREIMAGE = bytes32(uint256(0xdeadbeef));
    bytes32 immutable COMMITMENT_HASH = sha256(abi.encodePacked(PREIMAGE));
    uint256 constant EXPIRY = 100;
    uint256 constant AMOUNT = 1000 * 1e18;

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);

        vm.prank(owner);
        factory = new AvalancheEscrowFactory(owner);

        token = new ERC20Impl("TestToken", "TT", alice);
        permitToken = new ERC20PermitImpl("PermitToken", "PT", alice);
        mockBridge = new MockICMBridgeFactory();

        vm.startPrank(owner);
        factory.whitelistToken(address(token));
        factory.whitelistToken(address(permitToken));
        factory.whitelistToken(factory.NATIVE_TOKEN());
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////////////////
    // Helpers
    //////////////////////////////////////////////////////////////////////////

    function _p(bool l1Hop) internal view returns (AvalancheEscrowFactory.EscrowParams memory) {
        return AvalancheEscrowFactory.EscrowParams({
            token: address(token),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: l1Hop
        });
    }

    /// @dev Predicts vault address and pre-funds it with tokens
    function _predictAndFund(bool l1Hop) internal returns (address vaultAddr) {
        vaultAddr = factory.getEscrowAddress(_p(l1Hop));
        vm.prank(alice);
        token.transfer(vaultAddr, AMOUNT);
    }

    /// @dev Deploys vault via createEscrow after pre-funding
    function _deployVault(bool l1Hop) internal returns (AvalancheEscrowVault vault) {
        address vaultAddr = _predictAndFund(l1Hop);
        vm.prank(alice);
        factory.createEscrow(_p(l1Hop));
        vault = AvalancheEscrowVault(vaultAddr);
    }

    /// @dev Builds HopData with no relayer fee
    function _hopData() internal view returns (AvalancheEscrowVault.HopData memory) {
        return AvalancheEscrowVault.HopData({
            bridgeFactory: address(mockBridge),
            destBlockchainId: L1_CHAIN_ID,
            recipient: L1_RECIPIENT,
            primaryFeeToken: address(0),
            primaryRelayerFee: 0
        });
    }

    /// @dev Signs HopData as bob (recipient/redeemer) using EIP-191 personal sign.
    ///      chainId and vaultAddr are embedded in the hash for replay protection.
    ///      The recipient signs to authorize the hop destination, preventing frontrunning.
    function _signHopData(address vaultAddr, AvalancheEscrowVault.HopData memory hd)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 hash = keccak256(
            abi.encode(
                AvalancheEscrowVault(vaultAddr).HOP_AUTHORIZATION_TYPEHASH(),
                block.chainid,
                vaultAddr,
                COMMITMENT_HASH,
                hd.bridgeFactory,
                hd.destBlockchainId,
                hd.recipient,
                hd.primaryFeeToken,
                hd.primaryRelayerFee
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_PK, MessageHashUtils.toEthSignedMessageHash(hash));
        sig = abi.encodePacked(r, s, v);
    }

    function _factoryDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            factory.eip712Domain();
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

    function _signCreateParams(uint256 pk, AvalancheEscrowFactory.EscrowParams memory p)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                factory.CREATE_ESCROW_TYPEHASH(),
                p.token,
                p.creator,
                p.recipient,
                p.escrowDuration,
                p.commitmentHash,
                p.amount,
                p.l1Hop
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_factoryDomainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    //////////////////////////////////////////////////////////////////////////
    // AvalancheEscrowFactory — l1Hop = false (standard path)
    //////////////////////////////////////////////////////////////////////////

    function test_createEscrow_noHop_success() public {
        address vaultAddr = _predictAndFund(false);

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(vaultAddr, alice, address(token), bob, COMMITMENT_HASH, EXPIRY, AMOUNT, false);

        vm.prank(alice);
        factory.createEscrow(_p(false));

        assertTrue(factory.s_deployedEscrows(vaultAddr));
        AvalancheEscrowVault vault = AvalancheEscrowVault(vaultAddr);
        (,,,,, bool l1Hop) = vault.getEscrowParameters();
        assertFalse(l1Hop);
    }

    function test_createEscrowPermit_noHop_success() public {
        uint256 deadline = block.timestamp + 1 hours;
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: address(permitToken),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });
        address predictedAddr = factory.getEscrowAddress(p);

        // Build permit signature
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permitToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        alice,
                        address(factory),
                        AMOUNT,
                        permitToken.nonces(alice),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, permitHash);
        bytes memory permitSig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        address vault = factory.createEscrowPermit(p, deadline, permitSig);
        assertEq(vault, predictedAddr);
        assertTrue(factory.s_deployedEscrows(vault));
    }

    function test_createEscrowSigned_noHop_success() public {
        AvalancheEscrowFactory.EscrowParams memory p = _p(false);
        address predictedAddr = factory.getEscrowAddress(p);
        vm.prank(alice);
        token.approve(address(factory), AMOUNT);

        bytes memory sig = _signCreateParams(ALICE_PK, p);

        vm.prank(alice);
        address vault = factory.createEscrowSigned(p, sig);
        assertEq(vault, predictedAddr);
    }

    //////////////////////////////////////////////////////////////////////////
    // AvalancheEscrowFactory — l1Hop = true
    //////////////////////////////////////////////////////////////////////////

    function test_createEscrow_withHop_success() public {
        address vaultAddr = _predictAndFund(true);

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(vaultAddr, alice, address(token), bob, COMMITMENT_HASH, EXPIRY, AMOUNT, true);

        vm.prank(alice);
        factory.createEscrow(_p(true));

        AvalancheEscrowVault vault = AvalancheEscrowVault(vaultAddr);
        (,,,,, bool l1Hop) = vault.getEscrowParameters();
        assertTrue(l1Hop);
    }

    function test_createEscrow_withHop_differentAddressThanNoHop() public view {
        address hopAddr = factory.getEscrowAddress(_p(true));
        address noHopAddr = factory.getEscrowAddress(_p(false));
        assertTrue(hopAddr != noHopAddr, "l1Hop=true and l1Hop=false must produce different addresses");
    }

    function test_createEscrow_withHop_revert_nativeToken() public {
        address nativeToken = factory.NATIVE_TOKEN();
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: nativeToken,
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: true
        });
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__NativeNotSupportedForHop.selector);
        factory.createEscrow(p);
    }

    function test_createEscrowNative_withHop_revert() public {
        address nativeToken = factory.NATIVE_TOKEN();
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: nativeToken,
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: true
        });
        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__NativeNotSupportedForHop.selector);
        factory.createEscrowNative{value: AMOUNT}(p);
    }

    function test_createEscrowNative_noHop_success() public {
        address nativeToken = factory.NATIVE_TOKEN();
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: nativeToken,
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });
        address predictedAddr = factory.getEscrowAddress(p);
        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        address vault = factory.createEscrowNative{value: AMOUNT}(p);
        assertEq(vault, predictedAddr);
        assertEq(vault.balance, AMOUNT);
    }

    function test_nativeVault_claim_success() public {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });

        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        address vault = factory.createEscrowNative{value: AMOUNT}(p);

        uint256 bobBefore = bob.balance;
        AvalancheEscrowVault(vault).claim(PREIMAGE);

        assertEq(bob.balance, bobBefore + AMOUNT);
        assertEq(vault.balance, 0);
        assertTrue(AvalancheEscrowVault(vault).s_settled());
    }

    function test_nativeVault_refund_success() public {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });

        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        address vault = factory.createEscrowNative{value: AMOUNT}(p);

        vm.warp(block.timestamp + EXPIRY);
        uint256 aliceBefore = alice.balance;
        AvalancheEscrowVault(vault).refund();

        assertEq(alice.balance, aliceBefore + AMOUNT);
        assertEq(vault.balance, 0);
        assertTrue(AvalancheEscrowVault(vault).s_settled());
    }

    function test_nativeVault_claim_revert_whenRecipientRejectsNative() public {
        AvalancheNoReceive noReceive = new AvalancheNoReceive();
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: address(noReceive),
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });

        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        address vault = factory.createEscrowNative{value: AMOUNT}(p);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__NativeTransferFailed.selector);
        AvalancheEscrowVault(vault).claim(PREIMAGE);

        assertEq(vault.balance, AMOUNT);
    }

    function test_nativeVault_refund_revert_whenCreatorRejectsNative() public {
        AvalancheNoReceive noReceive = new AvalancheNoReceive();
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: address(noReceive),
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });

        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        address vault = factory.createEscrowNative{value: AMOUNT}(p);

        vm.warp(block.timestamp + EXPIRY);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__NativeTransferFailed.selector);
        AvalancheEscrowVault(vault).refund();

        assertEq(vault.balance, AMOUNT);
    }

    function test_createEscrowBatch_mixedHop() public {
        address vault1Addr = factory.getEscrowAddress(_p(false));

        AvalancheEscrowFactory.EscrowParams memory p2 = AvalancheEscrowFactory.EscrowParams({
            token: address(token),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY + 1,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: true
        });
        address vault2Addr = factory.getEscrowAddress(p2);

        vm.startPrank(alice);
        token.transfer(vault1Addr, AMOUNT);
        token.transfer(vault2Addr, AMOUNT);

        AvalancheEscrowFactory.EscrowParams[] memory params = new AvalancheEscrowFactory.EscrowParams[](2);
        params[0] = _p(false);
        params[1] = p2;

        address[] memory vaults = factory.createEscrowBatch(params);
        vm.stopPrank();

        assertEq(vaults[0], vault1Addr);
        assertEq(vaults[1], vault2Addr);
        (,,,,, bool hop0) = AvalancheEscrowVault(vaults[0]).getEscrowParameters();
        (,,,,, bool hop1) = AvalancheEscrowVault(vaults[1]).getEscrowParameters();
        assertFalse(hop0);
        assertTrue(hop1);
    }

    function test_createEscrow_revert_alreadyDeployed() public {
        _deployVault(false);
        // Factory checks s_deployedEscrows before the balance check, so no re-funding needed
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__EscrowAlreadyDeployed.selector);
        factory.createEscrow(_p(false));
    }

    function test_factory_ownerPauseWhitelistAndDelistBranches() public {
        address newToken = makeAddr("newToken");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AvalancheEscrowFactory.TokenWhitelisted(newToken);
        factory.whitelistToken(newToken);
        assertTrue(factory.s_whitelistedTokens(newToken));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AvalancheEscrowFactory.TokenDelisted(newToken);
        factory.delistToken(newToken);
        assertFalse(factory.s_whitelistedTokens(newToken));

        vm.prank(owner);
        factory.pause();

        address vaultAddr = _predictAndFund(false);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        factory.createEscrow(_p(false));

        vm.prank(owner);
        factory.unpause();

        vm.prank(alice);
        address vault = factory.createEscrow(_p(false));
        assertEq(vault, vaultAddr);
    }

    function test_getEscrowAddress_revert_invalidParams() public {
        AvalancheEscrowFactory.EscrowParams memory p = _p(false);

        p.creator = address(0);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InvalidAddressParameters.selector);
        factory.getEscrowAddress(p);

        p = _p(false);
        p.recipient = address(0);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InvalidAddressParameters.selector);
        factory.getEscrowAddress(p);

        p = _p(false);
        p.recipient = alice;
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InvalidAddressParameters.selector);
        factory.getEscrowAddress(p);

        p = _p(false);
        p.escrowDuration = 0;
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__ZeroEscrowDuration.selector);
        factory.getEscrowAddress(p);

        p = _p(false);
        p.amount = 0;
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__ZeroAmount.selector);
        factory.getEscrowAddress(p);

        p = _p(false);
        p.commitmentHash = bytes32(0);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InvalidCommitmentHash.selector);
        factory.getEscrowAddress(p);

        p = _p(false);
        p.token = makeAddr("unlisted");
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__TokenNotAccepted.selector);
        factory.getEscrowAddress(p);
    }

    function test_createEscrow_prefundedNative_success() public {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });
        address vaultAddr = factory.getEscrowAddress(p);

        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        (bool sent,) = payable(vaultAddr).call{value: AMOUNT}("");
        assertTrue(sent);

        address vault = factory.createEscrow(p);
        assertEq(vault, vaultAddr);
        assertEq(vault.balance, AMOUNT);
    }

    function test_createEscrow_revert_tokenNotAcceptedAndInsufficientFunds() public {
        AvalancheEscrowFactory.EscrowParams memory p = _p(false);
        p.token = makeAddr("unlisted");
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__TokenNotAccepted.selector);
        factory.createEscrow(p);

        p = _p(false);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InsufficientFundsDeposited.selector);
        factory.createEscrow(p);

        p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("native-insufficient"),
            amount: AMOUNT,
            l1Hop: false
        });
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InsufficientFundsDeposited.selector);
        factory.createEscrow(p);
    }

    function test_createEscrowBatch_revert_emptyInvalidAndAlreadyDeployed() public {
        AvalancheEscrowFactory.EscrowParams[] memory empty = new AvalancheEscrowFactory.EscrowParams[](0);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__EmptyBatch.selector);
        factory.createEscrowBatch(empty);

        AvalancheEscrowFactory.EscrowParams memory valid = _p(false);
        address validAddr = factory.getEscrowAddress(valid);
        vm.prank(alice);
        token.transfer(validAddr, AMOUNT);

        AvalancheEscrowFactory.EscrowParams[] memory params = new AvalancheEscrowFactory.EscrowParams[](2);
        params[0] = valid;
        params[1] = _p(false);
        params[1].token = makeAddr("unlisted");

        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__TokenNotAccepted.selector);
        factory.createEscrowBatch(params);

        _deployVault(false);
        params = new AvalancheEscrowFactory.EscrowParams[](1);
        params[0] = _p(false);

        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__EscrowAlreadyDeployed.selector);
        factory.createEscrowBatch(params);
    }

    function test_createEscrowBatch_nativeSuccessAndReverts() public {
        AvalancheEscrowFactory.EscrowParams memory nativeP = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("batch-native"),
            amount: AMOUNT,
            l1Hop: false
        });
        address nativeAddr = factory.getEscrowAddress(nativeP);

        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        (bool sent,) = payable(nativeAddr).call{value: AMOUNT}("");
        assertTrue(sent);

        AvalancheEscrowFactory.EscrowParams[] memory params = new AvalancheEscrowFactory.EscrowParams[](1);
        params[0] = nativeP;
        address[] memory vaults = factory.createEscrowBatch(params);
        assertEq(vaults[0], nativeAddr);

        nativeP.commitmentHash = sha256("batch-native-hop");
        nativeP.l1Hop = true;
        params[0] = nativeP;
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__NativeNotSupportedForHop.selector);
        factory.createEscrowBatch(params);

        nativeP.commitmentHash = sha256("batch-native-insufficient");
        nativeP.l1Hop = false;
        params[0] = nativeP;
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InsufficientFundsDeposited.selector);
        factory.createEscrowBatch(params);
    }

    function test_createEscrowNative_revert_validationBranches() public {
        AvalancheEscrowFactory.EscrowParams memory p = _p(false);
        vm.deal(alice, AMOUNT);
        vm.prank(alice);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__OnlyNativeTokenAllowed.selector);
        factory.createEscrowNative{value: AMOUNT}(p);

        p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("native-msg-value"),
            amount: AMOUNT,
            l1Hop: false
        });
        vm.prank(alice);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__MsgValueAmountMismatch.selector);
        factory.createEscrowNative{value: AMOUNT - 1}(p);

        address nativeToken = factory.NATIVE_TOKEN();
        vm.prank(owner);
        factory.delistToken(nativeToken);

        vm.prank(alice);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__TokenNotAccepted.selector);
        factory.createEscrowNative{value: AMOUNT}(p);
    }

    function test_createEscrowNative_revert_duplicateAndDepositFailed() public {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("native-duplicate"),
            amount: AMOUNT,
            l1Hop: false
        });
        vm.deal(alice, AMOUNT * 2);

        vm.prank(alice);
        factory.createEscrowNative{value: AMOUNT}(p);

        vm.prank(alice);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__EscrowAlreadyDeployed.selector);
        factory.createEscrowNative{value: AMOUNT}(p);

        p.commitmentHash = sha256("native-deposit-failed");
        address predicted = factory.getEscrowAddress(p);
        AvalancheNoReceive noReceive = new AvalancheNoReceive();
        vm.etch(predicted, address(noReceive).code);

        vm.prank(alice);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__NativeDepositFailed.selector);
        factory.createEscrowNative{value: AMOUNT}(p);
    }

    function test_createEscrowPermit_revert_branches() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        uint256 deadline = block.timestamp + 1 hours;

        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("permit-native"),
            amount: AMOUNT,
            l1Hop: false
        });
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__OnlyERC20Allowed.selector);
        factory.createEscrowPermit(p, deadline, sig);

        p = _p(false);
        p.token = makeAddr("unlisted-permit");
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__TokenNotAccepted.selector);
        factory.createEscrowPermit(p, deadline, sig);

        p = _p(false);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__PermitFailed.selector);
        factory.createEscrowPermit(p, deadline, sig);
    }

    function test_createEscrowSigned_revert_branches() public {
        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: factory.NATIVE_TOKEN(),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("signed-native"),
            amount: AMOUNT,
            l1Hop: false
        });
        bytes memory sig = _signCreateParams(ALICE_PK, p);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__OnlyERC20Allowed.selector);
        factory.createEscrowSigned(p, sig);

        p = _p(false);
        p.token = makeAddr("unlisted-signed");
        sig = _signCreateParams(ALICE_PK, p);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__TokenNotAccepted.selector);
        factory.createEscrowSigned(p, sig);

        p = _p(false);
        sig = _signCreateParams(BOB_PK, p);
        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InvalidSignature.selector);
        factory.createEscrowSigned(p, sig);
    }

    function test_createEscrowSigned_revert_feeOnTransferInsufficientAfterTransfer() public {
        AvalancheFeeOnTransferToken feeToken = new AvalancheFeeOnTransferToken(alice);
        vm.prank(owner);
        factory.whitelistToken(address(feeToken));

        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: address(feeToken),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: sha256("signed-fee-token"),
            amount: AMOUNT,
            l1Hop: false
        });
        bytes memory sig = _signCreateParams(ALICE_PK, p);

        vm.prank(alice);
        feeToken.approve(address(factory), AMOUNT);

        vm.expectRevert(AvalancheEscrowFactory.AvalancheEscrowFactory__InsufficientFundsDeposited.selector);
        factory.createEscrowSigned(p, sig);
    }

    //////////////////////////////////////////////////////////////////////////
    // AvalancheEscrowVault — claim() (l1Hop = false)
    //////////////////////////////////////////////////////////////////////////

    function test_claim_success() public {
        AvalancheEscrowVault vault = _deployVault(false);
        uint256 bobBefore = token.balanceOf(bob);

        vm.expectEmit(true, false, false, true);
        emit Claimed(bob, PREIMAGE);

        vault.claim(PREIMAGE);

        assertEq(token.balanceOf(bob), bobBefore + AMOUNT);
        assertTrue(vault.s_settled());
    }

    function test_claim_revert_isHopEscrow() public {
        AvalancheEscrowVault vault = _deployVault(true);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__IsHopEscrow.selector);
        vault.claim(PREIMAGE);
    }

    function test_claim_revert_invalidCommitment() public {
        AvalancheEscrowVault vault = _deployVault(false);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__InvalidCommitment.selector);
        vault.claim(bytes32(uint256(0xbadbeef)));
    }

    function test_claim_revert_alreadySettled() public {
        AvalancheEscrowVault vault = _deployVault(false);
        vault.claim(PREIMAGE);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        vault.claim(PREIMAGE);
    }

    //////////////////////////////////////////////////////////////////////////
    // AvalancheEscrowVault — claimHop() (l1Hop = true)
    //////////////////////////////////////////////////////////////////////////

    function test_claimHop_success_noFee() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);

        vm.expectEmit(false, true, true, true);
        emit ClaimedHop(PREIMAGE, L1_CHAIN_ID, L1_RECIPIENT, AMOUNT);

        vault.claimHop(PREIMAGE, sig, hd);

        assertTrue(vault.s_settled());
        // Bridge factory was called with correct params
        assertEq(mockBridge.callCount(), 1);
        assertEq(mockBridge.lastToken(), address(token));
        assertEq(mockBridge.lastAmount(), AMOUNT);
        assertEq(mockBridge.lastDestChain(), L1_CHAIN_ID);
        assertEq(mockBridge.lastRecipient(), L1_RECIPIENT);
        assertEq(mockBridge.lastFeeToken(), address(0));
        assertEq(mockBridge.lastRelayerFee(), 0);
        // Tokens moved from vault to mock bridge
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(mockBridge)), AMOUNT);
    }

    function test_claimHop_success_feeInBridgeToken() public {
        AvalancheEscrowVault vault = _deployVault(true);
        uint256 fee = 10 * 1e18;

        AvalancheEscrowVault.HopData memory hd = AvalancheEscrowVault.HopData({
            bridgeFactory: address(mockBridge),
            destBlockchainId: L1_CHAIN_ID,
            recipient: L1_RECIPIENT,
            primaryFeeToken: address(token),
            primaryRelayerFee: fee
        });
        bytes memory sig = _signHopData(address(vault), hd);

        vault.claimHop(PREIMAGE, sig, hd);

        // Net amount = AMOUNT - fee
        assertEq(mockBridge.lastAmount(), AMOUNT - fee);
        assertEq(mockBridge.lastFeeToken(), address(token));
        assertEq(mockBridge.lastRelayerFee(), fee);
        // Bridge factory pulls AMOUNT - fee + fee = AMOUNT total
        assertEq(token.balanceOf(address(mockBridge)), AMOUNT);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_claimHop_success_bridgeTokenWithZeroFee() public {
        AvalancheEscrowVault vault = _deployVault(true);

        AvalancheEscrowVault.HopData memory hd = AvalancheEscrowVault.HopData({
            bridgeFactory: address(mockBridge),
            destBlockchainId: L1_CHAIN_ID,
            recipient: L1_RECIPIENT,
            primaryFeeToken: address(token),
            primaryRelayerFee: 0
        });
        bytes memory sig = _signHopData(address(vault), hd);

        vault.claimHop(PREIMAGE, sig, hd);

        assertEq(mockBridge.lastAmount(), AMOUNT);
        assertEq(mockBridge.lastFeeToken(), address(token));
        assertEq(mockBridge.lastRelayerFee(), 0);
        assertEq(token.balanceOf(address(mockBridge)), AMOUNT);
    }

    function test_claimHop_revert_notHopEscrow() public {
        AvalancheEscrowVault vault = _deployVault(false);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__NotHopEscrow.selector);
        vault.claimHop(PREIMAGE, sig, hd);
    }

    function test_claimHop_revert_invalidCommitment() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__InvalidCommitment.selector);
        vault.claimHop(bytes32(uint256(0xbad)), sig, hd);
    }

    function test_claimHop_revert_invalidSignature_wrongSigner() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory hd = _hopData();

        // Sign with alice's key (creator) instead of bob's (recipient) — should fail
        bytes32 hash = keccak256(
            abi.encode(
                vault.HOP_AUTHORIZATION_TYPEHASH(),
                block.chainid,
                address(vault),
                COMMITMENT_HASH,
                hd.bridgeFactory,
                hd.destBlockchainId,
                hd.recipient,
                hd.primaryFeeToken,
                hd.primaryRelayerFee
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, MessageHashUtils.toEthSignedMessageHash(hash));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__InvalidHopSignature.selector);
        vault.claimHop(PREIMAGE, sig, hd);
    }

    function test_claimHop_revert_invalidSignature_tamperedHopData() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory originalHd = _hopData();
        bytes memory sig = _signHopData(address(vault), originalHd);

        // Tamper recipient after signing
        AvalancheEscrowVault.HopData memory tamperedHd = originalHd;
        tamperedHd.recipient = makeAddr("attacker");

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__InvalidHopSignature.selector);
        vault.claimHop(PREIMAGE, sig, tamperedHd);
    }

    function test_claimHop_revert_alreadySettled() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);

        vault.claimHop(PREIMAGE, sig, hd);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        vault.claimHop(PREIMAGE, sig, hd);
    }

    function test_claimHop_revert_unsupportedFeeToken() public {
        AvalancheEscrowVault vault = _deployVault(true);
        address otherToken = makeAddr("otherToken");

        AvalancheEscrowVault.HopData memory hd = AvalancheEscrowVault.HopData({
            bridgeFactory: address(mockBridge),
            destBlockchainId: L1_CHAIN_ID,
            recipient: L1_RECIPIENT,
            primaryFeeToken: otherToken, // separate token — not supported
            primaryRelayerFee: 1e18
        });
        bytes memory sig = _signHopData(address(vault), hd);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__UnsupportedFeeToken.selector);
        vault.claimHop(PREIMAGE, sig, hd);
    }

    function test_claimHop_revert_feeExceedsBalance() public {
        AvalancheEscrowVault vault = _deployVault(true);

        AvalancheEscrowVault.HopData memory hd = AvalancheEscrowVault.HopData({
            bridgeFactory: address(mockBridge),
            destBlockchainId: L1_CHAIN_ID,
            recipient: L1_RECIPIENT,
            primaryFeeToken: address(token),
            primaryRelayerFee: AMOUNT + 1 // fee >= balance
        });
        bytes memory sig = _signHopData(address(vault), hd);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__InsufficientBalanceForFee.selector);
        vault.claimHop(PREIMAGE, sig, hd);
    }

    function test_claimHop_revert_bridgeFactoryReverts() public {
        AvalancheEscrowVault vault = _deployVault(true);
        mockBridge.setShouldRevert(true);

        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);

        vm.expectRevert("MockBridge: forced revert");
        vault.claimHop(PREIMAGE, sig, hd);

        // Settlement should not have occurred
        assertFalse(vault.s_settled());
    }

    //////////////////////////////////////////////////////////////////////////
    // AvalancheEscrowVault — refund()
    //////////////////////////////////////////////////////////////////////////

    function test_refund_noHop_success() public {
        AvalancheEscrowVault vault = _deployVault(false);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.warp(block.timestamp + EXPIRY);

        vm.expectEmit(true, false, false, true);
        emit Refunded(alice, COMMITMENT_HASH);

        vault.refund();

        assertEq(token.balanceOf(alice), aliceBefore + AMOUNT);
        assertTrue(vault.s_settled());
    }

    function test_refund_hop_success() public {
        AvalancheEscrowVault vault = _deployVault(true);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.warp(block.timestamp + EXPIRY);
        vault.refund();

        assertEq(token.balanceOf(alice), aliceBefore + AMOUNT);
        assertTrue(vault.s_settled());
    }

    function test_refund_revert_notExpired() public {
        AvalancheEscrowVault vault = _deployVault(false);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowNotExpired.selector);
        vault.refund();
    }

    function test_refund_revert_alreadySettled_afterClaim() public {
        AvalancheEscrowVault vault = _deployVault(false);
        vault.claim(PREIMAGE);
        vm.warp(block.timestamp + EXPIRY);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        vault.refund();
    }

    function test_refund_revert_alreadySettled_afterClaimHop() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);
        vault.claimHop(PREIMAGE, sig, hd);

        vm.warp(block.timestamp + EXPIRY);
        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        vault.refund();
    }

    //////////////////////////////////////////////////////////////////////////
    // Mutual exclusivity
    //////////////////////////////////////////////////////////////////////////

    function test_claim_afterHopClaim_reverts() public {
        AvalancheEscrowVault vault = _deployVault(true);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);
        vault.claimHop(PREIMAGE, sig, hd);

        vm.expectRevert(AvalancheEscrowVault.AvalancheEscrowVault__EscrowAlreadySettled.selector);
        vault.claim(PREIMAGE);
    }

    //////////////////////////////////////////////////////////////////////////
    // Fuzz
    //////////////////////////////////////////////////////////////////////////

    function testFuzz_claimHop_amountRange(uint128 rawAmount) public {
        vm.assume(rawAmount > 0);
        uint256 amount = uint256(rawAmount);

        // Mint to alice so she always has enough regardless of fuzz value
        token.mint(alice, amount);

        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: address(token),
            creator: alice,
            recipient: bob,
            escrowDuration: EXPIRY,
            commitmentHash: COMMITMENT_HASH,
            amount: amount,
            l1Hop: true
        });
        address vaultAddr = factory.getEscrowAddress(p);
        vm.prank(alice);
        token.transfer(vaultAddr, amount);
        vm.prank(alice);
        factory.createEscrow(p);

        AvalancheEscrowVault vault = AvalancheEscrowVault(vaultAddr);
        AvalancheEscrowVault.HopData memory hd = _hopData();
        bytes memory sig = _signHopData(address(vault), hd);

        vault.claimHop(PREIMAGE, sig, hd);

        assertEq(mockBridge.lastAmount(), amount);
        assertTrue(vault.s_settled());
    }

    function testFuzz_refund_atExactExpiry(uint64 escrowDuration) public {
        vm.assume(escrowDuration > 0 && escrowDuration <= 50_000);

        AvalancheEscrowFactory.EscrowParams memory p = AvalancheEscrowFactory.EscrowParams({
            token: address(token),
            creator: alice,
            recipient: bob,
            escrowDuration: escrowDuration,
            commitmentHash: COMMITMENT_HASH,
            amount: AMOUNT,
            l1Hop: false
        });
        address vaultAddr = factory.getEscrowAddress(p);
        vm.prank(alice);
        token.transfer(vaultAddr, AMOUNT);
        vm.prank(alice);
        factory.createEscrow(p);

        AvalancheEscrowVault vault = AvalancheEscrowVault(vaultAddr);
        uint256 deposited = vault.s_depositedAt();

        vm.warp(deposited + escrowDuration);
        vault.refund(); // should not revert
        assertTrue(vault.s_settled());
    }

    function testFuzz_l1Hop_differentSalt(bytes32 commitmentHash) public view {
        vm.assume(commitmentHash != bytes32(0));
        address hopAddr = factory.getEscrowAddress(
            AvalancheEscrowFactory.EscrowParams({
                token: address(token),
                creator: alice,
                recipient: bob,
                escrowDuration: EXPIRY,
                commitmentHash: commitmentHash,
                amount: AMOUNT,
                l1Hop: true
            })
        );
        address noHopAddr = factory.getEscrowAddress(
            AvalancheEscrowFactory.EscrowParams({
                token: address(token),
                creator: alice,
                recipient: bob,
                escrowDuration: EXPIRY,
                commitmentHash: commitmentHash,
                amount: AMOUNT,
                l1Hop: false
            })
        );
        assertTrue(hopAddr != noHopAddr);
    }
}

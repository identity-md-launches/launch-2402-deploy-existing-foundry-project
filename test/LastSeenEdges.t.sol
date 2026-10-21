// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {LastSeenQuestions} from "../src/LastSeenQuestions.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {MockIMD, MockIntake} from "./LastSeenRegistry.t.sol";

/// Shared fixture: the launch's constructor arguments for everything but the two contracts that need a local
/// stand-in (the Intake and IMD), and a signer key in place of the oracle's.
abstract contract LastSeenFixture is Test {
    MockIMD imd;
    MockIntake intake;
    LastSeenRegistry reg;
    uint256 attesterKey = 0xA11CE;
    address victim = address(0xC652);
    address sweeper = address(0xEF94);
    address hunter = address(0xB0B);
    address deposit = address(0xDE90);
    uint256 constant PRICE = 0.5 ether;
    bytes32 constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    uint256 nonce;

    function setUp() public virtual {
        imd = new MockIMD();
        intake = new MockIntake();
        reg = new LastSeenRegistry(address(this), intake, ACTION, IERC20(address(imd)), PRICE, vm.addr(attesterKey));
        imd.mint(address(this), 1000 ether);
        imd.mint(hunter, 10 ether);
        imd.approve(address(reg), type(uint256).max);
        vm.prank(hunter);
        imd.approve(address(reg), type(uint256).max);
    }

    function _digest(OracleAttestation.Attestation memory a, address verifying) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                verifying
            )
        );
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    OracleAttestation.TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, _digest(a, address(reg)));
        return abi.encodePacked(r, s, v);
    }

    /// The oracle's questionHash for a pinned body: the members without the panel suffix, closed with "}".
    function _questionHash(bytes memory body) internal pure returns (bytes32) {
        bytes memory suffix = bytes(',"panelSize":5,"quorum":4,"validForSeconds":86400}');
        bytes memory members = new bytes(body.length - suffix.length);
        for (uint256 i; i < members.length; i++) {
            members[i] = body[i];
        }
        return keccak256(bytes.concat(members, "}"));
    }

    function _answer(bytes32 req, bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++nonce);
        a.chainId = 8453;
        a.questionHash = _questionHash(intake.bodyOf(req));
        a.answer = abi.encode(yes);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _deliver(bytes32 req, bool yes) internal {
        OracleAttestation.Attestation memory a = _answer(req, yes);
        intake.deliver(address(reg), req, a, _sign(a));
    }

    function _status(uint256 id) internal view returns (LastSeenRegistry.Status status) {
        (,,,,,,, status,) = reg.getCase(id);
    }

    function _bounty(uint256 id) internal view returns (uint256 bounty) {
        (,,,,,,,, bounty) = reg.getCase(id);
    }

    function _checks(uint256 id) internal view returns (uint256 checks) {
        (,,, checks,) = reg.hunts(id);
    }

    function _inFlight(uint256 id) internal view returns (uint32 inFlight) {
        (,, inFlight,,) = reg.hunts(id);
    }

    function _open() internal returns (uint256) {
        return reg.openCase(victim, sweeper, 8453, 100, 200);
    }

    function _confirmed() internal returns (uint256 id) {
        id = _open();
        _deliver(reg.requestVerdict(id), true);
    }
}

/// Failure paths and boundaries the original suite does not reach.
contract LastSeenEdgesTest is LastSeenFixture {
    // ---------------------------------------------------------------- constructor

    function test_constructorRefusesZeroOwner() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        new LastSeenRegistry(address(0), intake, ACTION, IERC20(address(imd)), PRICE, vm.addr(attesterKey));
    }

    function test_constructorStoresTheLaunchArguments() public {
        address owner_ = address(0x0A11);
        LastSeenRegistry r = new LastSeenRegistry(
            owner_,
            IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82),
            ACTION,
            IERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127),
            500000000000000000,
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982
        );
        assertEq(r.owner(), owner_);
        assertEq(address(r.intake()), 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(r.action(), bytes32("oracle.request@oracle-1"));
        assertEq(address(r.asset()), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        assertEq(r.price(), 0.5 ether);
        assertEq(r.attester(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(r.auditFee(), 0.5 ether);
        assertEq(r.panelSize(), 5);
        assertEq(r.quorum(), 4);
        assertEq(r.pool(), 0);
        (uint256 cases, uint256 leads, uint256 audits) = r.counts();
        assertEq(cases + leads + audits, 0);
        uint64[5] memory on = [uint64(1), 56, 4663, 8453, 42161];
        for (uint256 i; i < on.length; i++) {
            assertTrue(r.supportedChain(on[i]));
        }
        assertFalse(r.supportedChain(0));
        assertFalse(r.supportedChain(10));
        assertFalse(r.supportedChain(11155111));
    }

    // ---------------------------------------------------------------- openCase

    function test_openCaseRefusesBadInput() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(address(0), sweeper, 8453, 100, 200);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, address(0), 8453, 100, 200);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, victim, 8453, 100, 200);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, sweeper, 8453, 200, 200); // empty window
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, sweeper, 8453, 201, 200);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, sweeper, 0, 100, 200);
        // the smallest window is one block wide
        uint256 id = reg.openCase(victim, sweeper, 8453, 199, 200);
        assertEq(id, 0);
    }

    function test_openCaseRecordsEverything() public {
        vm.prank(hunter);
        uint256 id = reg.openCase(victim, sweeper, 4663, 7, type(uint64).max);
        (
            address wallet,
            address suspect,
            address opener,
            uint64 chainId,
            uint64 fromBlock,
            uint64 toBlock,
            uint64 askedAt,
            LastSeenRegistry.Status status,
            uint256 bounty
        ) = reg.getCase(id);
        assertEq(wallet, victim);
        assertEq(suspect, sweeper);
        assertEq(opener, hunter);
        assertEq(chainId, 4663);
        assertEq(fromBlock, 7);
        assertEq(toBlock, type(uint64).max);
        assertEq(askedAt, 0);
        assertEq(uint8(status), uint8(LastSeenRegistry.Status.Open));
        assertEq(bounty, 0);
    }

    function test_chainSwitchedOffRefusesNewCasesAndAudits() public {
        reg.setSupportedChain(8453, false);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        _open();
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.requestAudit(8453, address(0x70CE));
        reg.setSupportedChain(10, true);
        reg.openCase(victim, sweeper, 10, 1, 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_openCaseAcceptsExactlyTheValidInputs(
        address wallet,
        address suspect,
        uint8 chainPick,
        uint64 fromBlock,
        uint64 toBlock
    ) public {
        uint64[7] memory chains = [uint64(1), 56, 4663, 8453, 42161, 10, 0];
        uint64 chainId = chains[chainPick % 7];
        bool valid = wallet != address(0) && suspect != address(0) && wallet != suspect && chainPick % 7 < 5
            && fromBlock < toBlock;
        if (!valid) vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(wallet, suspect, chainId, fromBlock, toBlock);
        (uint256 cases,,) = reg.counts();
        assertEq(cases, valid ? 1 : 0);
    }

    // ---------------------------------------------------------------- requestVerdict

    function test_requestVerdictUnknownCaseReverts() public {
        vm.expectRevert(); // array index out of bounds
        reg.requestVerdict(0);
    }

    function test_requestVerdictRetryBoundaryIsOneDay() public {
        uint256 id = _open();
        uint256 t0 = block.timestamp;
        reg.requestVerdict(id);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.requestVerdict(id); // asked twice in a row
        vm.warp(t0 + 1 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.requestVerdict(id); // exactly one day is not yet late
        vm.warp(t0 + 1 days + 1);
        reg.requestVerdict(id);
        assertEq(intake.n(), 2);
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
    }

    function test_settledCaseCannotBeAskedAgain() public {
        uint256 yes = _confirmed();
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.requestVerdict(yes);

        uint256 no = _open();
        _deliver(reg.requestVerdict(no), false);
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.requestVerdict(no);
        assertEq(uint8(_status(no)), uint8(LastSeenRegistry.Status.Rejected));
    }

    function test_poolShortOfThePriceChargesTheCallerAndIsKept() public {
        reg.donate(PRICE - 1);
        uint256 id = _open();
        uint256 before = imd.balanceOf(address(this));
        reg.requestVerdict(id);
        assertEq(reg.pool(), PRICE - 1);
        assertEq(imd.balanceOf(address(this)), before - PRICE);
    }

    function test_callerWithoutFundsCannotAskWhenThePoolIsEmpty() public {
        address stranger = address(0x5);
        vm.startPrank(stranger);
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        vm.expectRevert(); // the ERC-20 pull fails
        reg.requestVerdict(id);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(LastSeenRegistry.Status.Open));
    }

    function test_verdictBodyIsPinnedToTheCase() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        (bytes memory body, bytes32 h) = new LastSeenQuestions().build(1, victim, sweeper, 8453, 100, 200, 5, 4, "");
        assertEq(keccak256(intake.bodyOf(req)), keccak256(body));
        assertEq(_questionHash(body), h);
        assertTrue(h != bytes32(0));
    }

    // ---------------------------------------------------------------- the callback

    function test_answerToAnUnknownRequestReverts() public {
        uint256 id = _open();
        OracleAttestation.Attestation memory a = _answer(reg.requestVerdict(id), true);
        bytes memory sig = _sign(a);
        vm.expectRevert(LastSeenRegistry.UnknownRequest.selector);
        intake.deliver(address(reg), keccak256("never asked"), a, sig);
    }

    function test_expiredAttestationRefusedAndBoundaryAccepted() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, true);
        bytes memory sig = _sign(a);
        vm.warp(a.expiresAt + 1);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        vm.warp(a.expiresAt); // still valid at the last second
        intake.deliver(address(reg), req, a, sig);
        assertTrue(reg.flagged(sweeper));
    }

    function test_nonBoolAnswerTypeRefused() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, true);
        a.answerType = 3;
        a.answer = abi.encode(uint256(1));
        bytes memory sig = _sign(a);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        assertEq(uint8(_status(id)), uint8(LastSeenRegistry.Status.Asked));
    }

    function test_malformedBoolAnswerReverts() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, true);
        a.answer = abi.encode(uint256(2)); // not a bool
        bytes memory sig = _sign(a);
        vm.expectRevert();
        intake.deliver(address(reg), req, a, sig);
        a.answer = hex"01"; // too short
        sig = _sign(a);
        vm.expectRevert();
        intake.deliver(address(reg), req, a, sig);
        assertFalse(reg.flagged(sweeper));
    }

    function test_panelSmallerThanConfiguredRefused() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, true);
        a.panelSize = 4;
        a.quorum = 4;
        a.agreed = 4;
        bytes memory sig = _sign(a);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
    }

    function test_raisedPanelAppliesToAnswers() public {
        reg.setPanel(7, 5);
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        // the body asked for the new panel
        bytes memory body = intake.bodyOf(req);
        bytes memory suffix = bytes(',"panelSize":7,"quorum":5,"validForSeconds":86400}');
        for (uint256 i; i < suffix.length; i++) {
            assertEq(body[body.length - suffix.length + i], suffix[i]);
        }
        bytes memory members = new bytes(body.length - suffix.length);
        for (uint256 i; i < members.length; i++) {
            members[i] = body[i];
        }
        OracleAttestation.Attestation memory a = _answer(req, true);
        a.questionHash = keccak256(bytes.concat(members, "}")); // the panel is not part of the question
        bytes memory sig = _sign(a); // panel 5: smaller than asked
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        intake.deliver(address(reg), req, a, _sign(a));
        assertTrue(reg.flagged(sweeper));
    }

    function test_tamperedFieldsBreakTheSignature() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, false);
        bytes memory sig = _sign(a);
        // flip the answer after signing
        a.answer = abi.encode(true);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        a.answer = abi.encode(false);
        // every other signed field, one at a time
        for (uint256 f; f < 10; f++) {
            OracleAttestation.Attestation memory t = _copy(a);
            if (f == 0) t.requestId = bytes32(uint256(999));
            if (f == 1) t.chainId = 1;
            if (f == 2) t.figure = 1;
            if (f == 3) t.fromBlock = 101;
            if (f == 4) t.toBlock = 201;
            if (f == 5) t.blockHash = bytes32(uint256(1));
            if (f == 6) t.panelJobId = bytes32(uint256(1));
            if (f == 7) t.agreed = 4;
            if (f == 8) t.issuedAt = a.issuedAt - 1;
            if (f == 9) t.expiresAt = a.expiresAt + 1;
            vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
            intake.deliver(address(reg), req, t, sig);
        }
        intake.deliver(address(reg), req, a, sig);
        assertEq(uint8(_status(id)), uint8(LastSeenRegistry.Status.Rejected));
    }

    function _copy(OracleAttestation.Attestation memory a)
        internal
        pure
        returns (OracleAttestation.Attestation memory)
    {
        return abi.decode(abi.encode(a), (OracleAttestation.Attestation));
    }

    function test_badSignatureEncodingsRefused() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, _digest(a, address(reg)));
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, abi.encodePacked(r, s)); // 64 bytes
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, abi.encodePacked(r, s, v, uint8(0))); // 66 bytes
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, abi.encodePacked(r, s, uint8(v - 27))); // v as 0/1
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, "");
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        intake.deliver(address(reg), req, a, abi.encodePacked(r, s, v));
        assertTrue(reg.flagged(sweeper));
    }

    function test_attesterRotationRefusesTheOldKey() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        OracleAttestation.Attestation memory a = _answer(req, true);
        bytes memory oldSig = _sign(a);
        reg.setOracle(intake, ACTION, IERC20(address(imd)), PRICE, vm.addr(0xB0B0));
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, oldSig);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B0, _digest(a, address(reg)));
        intake.deliver(address(reg), req, a, abi.encodePacked(r, s, v));
        assertTrue(reg.flagged(sweeper));
    }

    function test_intakeRotationStrandsOldRequestsUntilRetry() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        MockIntake next = new MockIntake();
        reg.setOracle(next, ACTION, IERC20(address(imd)), PRICE, vm.addr(attesterKey));
        OracleAttestation.Attestation memory a = _answer(req, true);
        bytes memory sig = _sign(a);
        vm.expectRevert(LastSeenRegistry.NotIntake.selector);
        intake.deliver(address(reg), req, a, sig);
        vm.warp(block.timestamp + 1 days + 1);
        bytes32 req2 = reg.requestVerdict(id);
        assertEq(next.n(), 1);
        OracleAttestation.Attestation memory b = _answer(req, true);
        b.questionHash = _questionHash(next.bodyOf(req2));
        next.deliver(address(reg), req2, b, _sign(b));
        assertTrue(reg.flagged(sweeper));
    }

    /// The heaviest callback (a confirmed hop that pays a hunter) fits inside the 200,000 gas the Intake gives it.
    function test_heaviestCallbackFitsTheStipend() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 8 ether, 2, 0, 30);
        vm.prank(hunter);
        (, bytes32 req) = reg.submitLead(id, sweeper, deposit);
        OracleAttestation.Attestation memory a = _answer(req, true);
        bytes memory sig = _sign(a);
        uint256 g = gasleft();
        intake.deliver(address(reg), req, a, sig); // forwards exactly 200,000
        assertLt(g - gasleft(), 200_000);
        assertTrue(reg.reached(id, deposit));
        assertEq(imd.balanceOf(hunter), 10 ether + 2 ether);
    }

    // ---------------------------------------------------------------- postBounty / fundBounty

    function test_postBountyBoundaries() public {
        uint256 id = _open();
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.postBounty(id, 1 ether, 1, 0, 6);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.postBounty(id, 1 ether, 1, 0, 366);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.postBounty(id, 1 ether, 0, 0, 30);
        uint256 t0 = block.timestamp;
        reg.postBounty(id, 1 ether, 1, bytes32("k1"), 7);
        (address hirer, uint64 openUntil,, uint256 checks, bytes32 tipKey) = reg.hunts(id);
        assertEq(hirer, address(this));
        assertEq(openUntil, t0 + 7 days);
        assertEq(checks, PRICE);
        assertEq(tipKey, bytes32("k1"));
        // the hirer tops up with no new checks, a zero key (kept) and a longer window
        reg.postBounty(id, 2 ether, 0, 0, 365);
        (, openUntil,, checks, tipKey) = reg.hunts(id);
        assertEq(openUntil, t0 + 365 days);
        assertEq(checks, PRICE);
        assertEq(tipKey, bytes32("k1"));
        assertEq(_bounty(id), 3 ether);
        // a shorter top-up never shortens the hunt
        reg.postBounty(id, 0, 1, bytes32("k2"), 7);
        (, openUntil,, checks, tipKey) = reg.hunts(id);
        assertEq(openUntil, t0 + 365 days);
        assertEq(checks, 2 * PRICE);
        assertEq(tipKey, bytes32("k2"));
        assertEq(imd.balanceOf(address(reg)), 3 ether + 2 * PRICE);
    }

    function test_postBountyRefusedOnRejectedOrUnknownCase() public {
        uint256 id = _open();
        _deliver(reg.requestVerdict(id), false);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.postBounty(id, 1 ether, 1, 0, 30);
        vm.expectRevert(); // out of bounds
        reg.postBounty(id + 1, 1 ether, 1, 0, 30);
    }

    function test_postBountyWithoutAllowanceReverts() public {
        uint256 id = _open();
        address poor = address(0x9001);
        imd.mint(poor, 10 ether);
        vm.prank(poor);
        vm.expectRevert();
        reg.postBounty(id, 1 ether, 1, 0, 30);
        (address hirer,,,,) = reg.hunts(id);
        assertEq(hirer, address(0));
    }

    function test_onlyTheHirerTopsUp() public {
        uint256 id = _open();
        reg.postBounty(id, 1 ether, 1, 0, 30);
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.postBounty(id, 1 ether, 1, 0, 30);
    }

    function test_fundBountyFailurePaths() public {
        uint256 id = _open();
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.fundBounty(id, 1 ether); // no hunt
        uint256 t0 = block.timestamp;
        reg.postBounty(id, 1 ether, 1, 0, 7);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.fundBounty(id, 0);
        vm.warp(t0 + 7 days); // last second of the hunt
        vm.prank(hunter);
        reg.fundBounty(id, 1 ether);
        assertEq(_bounty(id), 2 ether);
        vm.warp(t0 + 7 days + 1);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.fundBounty(id, 1 ether);
    }

    function test_fundBountyRefusedOnceTheCaseIsRejected() public {
        uint256 id = _open();
        bytes32 req = reg.requestVerdict(id);
        reg.postBounty(id, 1 ether, 1, 0, 30); // a hunt may start before the verdict
        _deliver(req, false);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.fundBounty(id, 1 ether);
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.submitLead(id, sweeper, deposit);
        // the hirer gets everything back once the hunt ends
        vm.warp(block.timestamp + 31 days);
        uint256 before = imd.balanceOf(address(this));
        reg.closeBounty(id);
        assertEq(imd.balanceOf(address(this)), before + 1 ether + PRICE);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_postBountyDaysWindow(uint16 days_, uint16 checks, uint96 reward) public {
        checks = uint16(bound(checks, 0, 50));
        uint256 id = _open();
        bool valid = days_ >= 7 && days_ <= 365 && checks > 0;
        uint256 before = imd.balanceOf(address(this));
        if (!valid) vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.postBounty(id, uint256(reward) % 500 ether, checks, 0, days_);
        if (valid) {
            assertEq(before - imd.balanceOf(address(this)), uint256(reward) % 500 ether + uint256(checks) * PRICE);
            (, uint64 openUntil,, uint256 c,) = reg.hunts(id);
            assertEq(openUntil, block.timestamp + uint256(days_) * 1 days);
            assertEq(c, uint256(checks) * PRICE);
        }
    }

    // ---------------------------------------------------------------- leads

    function test_submitLeadFailurePaths() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 7);
        vm.startPrank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, sweeper, address(0));
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, sweeper, sweeper);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, deposit, address(0x1234)); // not on the trail
        reg.submitLead(id, sweeper, deposit);
        // the one prepaid check is spent: no more leads until the hirer tops up
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.submitLead(id, sweeper, address(0x1234));
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.submitLink(id, "https://x.com/a");
        vm.stopPrank();
        reg.postBounty(id, 0, 1, 0, 7);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.submitLead(id, sweeper, address(0x1234)); // the hunt is over
    }

    function test_leadStakeIsPulledFromTheHunter() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 7);
        address broke = address(0xB1);
        vm.prank(broke);
        vm.expectRevert(); // no IMD for the stake
        reg.submitLead(id, sweeper, deposit);
        vm.prank(hunter);
        (uint256 lead,) = reg.submitLead(id, sweeper, deposit);
        assertEq(imd.balanceOf(hunter), 10 ether - PRICE);
        assertEq(_checks(id), PRICE);
        assertEq(_inFlight(id), 1);
        assertEq(lead, 0);
    }

    function test_rejectedHopIsNotPartOfTheTrail() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        _deliver(r, false);
        assertFalse(reg.reached(id, deposit));
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, deposit, address(0x1234));
        assertEq(_inFlight(id), 0);
    }

    function test_reclaimStakeBoundariesAndLateAnswer() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        uint256 t0 = block.timestamp;
        vm.prank(hunter);
        (uint256 lead, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        vm.warp(t0 + 2 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimStake(lead);
        vm.warp(t0 + 2 days + 1);
        vm.prank(address(0xA77)); // anyone can trigger it; the stake goes to the hunter
        reg.reclaimStake(lead);
        assertEq(imd.balanceOf(hunter), 10 ether);
        assertEq(_inFlight(id), 0);
        assertEq(_checks(id), PRICE); // the check is spent
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimStake(lead);
        // the hop was released: it can be tried again
        vm.prank(hunter);
        reg.submitLead(id, sweeper, deposit);
        // a late "yes" to the abandoned lead pays nothing
        OracleAttestation.Attestation memory a = _answer(r, true);
        a.expiresAt = uint64(block.timestamp + 1 days);
        intake.deliver(address(reg), r, a, _sign(a));
        assertEq(imd.balanceOf(hunter), 10 ether - PRICE);
        assertEq(_bounty(id), 4 ether);
        assertFalse(reg.reached(id, deposit));
        assertEq(_inFlight(id), 1);
    }

    function test_reclaimStakeOnSettledLeadReverts() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        vm.prank(hunter);
        (uint256 lead, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        _deliver(r, true);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimStake(lead);
        vm.expectRevert(); // no such lead
        reg.reclaimStake(lead + 1);
    }

    function test_hopLeadBodyIsPinned() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        // a verdict's question delivered under the lead's id is refused
        (, bytes32 verdictHash) = new LastSeenQuestions().build(1, victim, sweeper, 8453, 100, 200, 5, 4, "");
        OracleAttestation.Attestation memory a = _answer(r, true);
        a.questionHash = verdictHash;
        bytes memory sig = _sign(a);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), r, a, sig);
        a.questionHash = bytes32(0); // and so is an unpinned answer
        sig = _sign(a);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), r, a, sig);
    }

    function test_smallBountiesRoundTheShareDown() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 3, 2, 0, 30); // 3 wei: a quarter rounds to zero
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        _deliver(r, true);
        assertEq(imd.balanceOf(hunter), 10 ether); // only the stake back
        assertEq(_bounty(id), 3);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_confirmedLeadsPayAQuarterOfWhatIsLeft(uint128 reward, uint8 hops) public {
        hops = uint8(bound(hops, 1, 6));
        uint256 id = _confirmed();
        imd.mint(address(this), reward);
        reg.postBounty(id, reward, hops, 0, 30);
        uint256 left = reward;
        uint256 paidTotal;
        address from = sweeper;
        for (uint256 i; i < hops; i++) {
            address to = address(uint160(0x10000 + i));
            uint256 before = imd.balanceOf(hunter);
            vm.prank(hunter);
            (, bytes32 r) = reg.submitLead(id, from, to);
            _deliver(r, true);
            uint256 got = imd.balanceOf(hunter) - before + PRICE; // the stake came back too
            uint256 paid = got - PRICE;
            assertEq(paid * 4 <= left, true);
            assertLt(left - paid * 4, 4); // floor(left / 4)
            left -= paid;
            paidTotal += paid;
            from = to;
        }
        assertEq(_bounty(id), left);
        assertEq(paidTotal + left, reward);
        assertEq(_checks(id), 0);
    }

    // ---------------------------------------------------------------- links

    function test_linkLengthBoundaries() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 4, 0, 30);
        vm.startPrank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, "https://x.c"); // 11 bytes
        reg.submitLink(id, "https://x.co"); // 12 bytes
        bytes memory long = new bytes(300);
        bytes memory head = "https://";
        for (uint256 i; i < 300; i++) {
            long[i] = i < 8 ? head[i] : bytes1("a");
        }
        reg.submitLink(id, string(long));
        bytes memory tooLong = bytes.concat(long, "a");
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, string(tooLong));
        vm.stopPrank();
    }

    function test_linkCharactersThatCouldBreakTheBodyRefused() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 4, 0, 30);
        bytes1[6] memory bad = [bytes1(0x00), 0x0a, 0x20, 0x22, 0x5c, 0x7f];
        vm.startPrank(hunter);
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(LastSeenRegistry.BadInput.selector);
            reg.submitLink(id, string(bytes.concat("https://x.com/", bad[i])));
        }
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, string(bytes.concat("https://x.com/", hex"c3a9"))); // non-ASCII
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, "HTTPS://x.com/a");
        vm.stopPrank();
        assertEq(_inFlight(id), 0);
        assertEq(imd.balanceOf(hunter), 10 ether);
    }

    function test_rejectedLinkPaysTheHirersCheckAndFreesThePage() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 30);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLink(id, "https://x.com/a/status/1");
        _deliver(r, false);
        assertEq(imd.balanceOf(hunter), 10 ether - PRICE);
        assertEq(_checks(id), PRICE);
        assertEq(_bounty(id), 4 ether);
    }

    function test_sameLinkOnAnotherCaseIsItsOwnLead() public {
        uint256 a = _confirmed();
        uint256 b = _confirmed();
        reg.postBounty(a, 4 ether, 1, 0, 30);
        reg.postBounty(b, 4 ether, 1, 0, 30);
        vm.startPrank(hunter);
        reg.submitLink(a, "https://x.com/a");
        reg.submitLink(b, "https://x.com/a");
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_printableLinksAreAccepted(uint256 seed, uint16 len) public {
        len = uint16(bound(len, 4, 292));
        uint256 id = _confirmed();
        reg.postBounty(id, 1 ether, 1, 0, 30);
        bytes memory url = bytes.concat("https://", new bytes(len));
        for (uint256 i; i < len; i++) {
            uint8 c = uint8(uint256(keccak256(abi.encode(seed, i))) % 94) + 0x21; // 0x21..0x7e
            if (c == 0x22 || c == 0x5c) c = 0x61;
            url[8 + i] = bytes1(c);
        }
        vm.prank(hunter);
        (uint256 lead,) = reg.submitLink(id, string(url));
        assertEq(lead, 0);
        assertEq(_inFlight(id), 1);
    }

    // ---------------------------------------------------------------- tips and closing

    function test_payTipFailurePaths() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 30);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.payTip(id, bytes32("t"), address(0), 1 ether);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.payTip(id, bytes32("t"), hunter, 0);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.payTip(id, bytes32("t"), hunter, 4 ether + 1);
        reg.payTip(id, bytes32("t"), address(0x71B), 4 ether); // the whole reward, exactly
        assertEq(_bounty(id), 0);
        assertEq(_checks(id), PRICE); // prepaid checks are not a reward
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.payTip(id, bytes32("t"), address(0x71B), 1);
        uint256 other = _open();
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.payTip(other, bytes32("t"), address(0x71B), 1); // no hunt there: nobody is its hirer
    }

    function test_closeBountyBoundaries() public {
        uint256 id = _confirmed();
        uint256 t0 = block.timestamp;
        reg.postBounty(id, 4 ether, 2, 0, 7);
        vm.warp(t0 + 7 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.closeBounty(id); // the last second of the hunt
        vm.warp(t0 + 7 days + 1);
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.closeBounty(id);
        uint256 before = imd.balanceOf(address(this));
        reg.closeBounty(id);
        assertEq(imd.balanceOf(address(this)), before + 4 ether + 2 * PRICE);
        assertEq(imd.balanceOf(address(reg)), 0);
        reg.closeBounty(id); // again: nothing to return, nothing breaks
        assertEq(imd.balanceOf(address(this)), before + 4 ether + 2 * PRICE);
    }

    function test_closeBountyWaitsForLeadsInFlight() public {
        uint256 id = _confirmed();
        uint256 t0 = block.timestamp;
        reg.postBounty(id, 4 ether, 2, 0, 7);
        vm.warp(t0 + 7 days);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit); // in at the last second
        vm.warp(t0 + 8 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.closeBounty(id);
        OracleAttestation.Attestation memory a = _answer(r, true);
        intake.deliver(address(reg), r, a, _sign(a));
        reg.closeBounty(id);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    // ---------------------------------------------------------------- audits

    function test_requestAuditFailurePaths() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.requestAudit(8453, address(0));
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.requestAudit(10, address(0x70CE));
        vm.prank(address(0xB1)); // holds nothing
        vm.expectRevert();
        reg.requestAudit(8453, address(0x70CE));
        (,, uint256 audits) = reg.counts();
        assertEq(audits, 0);
    }

    function test_auditChargesPricePlusFee() public {
        reg.setAuditFee(0);
        uint256 before = imd.balanceOf(address(this));
        reg.requestAudit(8453, address(0x70CE));
        assertEq(before - imd.balanceOf(address(this)), PRICE);
        assertEq(reg.pool(), 0);
        reg.setAuditFee(3 ether);
        reg.requestAudit(8453, address(0x70CF));
        assertEq(before - imd.balanceOf(address(this)), 2 * PRICE + 3 ether);
        assertEq(reg.pool(), 3 ether);
        assertEq(imd.balanceOf(address(reg)), 3 ether);
    }

    function test_reAuditKeepsTheLastFindingUntilAnswered() public {
        address token = address(0x70CE);
        (, bytes32 r1) = reg.requestAudit(8453, token);
        _deliver(r1, false);
        assertEq(uint8(reg.auditOf(8453, token)), uint8(LastSeenRegistry.Finding.NoPowerFound));
        (, bytes32 r2) = reg.requestAudit(8453, token);
        assertEq(uint8(reg.auditOf(8453, token)), uint8(LastSeenRegistry.Finding.NoPowerFound));
        vm.warp(block.timestamp + 2 days + 1);
        reg.reclaimAudit(r2);
        assertEq(uint8(reg.auditOf(8453, token)), uint8(LastSeenRegistry.Finding.NoPowerFound));
        // the same target on another chain is another contract
        assertEq(uint8(reg.auditOf(1, token)), uint8(LastSeenRegistry.Finding.None));
    }

    function test_reclaimAuditOnlyForAudits() public {
        uint256 id = _open();
        bytes32 verdictReq = reg.requestVerdict(id);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimAudit(verdictReq);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimAudit(keccak256("nothing"));
        (, bytes32 r) = reg.requestAudit(8453, address(0x70CE));
        _deliver(r, true);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimAudit(r); // answered audits are settled
    }

    // ---------------------------------------------------------------- pool

    function test_donateZeroAndWithoutFunds() public {
        reg.donate(0);
        assertEq(reg.pool(), 0);
        vm.prank(address(0xB1));
        vm.expectRevert();
        reg.donate(1);
    }

    // ---------------------------------------------------------------- owner settings

    function test_ownerSettingsRefuseEveryoneElse() public {
        vm.startPrank(hunter);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.transferOwnership(hunter);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.setOracle(intake, ACTION, IERC20(address(imd)), PRICE, hunter);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.setAuditFee(0);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.setSupportedChain(10, true);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.setPanel(9, 7);
        vm.stopPrank();
        assertEq(reg.attester(), vm.addr(attesterKey));
    }

    function test_transferOwnershipMovesEveryPower() public {
        address next = address(0x0A12);
        reg.transferOwnership(next);
        assertEq(reg.owner(), next);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.setAuditFee(0);
        vm.prank(next);
        reg.setAuditFee(0);
        assertEq(reg.auditFee(), 0);
    }

    function test_setPanelBounds() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.setPanel(5, 1);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.setPanel(5, 6);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.setPanel(0, 0);
        reg.setPanel(2, 2);
        assertEq(reg.panelSize(), 2);
        assertEq(reg.quorum(), 2);
    }

    function test_assetCannotChangeWhileHoldingIt() public {
        MockIMD other = new MockIMD();
        reg.donate(1);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.setOracle(intake, ACTION, IERC20(address(other)), PRICE, vm.addr(attesterKey));
        // the same asset with a new price is fine while holding it
        reg.setOracle(intake, ACTION, IERC20(address(imd)), 1 ether, vm.addr(attesterKey));
        assertEq(reg.price(), 1 ether);
    }

    function test_assetChangesWhenEmpty() public {
        MockIMD other = new MockIMD();
        reg.setOracle(intake, bytes32("oracle.request@oracle-2"), IERC20(address(other)), 2 ether, address(0xA7));
        assertEq(address(reg.asset()), address(other));
        assertEq(reg.action(), bytes32("oracle.request@oracle-2"));
        assertEq(reg.price(), 2 ether);
        assertEq(reg.attester(), address(0xA7));
        assertEq(reg.auditFee(), PRICE); // the fee is its own setting
    }

    function test_priceChangeKeepsInFlightStakesWhole() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        vm.prank(hunter);
        (uint256 lead, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        reg.setOracle(intake, ACTION, IERC20(address(imd)), 2 ether, vm.addr(attesterKey));
        // the remaining prepaid check is worth less than one new check now
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.submitLead(id, sweeper, address(0x1234));
        _deliver(r, false);
        assertEq(_checks(id), 2 * PRICE); // the old stake, not the new price
        lead;
    }
}

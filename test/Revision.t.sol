// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {LastSeenQuestions} from "../src/LastSeenQuestions.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {MockIMD, MockIntake} from "./LastSeenRegistry.t.sol";

/// An ERC-20 whose transfers return false instead of reverting.
contract FalseIMD is ERC20 {
    constructor() ERC20("Bad", "BAD") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// One test per change made in the review round (see ADAPTATION.md, "Review findings").
contract RevisionTest is Test {
    MockIMD imd;
    MockIntake intake;
    LastSeenRegistry reg;
    LastSeenQuestions questions;
    uint256 attesterKey = 0xA11CE;
    address victim = address(0xC652);
    address sweeper = address(0xEF94);
    address hunter = address(0xB0B);
    address deposit = address(0xDE90);
    address opener = address(0x0C);
    address stranger = address(0x5157);
    uint256 constant PRICE = 0.5 ether;
    uint256 nonce;

    function setUp() public {
        imd = new MockIMD();
        intake = new MockIntake();
        questions = new LastSeenQuestions();
        reg = new LastSeenRegistry(
            address(this), intake, bytes32("oracle.request@oracle-1"), IERC20(address(imd)), PRICE, vm.addr(attesterKey)
        );
        address[6] memory who = [address(this), hunter, victim, sweeper, opener, stranger];
        for (uint256 i; i < who.length; i++) {
            imd.mint(who[i], 100 ether);
            vm.prank(who[i]);
            imd.approve(address(reg), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _sign(OracleAttestation.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, reg.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// The oracle's questionHash for a pinned body asked with panel `panel` / quorum `quorum`.
    function _questionHash(bytes memory body, uint16 panel, uint16 quorum) internal pure returns (bytes32) {
        bytes memory suffix = bytes(
            string.concat(
                ',"panelSize":',
                vm.toString(uint256(panel)),
                ',"quorum":',
                vm.toString(uint256(quorum)),
                ',"validForSeconds":86400}'
            )
        );
        bytes memory members = new bytes(body.length - suffix.length);
        for (uint256 i; i < members.length; i++) {
            members[i] = body[i];
        }
        return keccak256(bytes.concat(members, "}"));
    }

    function _answer(bool yes, bytes32 questionHash, uint16 panel, uint16 quorum, uint16 agreed)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = bytes32(++nonce);
        a.chainId = 8453;
        a.questionHash = questionHash;
        a.answer = abi.encode(yes);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    /// The answer as the oracle signs it for a request asked with panel 5 / quorum 4 (unpinned bodies accept any hash).
    function _deliver(bytes32 req, bool yes) internal {
        OracleAttestation.Attestation memory a = _answer(yes, _questionHash(intake.bodyOf(req), 5, 4), 5, 4, 5);
        intake.deliver(address(reg), req, a, _sign(a, attesterKey));
    }

    function _status(uint256 id) internal view returns (LastSeenRegistry.Status status) {
        (,,,,,,, status,) = reg.getCase(id);
    }

    function _bounty(uint256 id) internal view returns (uint256 bounty) {
        (,,,,,,,, bounty) = reg.getCase(id);
    }

    function _confirmed() internal returns (uint256 id) {
        vm.prank(opener);
        id = reg.openCase(victim, sweeper, 8453, 100, 200);
        _deliver(reg.requestVerdict(id), true);
    }

    // ---------------------------------------------------------------- the hirer's seat

    /// A stranger (the suspect itself here) can post first, but the opener takes the seat, with their own tip key,
    /// and the wallet takes it from anyone. What the stranger put in stays in the hunt.
    function test_openerAndWalletTakeTheSeatFromAStranger() public {
        vm.prank(opener);
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        vm.prank(sweeper);
        reg.postBounty(id, 1 ether, 1, bytes32("thief key"), 7);
        vm.prank(opener);
        reg.postBounty(id, 10 ether, 4, bytes32("victim key"), 30);
        (address hirer,,, uint256 checks, bytes32 tipKey) = reg.hunts(id);
        assertEq(hirer, opener);
        assertEq(tipKey, bytes32("victim key"));
        assertEq(checks, 5 * PRICE);
        assertEq(_bounty(id), 11 ether);
        // the stranger cannot take it back
        vm.prank(sweeper);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.postBounty(id, 0, 1, bytes32("thief key"), 7);
        // the victim's wallet outranks the opener; passing no key never inherits the previous hirer's
        vm.prank(victim);
        reg.postBounty(id, 0, 1, 0, 7);
        (hirer,,,, tipKey) = reg.hunts(id);
        assertEq(hirer, victim);
        assertEq(tipKey, bytes32(0));
        vm.prank(opener);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.postBounty(id, 0, 1, 0, 7);
        // the hirer keeps topping up as before
        vm.prank(victim);
        reg.postBounty(id, 1 ether, 0, bytes32("k"), 7);
    }

    // ---------------------------------------------------------------- page leads

    /// A page confirmed and paid once cannot be paid again under a fragment, a query string, a trailing slash or
    /// a differently cased host; a different page is still accepted.
    function test_samePageCountsOnceWhateverTheUrlVariant() public {
        uint256 id = _confirmed();
        vm.prank(opener);
        reg.postBounty(id, 40 ether, 6, 0, 30);
        vm.prank(hunter);
        (, bytes32 r1) = reg.submitLink(id, "https://x.com/thief/status/1");
        _deliver(r1, true);
        assertEq(_bounty(id), 30 ether);
        string[4] memory same = [
            "https://x.com/thief/status/1#again",
            "https://x.com/thief/status/1?s=20",
            "https://x.com/thief/status/1/",
            "https://X.COM/thief/status/1"
        ];
        for (uint256 i; i < same.length; i++) {
            vm.prank(hunter);
            vm.expectRevert(LastSeenRegistry.BadInput.selector);
            reg.submitLink(id, same[i]);
        }
        vm.prank(hunter);
        reg.submitLink(id, "https://x.com/thief/status/2");
        assertEq(questions.pageKey("https://X.com/p/?a=1#b"), questions.pageKey("https://x.com/p"));
        assertTrue(questions.pageKey("https://x.com/P") != questions.pageKey("https://x.com/p")); // paths keep their case
    }

    // ---------------------------------------------------------------- settings in flight

    /// An answer is judged against the panel, attester and intake recorded when it was asked, so the owner can
    /// change any of them while requests are in flight without losing them.
    function test_answerIsJudgedAgainstTheSettingsWhenAsked() public {
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        bytes32 r1 = reg.requestVerdict(id);
        uint256 id2 = reg.openCase(victim, deposit, 8453, 100, 200);
        bytes32 r2 = reg.requestVerdict(id2);
        reg.setPanel(7, 5);
        MockIntake newIntake = new MockIntake();
        uint256 newKey = 0xB0B0;
        reg.setOracle(newIntake, bytes32("oracle.request@oracle-2"), IERC20(address(imd)), PRICE, vm.addr(newKey));
        // the first request: the old panel, signed by the old attester, delivered by the old intake
        _deliver(r1, true);
        assertEq(uint8(_status(id)), uint8(LastSeenRegistry.Status.Confirmed));
        assertTrue(reg.flagged(sweeper));
        // the second: the new intake cannot deliver it, and the new attester's signature does not count for it
        OracleAttestation.Attestation memory a = _answer(true, _questionHash(intake.bodyOf(r2), 5, 4), 5, 4, 5);
        bytes memory sig = _sign(a, attesterKey);
        vm.expectRevert(LastSeenRegistry.NotIntake.selector);
        newIntake.deliver(address(reg), r2, a, sig);
        sig = _sign(a, newKey);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), r2, a, sig);
        _deliver(r2, false);
        assertEq(uint8(_status(id2)), uint8(LastSeenRegistry.Status.Rejected));
        // a request asked now needs the new settings
        uint256 id3 = reg.openCase(victim, address(0x3333), 8453, 100, 200);
        bytes32 r3 = reg.requestVerdict(id3);
        a = _answer(true, _questionHash(newIntake.bodyOf(r3), 7, 5), 7, 5, 7);
        sig = _sign(a, attesterKey);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        newIntake.deliver(address(reg), r3, a, sig);
        sig = _sign(a, newKey);
        vm.expectRevert(LastSeenRegistry.NotIntake.selector);
        intake.deliver(address(reg), r3, a, sig);
        newIntake.deliver(address(reg), r3, a, sig);
        assertTrue(reg.flagged(address(0x3333)));
    }

    /// The quorum inside the attestation must be at least the quorum the request asked for.
    function test_quorumBelowTheAskedQuorumRefused() public {
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        bytes32 req = reg.requestVerdict(id);
        bytes32 h = _questionHash(intake.bodyOf(req), 5, 4);
        OracleAttestation.Attestation memory a = _answer(true, h, 5, 1, 1);
        bytes memory sig = _sign(a, attesterKey);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        a = _answer(true, h, 5, 0, 0);
        sig = _sign(a, attesterKey);
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        assertFalse(reg.flagged(sweeper));
        a = _answer(true, h, 6, 5, 5); // a larger panel and quorum are fine
        intake.deliver(address(reg), req, a, _sign(a, attesterKey));
        assertTrue(reg.flagged(sweeper));
    }

    // ---------------------------------------------------------------- the hunt

    /// A hunt on a case the swarm rejects closes at once, once nothing is waiting.
    function test_rejectedCaseHuntClosesAtOnce() public {
        vm.prank(opener);
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        bytes32 req = reg.requestVerdict(id);
        vm.prank(opener);
        reg.postBounty(id, 0, 20, 0, 365);
        vm.prank(hunter);
        (, bytes32 lead) = reg.submitLead(id, sweeper, deposit);
        _deliver(req, false);
        vm.prank(opener);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.closeBounty(id); // a lead is still waiting
        _deliver(lead, false);
        uint256 before = imd.balanceOf(opener);
        vm.prank(opener);
        reg.closeBounty(id);
        assertEq(imd.balanceOf(opener), before + 20 * PRICE);
    }

    /// A hop whose target is the victim's wallet or the suspect discloses nothing and is refused.
    function test_hopToTheWalletOrSuspectRefused() public {
        uint256 id = _confirmed();
        vm.prank(opener);
        reg.postBounty(id, 8 ether, 4, 0, 30);
        vm.startPrank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, sweeper, victim);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        vm.stopPrank();
        _deliver(r, true);
        vm.startPrank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, deposit, sweeper);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, deposit, victim);
        reg.submitLead(id, deposit, address(0x4455));
        vm.stopPrank();
    }

    /// Only the lead's hunter or the hunt's hirer can give up on it.
    function test_onlyHunterOrHirerReclaimsAStake() public {
        uint256 id = _confirmed();
        vm.prank(opener);
        reg.postBounty(id, 8 ether, 4, 0, 30);
        vm.prank(hunter);
        (uint256 l1,) = reg.submitLead(id, sweeper, deposit);
        vm.prank(hunter);
        (uint256 l2,) = reg.submitLead(id, sweeper, address(0x4455));
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(stranger);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.reclaimStake(l1);
        vm.prank(hunter);
        reg.reclaimStake(l1);
        vm.prank(opener);
        reg.reclaimStake(l2);
    }

    // ---------------------------------------------------------------- the list

    /// The owner can take an address off the list; nobody else can.
    function test_ownerCanDelist() public {
        _confirmed();
        assertTrue(reg.flagged(sweeper));
        assertTrue(reg.compromised(victim));
        vm.prank(stranger);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        reg.delist(sweeper);
        reg.delist(sweeper);
        reg.delist(victim);
        assertFalse(reg.flagged(sweeper));
        assertFalse(reg.compromised(victim));
    }

    /// The verdict's definitions exclude movements the wallet authorised and another sender only relayed.
    function test_verdictDefinitionsExcludeAuthorisedMoves() public view {
        (bytes memory body, bytes32 h) = questions.build(1, victim, sweeper, 8453, 100, 200, 5, 4, "");
        assertTrue(_contains(body, "ERC-4337"));
        assertTrue(_contains(body, "did not authorise"));
        assertEq(_questionHash(body, 5, 4), h);
    }

    /// A block number the oracle cannot carry as a JSON number is refused before anything is paid.
    function test_unsafeBlockWindowRefused() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, sweeper, 8453, 1, 2 ** 53);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, sweeper, 8453, 1, type(uint64).max);
        reg.openCase(victim, sweeper, 8453, 1, 2 ** 53 - 1);
    }

    // ---------------------------------------------------------------- the audit

    /// A signed "can take funds" is not erased by a later, cheaper "no"; a "no" is upgraded by a later "yes".
    function test_canTakeFundsIsNotErasedByALaterNo() public {
        address t = address(0x70CE);
        (, bytes32 r1) = reg.requestAudit(8453, t);
        _deliver(r1, true);
        assertEq(uint8(reg.auditOf(8453, t)), uint8(LastSeenRegistry.Finding.CanTakeFunds));
        vm.prank(stranger);
        (, bytes32 r2) = reg.requestAudit(8453, t);
        _deliver(r2, false);
        assertEq(uint8(reg.auditOf(8453, t)), uint8(LastSeenRegistry.Finding.CanTakeFunds));
        address u = address(0x70CF);
        (, bytes32 r3) = reg.requestAudit(8453, u);
        _deliver(r3, false);
        assertEq(uint8(reg.auditOf(8453, u)), uint8(LastSeenRegistry.Finding.NoPowerFound));
        (, bytes32 r4) = reg.requestAudit(8453, u);
        _deliver(r4, true);
        assertEq(uint8(reg.auditOf(8453, u)), uint8(LastSeenRegistry.Finding.CanTakeFunds));
    }

    // ---------------------------------------------------------------- owner and token

    function test_ownershipCannotGoToZero() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.transferOwnership(address(0));
        reg.transferOwnership(stranger);
        assertEq(reg.owner(), stranger);
    }

    /// Without SafeERC20, a transfer that returns false still stops the call.
    function test_transferReturningFalseReverts() public {
        FalseIMD bad = new FalseIMD();
        LastSeenRegistry r = new LastSeenRegistry(
            address(this), intake, bytes32("x"), IERC20(address(bad)), PRICE, vm.addr(attesterKey)
        );
        bad.mint(address(this), 1 ether);
        bad.approve(address(r), type(uint256).max);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        r.donate(1 ether);
        assertEq(r.pool(), 0);
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j; j < needle.length && ok; j++) {
                ok = hay[i + j] == needle[j];
            }
            if (ok) return true;
        }
        return false;
    }
}

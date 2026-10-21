// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {LastSeenQuestions} from "../src/LastSeenQuestions.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {MockIMD, MockIntake} from "./LastSeenRegistry.t.sol";

/// One test per change made for the Robinhood Chain launch (see ADAPTATION.md), plus the oracle's conformance vector.
contract AdaptationTest is Test {
    MockIMD imd;
    MockIntake intake;
    LastSeenRegistry reg;
    LastSeenQuestions questions;
    uint256 attesterKey = 0xA11CE;
    address victim = address(0xC652);
    address sweeper = address(0xEF94);
    address hunter = address(0xB0B);
    address deposit = address(0xDE90);
    uint256 constant PRICE = 0.5 ether;
    uint256 nonce;

    function setUp() public {
        imd = new MockIMD();
        intake = new MockIntake();
        questions = new LastSeenQuestions();
        reg = new LastSeenRegistry(
            address(this), intake, bytes32("oracle.request@oracle-1"), IERC20(address(imd)), PRICE, vm.addr(attesterKey)
        );
        imd.mint(address(this), 100 ether);
        imd.mint(hunter, 10 ether);
        imd.approve(address(reg), type(uint256).max);
        vm.prank(hunter);
        imd.approve(address(reg), type(uint256).max);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key, address verifying)
        internal
        view
        returns (bytes memory)
    {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _questionHash(bytes memory body) internal pure returns (bytes32) {
        bytes memory suffix = bytes(',"panelSize":5,"quorum":4,"validForSeconds":86400}');
        bytes memory members = new bytes(body.length - suffix.length);
        for (uint256 i; i < members.length; i++) {
            members[i] = body[i];
        }
        return keccak256(bytes.concat(members, "}"));
    }

    function _answer(bool yes, bytes32 questionHash) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++nonce);
        a.chainId = 8453;
        a.questionHash = questionHash;
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
        OracleAttestation.Attestation memory a = _answer(yes, _questionHash(intake.bodyOf(req)));
        intake.deliver(address(reg), req, a, _sign(a, attesterKey, address(reg)));
    }

    function _status(uint256 id) internal view returns (LastSeenRegistry.Status status) {
        (,,,,,,, status,) = reg.getCase(id);
    }

    function _bounty(uint256 id) internal view returns (uint256 bounty) {
        (,,,,,,,, bounty) = reg.getCase(id);
    }

    function _confirmed() internal returns (uint256 id) {
        id = reg.openCase(victim, sweeper, 8453, 100, 200);
        _deliver(reg.requestVerdict(id), true);
    }

    // ---------------------------------------------------------------- launch rules

    /// The launch floor refuses a runtime over EIP-170; forge tests do not, so it is asserted here.
    function test_runtimeFitsEip170() public view {
        assertLe(address(reg).code.length, 24_576, "runtime exceeds EIP-170");
        assertLe(address(questions).code.length, 24_576, "helper runtime exceeds EIP-170");
    }

    /// The owner is the constructor argument, never the deployer (the factory).
    function test_ownerIsTheArgumentNotTheDeployer() public {
        address paying = address(0x0A11);
        LastSeenRegistry r =
            new LastSeenRegistry(paying, intake, bytes32("x"), IERC20(address(imd)), PRICE, vm.addr(attesterKey));
        assertEq(r.owner(), paying);
        vm.expectRevert(LastSeenRegistry.NotOwner.selector);
        r.setAuditFee(1);
        vm.prank(paying);
        r.setAuditFee(1);
        assertEq(r.auditFee(), 1);
    }

    /// The constructor runs on an empty chain: it must not call any other contract.
    function test_constructorNeedsNoOtherContract() public {
        LastSeenRegistry r = new LastSeenRegistry(
            address(this),
            IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82),
            0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000,
            IERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127),
            500000000000000000,
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982
        );
        assertEq(r.price(), 0.5 ether);
        assertTrue(r.supportedChain(4663));
    }

    // ---------------------------------------------------------------- reproduced audit findings

    /// Retry: the earlier request no longer counts, so a stale answer cannot settle (or re-settle) the case.
    function test_retryInvalidatesTheEarlierRequest() public {
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        bytes32 r1 = reg.requestVerdict(id);
        vm.warp(block.timestamp + 1 days + 1);
        bytes32 r2 = reg.requestVerdict(id);
        assertTrue(r1 != r2);
        OracleAttestation.Attestation memory no = _answer(false, _questionHash(intake.bodyOf(r1)));
        bytes memory sig = _sign(no, attesterKey, address(reg));
        vm.expectRevert(LastSeenRegistry.UnknownRequest.selector);
        intake.deliver(address(reg), r1, no, sig);
        assertEq(uint8(_status(id)), uint8(LastSeenRegistry.Status.Asked));
        _deliver(r2, true);
        assertTrue(reg.flagged(sweeper));
    }

    /// payTip: not while a lead waits, so a confirmed lead is paid from the reward posted when it went in.
    function test_hirerCannotEmptyTheRewardUnderAWaitingLead() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 8 ether, 2, 0, 30);
        uint256 before = imd.balanceOf(hunter);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.payTip(id, bytes32("t"), address(this), 8 ether);
        _deliver(r, true);
        assertEq(imd.balanceOf(hunter), before + 2 ether);
        reg.payTip(id, bytes32("t"), address(0x71B), 1 ether); // nothing waiting any more
        assertEq(imd.balanceOf(address(0x71B)), 1 ether);
    }

    /// fundBounty: refused after the hunt's end date, so a late donation cannot be taken by the hirer.
    function test_fundBountyRefusedAfterTheHuntEnds() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 1 ether, 1, 0, 7);
        reg.fundBounty(id, 1 ether);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.fundBounty(id, 1 ether);
    }

    /// A page lead that was rejected or never answered can be submitted again for the case.
    function test_pageCanBeResubmittedAfterRejectionOrNoAnswer() public {
        uint256 id = _confirmed();
        reg.postBounty(id, 4 ether, 3, 0, 30);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLink(id, "https://x.com/a/status/1");
        _deliver(r, false);
        vm.prank(hunter);
        (uint256 lead,) = reg.submitLink(id, "https://x.com/a/status/1");
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, "https://x.com/a/status/1"); // waiting: once per case
        vm.warp(block.timestamp + 3 days);
        reg.reclaimStake(lead);
        vm.prank(hunter);
        reg.submitLink(id, "https://x.com/a/status/1");
    }

    /// The answer to another question, delivered under a case's pending id, is refused: the signature carries the hash.
    function test_answerToAnotherQuestionRefused() public {
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        bytes32 req = reg.requestVerdict(id);
        (, bytes32 leadHash) = questions.build(2, sweeper, deposit, 8453, 100, 200, 5, 4, "");
        OracleAttestation.Attestation memory a = _answer(true, leadHash);
        bytes memory sig = _sign(a, attesterKey, address(reg));
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
        assertFalse(reg.flagged(sweeper));
        _deliver(req, true);
        assertTrue(reg.flagged(sweeper));
    }

    /// The pinned hash is keccak-256 of the canonical question document: sorted keys, chain evidence left out.
    function test_questionHashIsTheCanonicalDocument() public view {
        (bytes memory body, bytes32 h) = questions.build(2, sweeper, deposit, 8453, 100, 200, 5, 4, "");
        bytes memory document = bytes.concat(
            '{"answerType":"bool","chainId":8453,"definitions":{"send":"A token transfer event or native coin movement whose sender is the first address and whose receiver is the second."},',
            '"question":"Within the window, did address 0x000000000000000000000000000000000000ef94 send tokens or native coin to address 0x000000000000000000000000000000000000de90? Answer true if there is at least one such transfer.",',
            '"v":1,"window":{"fromBlock":100,"toBlock":200}}'
        );
        assertEq(h, keccak256(document));
        assertEq(_questionHash(body), h);
        assertEq(body[body.length - 1], bytes1("}"));
    }

    /// An audit nobody answered can be marked so after two days; the target can then be asked about again.
    function test_unansweredAuditCanBeReclaimed() public {
        address token = address(0x70CE);
        (uint256 aid, bytes32 r) = reg.requestAudit(8453, token);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimAudit(r);
        vm.warp(block.timestamp + 2 days + 1);
        reg.reclaimAudit(r);
        assertEq(uint8(reg.auditOf(8453, token)), uint8(LastSeenRegistry.Finding.None));
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimAudit(r); // once
        // a late answer to it is unknown now
        OracleAttestation.Attestation memory a = _answer(true, bytes32(0));
        bytes memory sig = _sign(a, attesterKey, address(reg));
        vm.expectRevert(LastSeenRegistry.UnknownRequest.selector);
        intake.deliver(address(reg), r, a, sig);
        aid;
    }

    /// The audit and page bodies carry no `guards` member, which the oracle's body schema does not list.
    function test_bodiesCarryNoUnknownMember() public view {
        (bytes memory audit,) = questions.build(4, address(0), address(0x70CE), 8453, 0, 0, 5, 4, "");
        (bytes memory page,) = questions.build(3, victim, sweeper, 8453, 100, 200, 5, 4, "https://x.com/a");
        assertFalse(_contains(audit, "guards"));
        assertFalse(_contains(page, "guards"));
        assertTrue(_contains(audit, "sourcify.dev"));
        assertTrue(_contains(page, "https://x.com/a"));
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

    // ---------------------------------------------------------------- the protocol's conformance vector

    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    function _vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }

    function _vectorConsumer() internal returns (LastSeenRegistry c) {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(1800000000);
        deployCodeTo(
            "LastSeenRegistry.sol:LastSeenRegistry",
            abi.encode(address(this), intake, bytes32("x"), IERC20(address(imd)), PRICE, SIGNER),
            VECTOR_CONSUMER
        );
        c = LastSeenRegistry(VECTOR_CONSUMER);
    }

    /// The digest this contract verifies is the one the oracle signs: struct, type string and domain match the protocol.
    function test_digestMatchesTheProtocol() public {
        LastSeenRegistry c = _vectorConsumer();
        assertEq(
            c.attestationDigest(_vector()), VECTOR_DIGEST, "struct, type string or domain differs from the protocol's"
        );
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(reg.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    /// A bool answer signed by the vector's key, for the vector's consumer, settles a case (the vector's own answer type is a list, which this contract refuses).
    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        LastSeenRegistry c = _vectorConsumer();
        imd.approve(address(c), type(uint256).max);
        uint256 id = c.openCase(victim, sweeper, 8453, 100, 200);
        bytes32 req = c.requestVerdict(id);
        OracleAttestation.Attestation memory a = _vector();
        a.answerType = 0;
        a.answer = abi.encode(true);
        a.questionHash = _questionHash(intake.bodyOf(req));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, c.attestationDigest(a));
        intake.deliver(address(c), req, a, abi.encodePacked(r, s, v));
        assertTrue(c.flagged(sweeper));
    }
}

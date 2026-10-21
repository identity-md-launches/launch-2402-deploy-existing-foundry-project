// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("IdentityMD", "IMD") {}
    function mint(address to, uint256 v) external { _mint(to, v); }
}

/// Stands in for IdentityMD's Intake: takes the payment, remembers the question, and lets the test deliver an answer.
contract MockIntake is IIntake {
    uint256 public n;
    bytes public lastBody;
    address public lastTarget;
    function request(bytes32, bytes calldata body, Callback calldata cb, address asset, uint256 amount) external returns (bytes32 id) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        lastBody = body;
        lastTarget = cb.target;
        id = keccak256(abi.encode(++n));
    }
    function deliver(address target, bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        LastSeenRegistry(target).onOracleResult{gas: 200_000}(id, a, sig); // the gas IdentityMD gives a callback
    }
}

contract LastSeenRegistryTest is Test {
    MockIMD imd;
    MockIntake intake;
    LastSeenRegistry reg;
    uint256 attesterKey = 0xA11CE;
    address victim = address(0xC652);
    address sweeper = address(0xEF94);
    address hunter = address(0xB0B);
    address deposit = address(0xDE90);
    uint256 constant PRICE = 0.5 ether;

    function setUp() public {
        imd = new MockIMD();
        intake = new MockIntake();
        reg = new LastSeenRegistry(address(this), intake, bytes32("oracle.request@oracle-1"), IERC20(address(imd)), PRICE, vm.addr(attesterKey));
        imd.mint(address(this), 100 ether);
        imd.mint(hunter, 10 ether);
        imd.approve(address(reg), type(uint256).max);
        vm.prank(hunter);
        imd.approve(address(reg), type(uint256).max);
    }

    // the digest is rebuilt here from the published EIP-712 definition, not borrowed from the contract
    function _sign(OracleAttestation.Attestation memory a, uint256 key, address verifying) internal view returns (bytes memory) {
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, verifying));
        bytes32 s1 = keccak256(abi.encode(OracleAttestation.TYPEHASH, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock));
        bytes32 structHash = keccak256(bytes.concat(
            abi.encode(OracleAttestation.TYPEHASH, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock),
            abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)));
        s1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _answer(bool yes, uint16 agreed) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(uint256(1));
        a.chainId = 8453;
        a.answerType = 0;
        a.answer = abi.encode(yes);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = agreed;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _openAndAsk() internal returns (uint256 id, bytes32 req) {
        id = reg.openCase(victim, sweeper, 8453, 100, 200);
        req = reg.requestVerdict(id);
    }

    function test_confirmedVerdictFlagsBoth() public {
        (uint256 id, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(true, 5);
        intake.deliver(address(reg), req, a, _sign(a, attesterKey, address(reg)));
        assertTrue(reg.flagged(sweeper));
        assertTrue(reg.compromised(victim));
        assertEq(uint8(reg.getCase(id).status), uint8(LastSeenRegistry.Status.Confirmed));
    }

    function test_noMeansNoFlag() public {
        (uint256 id, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(false, 5);
        intake.deliver(address(reg), req, a, _sign(a, attesterKey, address(reg)));
        assertFalse(reg.flagged(sweeper));
        assertEq(uint8(reg.getCase(id).status), uint8(LastSeenRegistry.Status.Rejected));
    }

    function test_wrongSignerRejected() public {
        (, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(true, 5);
        bytes memory sig = _sign(a, 0xBAD, address(reg));
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
    }

    function test_signatureForAnotherContractRejected() public {
        (, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(true, 5);
        bytes memory sig = _sign(a, attesterKey, address(0x1234));
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
    }

    function test_panelBelowQuorumRejected() public {
        (, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(true, 3);
        bytes memory sig = _sign(a, attesterKey, address(reg));
        vm.expectRevert(LastSeenRegistry.BadAttestation.selector);
        intake.deliver(address(reg), req, a, sig);
    }

    function test_onlyIntakeCanAnswer() public {
        (, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(true, 5);
        bytes memory sig = _sign(a, attesterKey, address(reg));
        vm.expectRevert(LastSeenRegistry.NotIntake.selector);
        reg.onOracleResult(req, a, sig);
    }

    function test_answerCannotBeReplayed() public {
        (, bytes32 req) = _openAndAsk();
        OracleAttestation.Attestation memory a = _answer(true, 5);
        bytes memory sig = _sign(a, attesterKey, address(reg));
        intake.deliver(address(reg), req, a, sig);
        vm.expectRevert(LastSeenRegistry.UnknownRequest.selector);
        intake.deliver(address(reg), req, a, sig);
    }

    function test_poolMakesVerdictFreeForVictim() public {
        reg.donate(1 ether);
        address stranger = address(0x5);
        vm.startPrank(stranger); // holds no IMD at all
        uint256 id = reg.openCase(victim, sweeper, 8453, 100, 200);
        reg.requestVerdict(id);
        vm.stopPrank();
        assertEq(reg.pool(), 0.5 ether);
        assertEq(imd.balanceOf(address(intake)), PRICE);
    }

    function _confirmed() internal returns (uint256 id, OracleAttestation.Attestation memory a) {
        bytes32 req;
        (id, req) = _openAndAsk();
        a = _answer(true, 5);
        intake.deliver(address(reg), req, a, _sign(a, attesterKey, address(reg)));
    }

    function _deliver(bytes32 req, bool yes) internal {
        OracleAttestation.Attestation memory a = _answer(yes, 5);
        intake.deliver(address(reg), req, a, _sign(a, attesterKey, address(reg)));
    }

    function test_trailPaysHuntersHopByHop() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 8 ether, 4, bytes32("key"), 30);
        (address hirer,,, uint256 checks,) = reg.hunts(id);
        assertEq(hirer, address(this));
        assertEq(checks, 4 * PRICE);

        // a lead must start where the confirmed trail already is
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, address(0x777), deposit);

        address hop = address(0x4455);
        vm.prank(hunter);
        (, bytes32 r1) = reg.submitLead(id, sweeper, hop);
        _deliver(r1, true);
        assertTrue(reg.reached(id, hop));
        uint256 afterFirst = imd.balanceOf(hunter);
        assertEq(afterFirst, 10 ether + 2 ether); // stake back, plus a quarter of 8

        vm.prank(hunter);
        (, bytes32 r2) = reg.submitLead(id, hop, deposit);
        _deliver(r2, true);
        assertEq(imd.balanceOf(hunter), afterFirst + 1.5 ether); // a quarter of the 6 left
        assertEq(reg.getCase(id).bounty, 4.5 ether);
        (,,, checks,) = reg.hunts(id);
        assertEq(checks, 2 * PRICE); // the hirer paid for the two checks
    }

    function test_wrongLeadPaysForItsOwnCheck() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 30);
        vm.prank(hunter);
        (, bytes32 r) = reg.submitLead(id, sweeper, deposit);
        _deliver(r, false);
        assertEq(imd.balanceOf(hunter), 10 ether - PRICE);
        (,,, uint256 checks,) = reg.hunts(id);
        assertEq(checks, PRICE); // the stake refilled the hirer's prepaid check
        assertEq(reg.getCase(id).bounty, 4 ether);
        // the same hop can be tried again, by anyone
        vm.prank(hunter);
        reg.submitLead(id, sweeper, deposit);
    }

    function test_sameHopCannotBePaidTwice() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        vm.prank(hunter);
        reg.submitLead(id, sweeper, deposit);
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLead(id, sweeper, deposit);
    }

    function test_leadNeedsAHuntWithPrepaidChecks() public {
        (uint256 id,) = _openAndAsk();
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.submitLead(id, sweeper, deposit);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.postBounty(id, 1 ether, 0, 0, 30); // a hunt with no checks could never judge anything
    }

    function test_linkLeadIsJudgedByThePanelAndPays() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 30);
        address anon = address(0xA407); // a fresh wallet with nothing else on it
        imd.mint(anon, PRICE);
        vm.startPrank(anon);
        imd.approve(address(reg), PRICE);
        (, bytes32 r) = reg.submitLink(id, "https://x.com/someone/status/123");
        vm.stopPrank();
        bytes memory body = intake.lastBody();
        assertEq(body[body.length - 1], bytes1("}"));
        _deliver(r, true);
        assertEq(imd.balanceOf(anon), PRICE + 1 ether);
    }

    function test_unsafeLinksRefused() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 4 ether, 2, 0, 30);
        vm.startPrank(hunter);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, "http://plain.example/x");
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, 'https://x.com/a","evil":"1');
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, "https://x.com/a b");
        reg.submitLink(id, "https://x.com/a");
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.submitLink(id, "https://x.com/a"); // once per case
        vm.stopPrank();
    }

    function test_onlyHirerPaysTipsAndCloses() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 7);
        vm.prank(hunter);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.payTip(id, bytes32("t"), hunter, 1 ether);
        reg.payTip(id, bytes32("t"), address(0x71B), 1 ether);
        assertEq(imd.balanceOf(address(0x71B)), 1 ether);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.closeBounty(id); // still open
        vm.warp(block.timestamp + 8 days);
        uint256 before = imd.balanceOf(address(this));
        reg.closeBounty(id);
        assertEq(imd.balanceOf(address(this)), before + 3 ether + PRICE);
    }

    function test_unansweredLeadReturnsStake() public {
        (uint256 id,) = _confirmed();
        reg.postBounty(id, 4 ether, 1, 0, 7);
        vm.prank(hunter);
        (uint256 lead,) = reg.submitLead(id, sweeper, deposit);
        vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
        reg.reclaimStake(lead);
        vm.warp(block.timestamp + 3 days);
        reg.reclaimStake(lead);
        assertEq(imd.balanceOf(hunter), 10 ether);
        vm.warp(block.timestamp + 30 days);
        reg.closeBounty(id); // nothing left waiting
    }

    function test_swarmAuditFeedsThePool() public {
        address token = address(0x70CE);
        (uint256 aid, bytes32 r) = reg.requestAudit(8453, token);
        assertEq(reg.pool(), PRICE); // the audit fee
        assertEq(uint8(reg.auditOf(8453, token)), uint8(LastSeenRegistry.Finding.Asked));
        string memory body = reg.auditBody(8453, token);
        assertEq(keccak256(intake.lastBody()), keccak256(bytes(body)));
        _deliver(r, true);
        assertEq(uint8(reg.auditOf(8453, token)), uint8(LastSeenRegistry.Finding.CanTakeFunds));
        assertEq(uint8(reg.getAudit(aid).finding), uint8(LastSeenRegistry.Finding.CanTakeFunds));
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.requestAudit(10, token);
    }

    function test_bodyIsValidJsonShape() public {
        (uint256 id,) = _openAndAsk();
        string memory body = reg.verdictBody(id);
        assertEq(bytes(body)[0], bytes1("{"));
        assertEq(bytes(body)[bytes(body).length - 1], bytes1("}"));
        assertEq(keccak256(intake.lastBody()), keccak256(bytes(body)));
        assertEq(intake.lastTarget(), address(reg));
    }

    function test_unsupportedChainRefusedBeforePaying() public {
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.openCase(victim, sweeper, 10, 100, 200); // Optimism: the oracle cannot read it
    }

    function test_callbackSelectorMatchesDocs() public view {
        assertEq(reg.onOracleResult.selector, bytes4(0x510379c7));
    }
}

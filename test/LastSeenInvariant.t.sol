// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {OracleAttestation} from "../src/IIntake.sol";
import {MockIMD, MockIntake} from "./LastSeenRegistry.t.sol";

/// Drives the registry in random order from several wallets, with the oracle answering (or not) at random.
/// Ghosts record what the registry must owe, measured from token movements rather than its own storage.
contract RegistryHandler is Test {
    LastSeenRegistry public reg;
    MockIMD public imd;
    MockIntake public intake;
    uint256 internal attesterKey;
    uint256 public constant PRICE = 0.5 ether;
    uint256 internal constant MAX_CASES = 6;

    address[4] internal actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    address[3] internal suspects = [address(0x5A), address(0x5B), address(0x5C)];
    address internal constant WALLET = address(0xC652);

    struct Req {
        bytes32 id;
        uint8 kind; // 1 verdict, 2 lead, 3 audit
        uint256 ref; // case, lead or audit id
        uint16 panel; // the oracle settings the request was asked and paid under
        uint16 quorum;
        uint256 key;
    }

    uint16 internal panel = 5;
    uint16 internal quorum = 4;
    uint256 internal constant KEY_B = 0xB0B0;

    Req[] internal open; // requests nobody has answered or reclaimed
    uint256[] internal leadCase; // lead => case
    bool[] internal leadWaiting; // lead => waiting for the swarm
    uint256[] internal leadStake; // lead => IMD the hunter put down
    address[] internal leadTo; // lead => the hop's target, zero for a page
    address[] internal leadHunter; // lead => who staked it
    mapping(uint256 => address[]) internal trail; // case => addresses a lead may start from
    mapping(uint256 => uint256) public waitingOf; // case => leads waiting
    mapping(uint256 => uint8) public finalStatus; // case => Confirmed/Rejected once settled, 0 before
    mapping(address => bool) public everConfirmed; // suspect => some case about it confirmed

    uint256 public ghostPoolIn; // donations and audit fees
    uint256 public ghostFromPool; // verdicts the pool paid for
    uint256 public ghostRewardIn; // posted and funded rewards
    uint256 public ghostRewardOut; // rewards paid as tips, lead shares or returned at close
    uint256 public ghostStakes; // stakes held for waiting leads
    uint256 public ghostRequests; // requests the registry paid the intake for
    uint256 public leadsPaid; // confirmed leads that paid a share
    uint256 public closes; // hunts closed with funds returned
    uint256 public seatsTaken; // hunts whose seat the opener or the wallet took over
    uint256 public rotations; // oracle panel or attester changes while requests were in flight
    bool public forgedAccepted;
    bool public closedTooEarly;
    uint256 nonce;

    constructor(MockIMD imd_, MockIntake intake_, uint256 key) {
        imd = imd_;
        intake = intake_;
        attesterKey = key;
    }

    /// The registry is owned by this handler (so it can move the audit fee); it is deployed after the handler.
    function init(LastSeenRegistry reg_) external {
        require(address(reg) == address(0));
        reg = reg_;
        for (uint256 i; i < actors.length; i++) {
            imd.mint(actors[i], 10_000 ether);
            vm.prank(actors[i]);
            imd.approve(address(reg), type(uint256).max);
        }
        imd.mint(WALLET, 10_000 ether);
        vm.prank(WALLET);
        imd.approve(address(reg), type(uint256).max);
    }

    function cases() public view returns (uint256 n) {
        (n,,) = reg.counts();
    }

    function leads() external view returns (uint256) {
        return leadCase.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _bounty(uint256 id) internal view returns (uint256 b) {
        (,,,,,,,, b) = reg.getCase(id);
    }

    function _status(uint256 id) internal view returns (LastSeenRegistry.Status s) {
        (,,,,,,, s,) = reg.getCase(id);
    }

    // ---------------------------------------------------------------- actions

    function openCase(uint256 suspectSeed, uint256 actorSeed, uint64 fromBlock, uint64 len) external {
        if (cases() >= MAX_CASES) return;
        fromBlock = uint64(bound(fromBlock, 0, 1e9));
        len = uint64(bound(len, 1, 1e6));
        address s = suspects[suspectSeed % suspects.length];
        vm.prank(_actor(actorSeed));
        uint256 id = reg.openCase(WALLET, s, 8453, fromBlock, fromBlock + len);
        trail[id].push(s);
    }

    function requestVerdict(uint256 caseSeed, uint256 actorSeed) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (,,,,,, uint64 askedAt, LastSeenRegistry.Status s,) = reg.getCase(id);
        bool retry = s == LastSeenRegistry.Status.Asked && block.timestamp > askedAt + 1 days;
        if (s != LastSeenRegistry.Status.Open && !retry) {
            vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
            reg.requestVerdict(id);
            return;
        }
        address a = _actor(actorSeed);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        bytes32 req = reg.requestVerdict(id);
        if (imd.balanceOf(a) == before) ghostFromPool++;
        else assertEq(before - imd.balanceOf(a), PRICE);
        ghostRequests++;
        // the earlier ask no longer counts
        for (uint256 i; i < open.length; i++) {
            if (open[i].kind == 1 && open[i].ref == id) {
                _drop(i);
                break;
            }
        }
        open.push(Req(req, 1, id, panel, quorum, attesterKey));
    }

    function postBounty(uint256 caseSeed, uint256 actorSeed, uint256 reward, uint16 checks, uint16 days_) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (address hirer,,,,) = reg.hunts(id);
        address a = hirer == address(0) ? _actor(actorSeed) : hirer;
        LastSeenRegistry.Status s = _status(id);
        if (s == LastSeenRegistry.Status.Rejected) return;
        reward = bound(reward, 0, 50 ether);
        checks = uint16(bound(checks, hirer == address(0) ? 1 : 0, 6));
        days_ = uint16(bound(days_, 7, 120));
        vm.prank(a);
        reg.postBounty(id, reward, checks, bytes32(0), days_);
        ghostRewardIn += reward;
    }

    /// The case's opener or its wallet takes the seat from a stranger, never from each other and never under a
    /// waiting lead. The earlier hirer is paid back what was left; the new hirer starts from their own deposit.
    function takeSeat(uint256 caseSeed, bool byWallet, uint256 reward, uint16 checks, uint16 days_) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (address hirer,, uint256 inFlight,,) = reg.hunts(id);
        (address wallet,, address opener,,,,, LastSeenRegistry.Status s,) = reg.getCase(id);
        if (hirer == address(0) || s == LastSeenRegistry.Status.Rejected) return;
        address taker = byWallet ? wallet : opener;
        if (taker == hirer) return;
        if (hirer == opener || hirer == wallet) {
            vm.prank(taker);
            vm.expectRevert(LastSeenRegistry.NotHirer.selector);
            reg.postBounty(id, 1 ether, 1, bytes32(0), 7);
            return;
        }
        if (inFlight != 0) {
            vm.prank(taker);
            vm.expectRevert(LastSeenRegistry.WrongStatus.selector);
            reg.postBounty(id, 1 ether, 1, bytes32(0), 7);
            return;
        }
        // a takeover with no check of the taker's own is refused, and nothing moves
        vm.prank(taker);
        vm.expectRevert(LastSeenRegistry.BadInput.selector);
        reg.postBounty(id, 1 ether, 0, bytes32(0), 7);

        _takeSeat(id, taker, bound(reward, 0, 20 ether), uint16(bound(checks, 1, 4)), uint16(bound(days_, 7, 120)));
    }

    function _takeSeat(uint256 id, address taker, uint256 reward, uint16 checks, uint16 days_) internal {
        (address hirer,,, uint256 heldChecks,) = reg.hunts(id);
        uint256 left = _bounty(id);
        uint256 hirerBefore = imd.balanceOf(hirer);
        uint256 takerBefore = imd.balanceOf(taker);
        vm.prank(taker);
        reg.postBounty(id, reward, checks, bytes32("taken"), days_);
        // the earlier hirer gets exactly what was left; the taker pays exactly their own deposit
        assertEq(imd.balanceOf(hirer) - hirerBefore, left + heldChecks);
        assertEq(takerBefore - imd.balanceOf(taker), reward + uint256(checks) * PRICE);
        (address now_, uint256 openUntil,, uint256 newChecks, bytes32 key) = reg.hunts(id);
        assertEq(now_, taker);
        assertEq(key, bytes32("taken"));
        assertEq(newChecks, uint256(checks) * PRICE);
        assertEq(_bounty(id), reward);
        assertEq(openUntil, block.timestamp + uint256(days_) * 1 days); // restarted, not inherited
        ghostRewardOut += left;
        ghostRewardIn += reward;
        seatsTaken++;
    }

    /// A stranger can never take a seat that is already someone's.
    function strangerTakesSeat(uint256 caseSeed, uint256 actorSeed) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (address hirer,,,,) = reg.hunts(id);
        (address wallet,, address opener,,,,, LastSeenRegistry.Status s,) = reg.getCase(id);
        address a = _actor(actorSeed);
        if (hirer == address(0) || a == hirer || a == opener || a == wallet || s == LastSeenRegistry.Status.Rejected) {
            return;
        }
        vm.prank(a);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.postBounty(id, 1 ether, 1, bytes32(0), 30);
    }

    /// The owner changes the panel or the attester while requests are in flight: each is still judged as asked.
    function rotate(uint256 seed) external {
        panel = uint16(5 + seed % 4);
        quorum = uint16(4 + (seed / 4) % (panel - 3));
        attesterKey = (seed / 64) % 2 == 0 ? 0xA11CE : KEY_B;
        reg.setPanel(panel, quorum);
        reg.setOracle(intake, reg.action(), IERC20(address(imd)), PRICE, vm.addr(attesterKey));
        if (open.length > 0) rotations++;
    }

    function fundBounty(uint256 caseSeed, uint256 actorSeed, uint256 amount) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (address hirer, uint256 openUntil,,,) = reg.hunts(id);
        if (hirer == address(0) || block.timestamp > openUntil || _status(id) == LastSeenRegistry.Status.Rejected) {
            return;
        }
        amount = bound(amount, 1, 20 ether);
        vm.prank(_actor(actorSeed));
        reg.fundBounty(id, amount);
        ghostRewardIn += amount;
    }

    function _canLead(uint256 id) internal view returns (bool) {
        (address hirer, uint256 openUntil,, uint256 checks,) = reg.hunts(id);
        return hirer != address(0) && block.timestamp <= openUntil && _status(id) != LastSeenRegistry.Status.Rejected
            && checks >= PRICE;
    }

    function submitLead(uint256 caseSeed, uint256 actorSeed, uint256 fromSeed, uint256 toSeed) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        if (!_canLead(id)) return;
        address from = trail[id][fromSeed % trail[id].length];
        address to = address(uint160(0x7000 + toSeed % 12));
        if (to == from) return;
        address a = _actor(actorSeed);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        try reg.submitLead(id, from, to) returns (uint256 lead, bytes32 req) {
            _recordLead(id, lead, req, before - imd.balanceOf(a), to, a);
        } catch {
            // only a hop already claimed or confirmed for this case is refused here
        }
    }

    function submitLink(uint256 caseSeed, uint256 actorSeed, uint256 pageSeed) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        if (!_canLead(id)) return;
        string memory url = string.concat("https://x.com/p/", vm.toString(pageSeed % 8));
        address a = _actor(actorSeed);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        try reg.submitLink(id, url) returns (uint256 lead, bytes32 req) {
            _recordLead(id, lead, req, before - imd.balanceOf(a), address(0), a);
        } catch {
            // the page is already waiting or confirmed for this case
        }
    }

    function _recordLead(uint256 id, uint256 lead, bytes32 req, uint256 paid, address to, address hunter) internal {
        leadTo.push(to);
        leadHunter.push(hunter);
        assertEq(lead, leadCase.length);
        assertEq(paid, PRICE); // the stake
        leadCase.push(id);
        leadWaiting.push(true);
        leadStake.push(paid);
        ghostStakes += paid;
        waitingOf[id]++;
        ghostRequests++;
        open.push(Req(req, 2, lead, panel, quorum, attesterKey));
    }

    function payTip(uint256 caseSeed, uint256 amount, uint256 toSeed) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (address hirer,, uint256 inFlight,,) = reg.hunts(id);
        uint256 b = _bounty(id);
        if (hirer == address(0) || inFlight != 0 || b == 0) return;
        amount = bound(amount, 1, b);
        vm.prank(hirer);
        reg.payTip(id, bytes32(0), _actor(toSeed), amount);
        ghostRewardOut += amount;
    }

    function closeBounty(uint256 caseSeed) external {
        uint256 n = cases();
        if (n == 0) return;
        uint256 id = caseSeed % n;
        (address hirer, uint256 openUntil, uint256 inFlight, uint256 checks,) = reg.hunts(id);
        if (hirer == address(0)) return;
        // a hunt ends at its end date, or at once when the swarm rejects the case; never with a lead waiting
        bool rejected = _status(id) == LastSeenRegistry.Status.Rejected;
        if ((block.timestamp <= openUntil && !rejected) || inFlight != 0) {
            vm.prank(hirer);
            try reg.closeBounty(id) {
                closedTooEarly = true;
            } catch {}
            return;
        }
        uint256 b = _bounty(id);
        uint256 before = imd.balanceOf(hirer);
        vm.prank(hirer);
        reg.closeBounty(id);
        assertEq(imd.balanceOf(hirer) - before, b + checks);
        ghostRewardOut += b;
        if (b + checks > 0) closes++;
    }

    /// The hunter or the hirer gives up on an unanswered lead; a stranger cannot.
    function reclaimStake(uint256 leadSeed, uint256 who) external {
        if (leadCase.length == 0) return;
        uint256 lead = leadSeed % leadCase.length;
        if (!leadWaiting[lead]) return;
        vm.warp(block.timestamp + 2 days + 1);
        address hunter = leadHunter[lead];
        (address hirer,,,,) = reg.hunts(leadCase[lead]);
        address stranger = address(0x57A9);
        vm.prank(stranger);
        vm.expectRevert(LastSeenRegistry.NotHirer.selector);
        reg.reclaimStake(lead);
        uint256 before = imd.balanceOf(hunter);
        vm.prank(who % 2 == 0 ? hunter : hirer);
        reg.reclaimStake(lead);
        assertEq(imd.balanceOf(hunter) - before, leadStake[lead]); // the stake goes to the hunter, whoever asks
        _leadDone(lead, true);
    }

    function requestAudit(uint256 actorSeed, uint256 targetSeed, uint256 fee) external {
        if (fee % 3 == 0) reg.setAuditFee(bound(fee, 0, 2 ether));
        uint256 f = reg.auditFee();
        address a = _actor(actorSeed);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        (uint256 aid, bytes32 req) = reg.requestAudit(8453, address(uint160(0x9000 + targetSeed % 4)));
        assertEq(before - imd.balanceOf(a), PRICE + f);
        ghostPoolIn += f;
        ghostRequests++;
        open.push(Req(req, 3, aid, panel, quorum, attesterKey));
    }

    function reclaimAudit(uint256 seed) external {
        for (uint256 k; k < open.length; k++) {
            uint256 i = (seed + k) % open.length;
            if (open[i].kind != 3) continue;
            vm.warp(block.timestamp + 2 days + 1);
            reg.reclaimAudit(open[i].id);
            _drop(i);
            return;
        }
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 0, 5 ether);
        vm.prank(_actor(actorSeed));
        reg.donate(amount);
        ghostPoolIn += amount;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    /// The oracle answers one waiting request, signed for this registry.
    function answer(uint256 seed, bool yes) external {
        if (open.length == 0) return;
        uint256 i = seed % open.length;
        Req memory r = open[i];
        OracleAttestation.Attestation memory a = _attestation(r, yes);
        uint256 caseId = r.kind == 1 ? r.ref : r.kind == 2 ? leadCase[r.ref] : 0;
        uint256 bountyBefore = r.kind == 2 ? _bounty(caseId) : 0;
        intake.deliver(address(reg), r.id, a, _sign(a, r.key));
        _drop(i);
        if (r.kind == 1) {
            LastSeenRegistry.Status s = _status(caseId);
            assertEq(uint8(s), uint8(yes ? LastSeenRegistry.Status.Confirmed : LastSeenRegistry.Status.Rejected));
            finalStatus[caseId] = uint8(s);
            if (yes) {
                (, address suspect,,,,,,,) = reg.getCase(caseId);
                everConfirmed[suspect] = true;
            }
        } else if (r.kind == 2 && leadWaiting[r.ref]) {
            ghostRewardOut += bountyBefore - _bounty(caseId);
            address to = leadTo[r.ref];
            if (yes && to != address(0)) {
                assertTrue(reg.reached(caseId, to));
                trail[caseId].push(to);
            }
            if (yes) leadsPaid++;
            _leadDone(r.ref, false); // confirmed: the stake went back; wrong: it became the hirer's check
        } else if (r.kind == 2) {
            assertEq(bountyBefore, _bounty(caseId)); // a late answer to a reclaimed lead pays nothing
        }
    }

    /// Answers the registry must refuse: a stranger's key, the other attester's key, a panel or quorum below what the
    /// request asked for, or (for pinned questions) another question.
    function forge_(uint256 seed, bool yes, uint8 how) external {
        if (open.length == 0) return;
        Req memory r = open[seed % open.length];
        OracleAttestation.Attestation memory a = _attestation(r, yes);
        uint256 key = r.key;
        how = how % 5;
        if (how == 0 && r.kind == 1) a.questionHash = keccak256(abi.encode(seed));
        else if (how == 1) key = r.key == KEY_B ? 0xA11CE : KEY_B; // signed by the attester the request was not asked of
        else if (how == 2) a.panelSize = r.panel - 1;
        else if (how == 3) (a.quorum, a.agreed) = (r.quorum - 1, r.quorum - 1);
        else key = 0xBAD;
        bytes memory sig = _sign(a, key);
        try intake.deliver(address(reg), r.id, a, sig) {
            forgedAccepted = true;
        } catch {}
    }

    // ---------------------------------------------------------------- helpers

    function _drop(uint256 i) internal {
        open[i] = open[open.length - 1];
        open.pop();
    }

    function _leadDone(uint256 lead, bool dropRequest) internal {
        ghostStakes -= leadStake[lead];
        leadStake[lead] = 0;
        leadWaiting[lead] = false;
        waitingOf[leadCase[lead]]--;
        // a reclaimed lead's request stays answerable (late answers must be no-ops), so it is kept
        if (!dropRequest) return;
        for (uint256 i; i < open.length; i++) {
            if (open[i].kind == 2 && open[i].ref == lead) {
                _drop(i);
                return;
            }
        }
    }

    function _attestation(Req memory r, bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++nonce);
        a.chainId = 8453;
        bytes memory body = intake.bodyOf(r.id);
        bytes memory suffix = bytes(
            string.concat(
                ',"panelSize":', vm.toString(r.panel), ',"quorum":', vm.toString(r.quorum), ',"validForSeconds":86400}'
            )
        );
        bytes memory members = new bytes(body.length - suffix.length);
        for (uint256 i; i < members.length; i++) {
            members[i] = body[i];
        }
        a.questionHash = keccak256(bytes.concat(members, "}"));
        a.answer = abi.encode(yes);
        a.panelSize = r.panel;
        a.quorum = r.quorum;
        a.agreed = r.quorum + uint16(nonce % 2); // anywhere from the quorum to one more
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, reg.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }
}

contract LastSeenInvariantTest is Test {
    LastSeenRegistry reg;
    MockIMD imd;
    MockIntake intake;
    RegistryHandler handler;
    uint256 constant PRICE = 0.5 ether;

    function setUp() public {
        imd = new MockIMD();
        intake = new MockIntake();
        uint256 key = 0xA11CE;
        handler = new RegistryHandler(imd, intake, key);
        reg = new LastSeenRegistry(
            address(handler), intake, bytes32("oracle.request@oracle-1"), IERC20(address(imd)), PRICE, vm.addr(key)
        );
        handler.init(reg);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](24);
        sel[0] = RegistryHandler.openCase.selector;
        sel[1] = RegistryHandler.requestVerdict.selector;
        sel[2] = RegistryHandler.postBounty.selector;
        sel[3] = RegistryHandler.fundBounty.selector;
        sel[4] = RegistryHandler.submitLead.selector;
        sel[5] = RegistryHandler.submitLink.selector;
        sel[6] = RegistryHandler.payTip.selector;
        sel[7] = RegistryHandler.closeBounty.selector;
        sel[8] = RegistryHandler.reclaimStake.selector;
        sel[9] = RegistryHandler.requestAudit.selector;
        sel[10] = RegistryHandler.reclaimAudit.selector;
        sel[11] = RegistryHandler.donate.selector;
        sel[12] = RegistryHandler.warp.selector;
        sel[13] = RegistryHandler.answer.selector;
        sel[14] = RegistryHandler.answer.selector; // answers come often
        sel[15] = RegistryHandler.forge_.selector;
        sel[16] = RegistryHandler.submitLead.selector;
        sel[17] = RegistryHandler.submitLead.selector;
        sel[18] = RegistryHandler.postBounty.selector;
        sel[19] = RegistryHandler.answer.selector;
        sel[20] = RegistryHandler.takeSeat.selector;
        sel[21] = RegistryHandler.strangerTakesSeat.selector;
        sel[22] = RegistryHandler.rotate.selector;
        sel[23] = RegistryHandler.forge_.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    function _sums() internal view returns (uint256 bounties, uint256 checks) {
        uint256 n = handler.cases();
        for (uint256 i; i < n; i++) {
            (,,,,,,,, uint256 b) = reg.getCase(i);
            (,,, uint256 c,) = reg.hunts(i);
            bounties += b;
            checks += c;
        }
    }

    /// What the registry holds is exactly what it owes: the pool, every reward, every prepaid check, every stake.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_holdsExactlyWhatItOwes() public view {
        (uint256 bounties, uint256 checks) = _sums();
        assertEq(imd.balanceOf(address(reg)), reg.pool() + bounties + checks + handler.ghostStakes());
    }

    /// The pool is what was donated or paid as audit fees, less the verdicts it paid for.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_poolIsDonationsLessFreeVerdicts() public view {
        assertEq(reg.pool(), handler.ghostPoolIn() - handler.ghostFromPool() * PRICE);
    }

    /// Rewards left are what was posted or funded, less what was paid out as tips, lead shares or returned.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_rewardsAreConserved() public view {
        (uint256 bounties,) = _sums();
        assertEq(bounties, handler.ghostRewardIn() - handler.ghostRewardOut());
    }

    /// Every question the registry asked was paid in full, once.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_everyRequestPaidExactlyThePrice() public view {
        assertEq(intake.n(), handler.ghostRequests());
        assertEq(imd.balanceOf(address(intake)), handler.ghostRequests() * PRICE);
    }

    /// A hunt's in-flight count is the number of its leads still waiting for the swarm.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_inFlightMatchesWaitingLeads() public view {
        uint256 n = handler.cases();
        for (uint256 i; i < n; i++) {
            (,, uint256 inFlight,,) = reg.hunts(i);
            assertEq(inFlight, handler.waitingOf(i));
        }
    }

    /// A settled case never reopens or flips, and the flagged list is exactly the confirmed suspects.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_settledCasesStaySettled() public view {
        uint256 n = handler.cases();
        for (uint256 i; i < n; i++) {
            uint8 f = handler.finalStatus(i);
            (, address suspect,,,,,, LastSeenRegistry.Status s,) = reg.getCase(i);
            if (f != 0) assertEq(uint8(s), f);
            assertEq(reg.flagged(suspect), handler.everConfirmed(suspect));
        }
    }

    /// No forged answer was ever accepted, and no hunt closed early or with a lead waiting.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_noForgeryNoEarlyClose() public view {
        assertFalse(handler.forgedAccepted());
        assertFalse(handler.closedTooEarly());
    }
}

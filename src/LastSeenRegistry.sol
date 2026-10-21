// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IIntake, OracleAttestation} from "./IIntake.sol";
import {LastSeenQuestions} from "./LastSeenQuestions.sol";

/// @title LastSeenRegistry
/// @notice A public "do not send" list for crypto wallets, a bounty hunt for stolen funds, and contract audits,
///         where every answer that matters is checked and signed by the IdentityMD agent swarm.
///
/// 1. The case. Anyone opens one: "address S has been taking funds out of wallet W on chain C, between blocks A and B".
///    Anyone asks for a verdict; the contract pays 0.5 IMD (from a shared pool when it has funds, so victims pay nothing)
///    and asks the swarm one yes/no question about on-chain facts. Only a signed "yes" puts S on the flagged list.
/// 2. The hunt. A victim hires hunters: they post a reward in IMD and prepay the swarm's fee for a number of checks.
///    Hunters bring leads from any wallet they like, with no name or account: either one on-chain hop ("S sent the
///    money to L") or a public page that ties the thief to an account. The swarm judges every lead from the hirer's
///    prepaid checks; a confirmed lead pays the hunter a quarter of the reward left. A hunter stakes the price of one
///    check, returned with the reward when the lead is right and given to the hirer's checks when it is wrong, so
///    guessing costs the guesser and not the victim. Private tips are encrypted to the hirer's key in the hunter's
///    browser; the hirer can pay for those directly.
/// 3. The audit. Anyone hires the swarm to read a contract's verified source and answer: can one privileged account
///    move users' funds without their signature? The fee on top of the swarm's price goes to the pool that pays for
///    victims' verdicts.
///
/// Wallets, apps and exchanges read `flagged`, `compromised` and `auditOf` for free before they send anything.
///
/// Trust assumption: the owner sets the oracle connection (intake, action, asset, price, attester), as the IdentityMD
/// oracle skill requires so a new oracle version needs no redeploy. Whoever holds the owner key therefore decides
/// which signer's answers count, and with that every verdict, lead payout and audit finding. The owner has no
/// function that withdraws the pool, rewards, prepaid checks or stakes directly.
contract LastSeenRegistry {
    enum Status {
        None,
        Open,
        Asked,
        Confirmed,
        Rejected,
        NoAnswer
    }
    enum Finding {
        None,
        Asked,
        NoPowerFound,
        CanTakeFunds,
        NoAnswer
    }

    // Storage structs the contract alone reads use one slot per field: the unoptimized build (foundry.toml is
    // protected) spends hundreds of runtime bytes on every packed field, and the runtime must stay under EIP-170.
    struct Case {
        address wallet; // the victim's wallet
        address suspect; // the address said to be taking funds out of it
        address opener;
        uint256 chainId; // where it happened
        uint256 fromBlock;
        uint256 toBlock;
        uint256 askedAt;
        Status status;
        uint256 bounty; // IMD reward left for hunters
    }

    struct Hunt {
        address hirer; // who posted the bounty; only they can pay private tips or close it
        uint256 openUntil;
        uint256 inFlight; // leads waiting for the swarm
        uint256 checks; // IMD the hirer prepaid so the swarm can judge leads
        bytes32 tipKey; // sha-256 of the hirer's public key; private tips are encrypted to it before they leave the hunter's browser
    }

    struct Lead {
        uint256 caseId;
        address from; // on-chain hop: the suspect, or an address an earlier confirmed lead reached
        address to; // on-chain hop: where the hunter says the funds went next; zero for a link
        address hunter; // any address the hunter chooses; nothing ties it to a person
        Status status;
        uint256 kind; // 1 = on-chain hop, 2 = public page
        uint256 askedAt;
    }

    struct Audit {
        address target;
        uint256 chainId;
        address asker;
        Finding finding;
    }

    /// A request as it was asked: the answer is judged against the oracle settings of that moment, so the owner can
    /// change the panel, the attester or the intake while requests are in flight without losing them.
    struct Pending {
        // one word, packed by hand (the unoptimized build cannot afford solc's field packing):
        // bits 0-7 kind (1 = case verdict, 2 = lead, 3 = audit), 8-47 askedAt, 48-63 panelSize, 64-79 quorum, 80-239 attester
        uint256 meta;
        IIntake intake;
        uint256 id;
        bytes32 questionHash; // what the oracle must sign for the answer to count; zero when the question cannot be pinned
    }

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("IdentityMD Oracle");
    bytes32 internal constant VERSION_HASH = keccak256("2");

    /// The question texts, built outside this contract so its runtime stays under EIP-170.
    LastSeenQuestions internal immutable questions;

    /// The owner: a constructor argument, never the deployer. Sets the oracle connection, the fee, the chains and the panel.
    address public owner;

    // the oracle connection: owner settings, so a new oracle version needs no redeploy
    IIntake public intake;
    bytes32 public action;
    IERC20 public asset;
    uint256 public price;
    address public attester;
    uint16 public panelSize = 5;
    uint16 public quorum = 4;
    uint256 public auditFee; // on top of the swarm's price; goes to the pool

    uint256 public pool; // IMD anyone can donate so that verdicts are free for victims
    // chains the oracle can read evidence on; a question about any other chain is refused and the 0.5 IMD is lost
    mapping(uint64 => bool) public supportedChain;
    Case[] internal _cases;
    Lead[] internal _leads;
    Audit[] internal _audits;
    mapping(uint256 => Hunt) public hunts;
    mapping(bytes32 => Pending) internal pending;
    mapping(uint256 => bytes32) internal _caseRequest; // case => the one request id whose answer may settle it
    mapping(address => bool) public flagged; // confirmed to take funds from other people's wallets
    mapping(address => bool) public compromised; // confirmed to have a key in someone else's hands
    mapping(uint256 => mapping(address => bool)) public reached; // case => addresses the confirmed trail has reached
    mapping(uint256 => mapping(address => bool)) internal _claimed; // case => hop targets already confirmed or waiting
    mapping(bytes32 => bool) internal _linkUsed;
    mapping(uint256 => bytes32) internal _linkKey; // page lead => its _linkUsed key, released when it fails or goes unanswered
    mapping(uint64 => mapping(address => Finding)) public auditOf; // chain => contract => the swarm's latest finding
    mapping(uint256 => uint256) internal _stake; // lead => IMD the hunter put down

    event CaseOpened(
        uint256 indexed caseId,
        address indexed wallet,
        address indexed suspect,
        uint64 chainId,
        uint64 fromBlock,
        uint64 toBlock
    );
    event VerdictAsked(uint256 indexed caseId, bytes32 requestId, bool fromPool);
    event Verdict(uint256 indexed caseId, bool confirmed, bytes32 oracleRequestId, uint16 agreed, uint16 panel);
    event BountyPosted(
        uint256 indexed caseId, address indexed hirer, uint256 reward, uint256 checks, uint256 openUntil, bytes32 tipKey
    );
    event BountyFunded(uint256 indexed caseId, uint256 amount, uint256 total);
    event BountyClosed(uint256 indexed caseId, uint256 returned);
    event LeadSubmitted(
        uint256 indexed leadId, uint256 indexed caseId, address from, address to, address hunter, bytes32 requestId
    );
    event LinkSubmitted(uint256 indexed leadId, uint256 indexed caseId, string url, address hunter, bytes32 requestId);
    event LeadVerdict(uint256 indexed leadId, bool confirmed, uint256 paid);
    event TipPaid(uint256 indexed caseId, bytes32 indexed tipId, address to, uint256 amount);
    event AuditAsked(uint256 indexed auditId, uint64 chainId, address indexed target, address asker, bytes32 requestId);
    event AuditResult(uint256 indexed auditId, bool canTakeFunds, uint16 agreed, uint16 panel);
    event AuditUnanswered(uint256 indexed auditId, bytes32 requestId);
    event PoolFunded(address indexed from, uint256 amount, uint256 total);

    event Delisted(address indexed who);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error BadInput();
    error NotOwner();
    error WrongStatus();
    error NotIntake();
    error NotHirer();
    error UnknownRequest();
    error BadAttestation();

    constructor(address owner_, IIntake intake_, bytes32 action_, IERC20 asset_, uint256 price_, address attester_) {
        if (owner_ == address(0)) revert BadInput();
        owner = owner_;
        questions = new LastSeenQuestions();
        intake = intake_;
        action = action_;
        asset = asset_;
        price = price_;
        attester = attester_;
        auditFee = price_;
        uint64[5] memory ids = [uint64(1), 56, 4663, 8453, 42161];
        for (uint256 i; i < ids.length; i++) {
            supportedChain[ids[i]] = true;
        }
    }

    // ---------------------------------------------------------------- cases

    function openCase(address wallet, address suspect, uint64 chainId, uint64 fromBlock, uint64 toBlock)
        external
        returns (uint256 id)
    {
        // the oracle carries block numbers as JSON numbers: above 2^53 - 1 it refuses the body and the price is lost
        if (
            wallet == address(0) || suspect == address(0) || wallet == suspect || !supportedChain[chainId]
                || fromBlock >= toBlock || toBlock > 9_007_199_254_740_991
        ) revert BadInput();
        id = _cases.length;
        Case storage c = _cases.push();
        c.wallet = wallet;
        c.suspect = suspect;
        c.opener = msg.sender;
        c.chainId = chainId;
        c.fromBlock = fromBlock;
        c.toBlock = toBlock;
        c.status = Status.Open;
        emit CaseOpened(id, wallet, suspect, chainId, fromBlock, toBlock);
    }

    /// Ask the swarm whether the case is true. Paid from the pool when it can cover it, otherwise by the caller.
    /// A case can be asked again if the last answer never arrived (after a day); the earlier request then no longer counts.
    function requestVerdict(uint256 caseId) external returns (bytes32 requestId) {
        Case storage c = _cases[caseId];
        bool retry = c.status == Status.Asked && block.timestamp > c.askedAt + 1 days;
        if (c.status != Status.Open && !retry) revert WrongStatus();
        bool fromPool = _pay();
        (bytes memory body, bytes32 questionHash) =
            _question(1, c.wallet, c.suspect, c.chainId, c.fromBlock, c.toBlock, "");
        delete pending[_caseRequest[caseId]]; // a stale answer to the earlier ask must not settle the case
        requestId = _ask(1, caseId, body, questionHash);
        _caseRequest[caseId] = requestId;
        c.status = Status.Asked;
        c.askedAt = block.timestamp;
        emit VerdictAsked(caseId, requestId, fromPool);
    }

    // ---------------------------------------------------------------- the hunt

    /// Hire hunters for a case: `reward` IMD for them, and `checks` swarm judgements paid up front (price each).
    /// One hirer per case; they can top up later. Open for `days_` (7 to 365) from now. An empty seat is anyone's,
    /// but the case belongs to its opener and to the victim: the opener takes the seat from any stranger, and the
    /// wallet takes it from anyone, so nobody can squat a victim's hunt. What the earlier hirer put in stays in the hunt.
    function postBounty(uint256 caseId, uint256 reward, uint16 checks, bytes32 tipKey, uint16 days_) external {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (c.status == Status.None || c.status == Status.Rejected) revert WrongStatus();
        if (
            h.hirer != address(0) && h.hirer != msg.sender && msg.sender != c.wallet
                && (msg.sender != c.opener || h.hirer == c.wallet)
        ) revert NotHirer();
        if (days_ < 7 || days_ > 365 || (h.hirer == address(0) && checks == 0)) revert BadInput();
        uint256 fees = uint256(checks) * price;
        _pull(reward + fees);
        if (tipKey != bytes32(0) || h.hirer != msg.sender) h.tipKey = tipKey; // a new hirer never inherits a key
        h.hirer = msg.sender;
        h.checks += fees;
        c.bounty += reward;
        uint256 until = block.timestamp + uint256(days_) * 1 days;
        if (until > h.openUntil) h.openUntil = until;
        emit BountyPosted(caseId, msg.sender, c.bounty, h.checks, h.openUntil, h.tipKey);
    }

    /// Anyone can add to the reward of a case that has a hunt still open. The reward is one balance at the hirer's
    /// disposal: they pay tips from it and take back what is left, so a donation is a gift to the hirer's hunt.
    function fundBounty(uint256 caseId, uint256 amount) external {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (h.hirer == address(0) || block.timestamp > h.openUntil || c.status == Status.Rejected || amount == 0) {
            revert WrongStatus();
        }
        _pull(amount);
        c.bounty += amount;
        emit BountyFunded(caseId, amount, c.bounty);
    }

    /// An on-chain lead: funds went from `from` to `to`. `from` must be the suspect or an address the confirmed trail reached;
    /// `to` can be neither the victim's wallet nor the suspect, since a hop back to them discloses nothing.
    function submitLead(uint256 caseId, address from, address to) external returns (uint256 leadId, bytes32 requestId) {
        Case storage c = _cases[caseId];
        if (
            to == address(0) || to == from || to == c.wallet || to == c.suspect || _claimed[caseId][to]
                || (from != c.suspect && !reached[caseId][from])
        ) revert BadInput();
        _claimed[caseId][to] = true;
        leadId = _newLead(caseId, from, to, 1);
        (bytes memory body, bytes32 questionHash) = _question(2, from, to, c.chainId, c.fromBlock, c.toBlock, "");
        requestId = _ask(2, leadId, body, questionHash);
        emit LeadSubmitted(leadId, caseId, from, to, msg.sender, requestId);
    }

    /// A public page that ties the suspect to an account, an exchange deposit or a person. The swarm reads the page.
    /// The address is whatever the hunter wants paid; post it from a fresh wallet to stay anonymous.
    /// A page counts once per case whatever fragment, query string, host case or trailing slash the URL carries.
    function submitLink(uint256 caseId, string calldata url) external returns (uint256 leadId, bytes32 requestId) {
        Case storage c = _cases[caseId];
        // refuses an unsafe URL; `page` is the hash of the URL without fragment, query or trailing slash, host lowercased
        (bytes memory body, bytes32 page) = _question(3, c.wallet, c.suspect, c.chainId, c.fromBlock, c.toBlock, url);
        bytes32 k = keccak256(abi.encodePacked(caseId, page));
        if (_linkUsed[k]) revert BadInput();
        _linkUsed[k] = true;
        leadId = _newLead(caseId, address(0), address(0), 2);
        _linkKey[leadId] = k;
        requestId = _ask(2, leadId, body, bytes32(0));
        emit LinkSubmitted(leadId, caseId, url, msg.sender, requestId);
    }

    /// For a private tip the swarm cannot check: the hirer reads it and pays from the reward directly.
    /// Not while a lead is waiting for the swarm: a confirmed lead is paid from the reward that was posted when it went in.
    function payTip(uint256 caseId, bytes32 tipId, address to, uint256 amount) external {
        Case storage c = _cases[caseId];
        if (msg.sender != hunts[caseId].hirer) revert NotHirer();
        if (hunts[caseId].inFlight != 0) revert WrongStatus();
        if (to == address(0) || amount == 0 || amount > c.bounty) revert BadInput();
        c.bounty -= amount;
        _push(to, amount);
        emit TipPaid(caseId, tipId, to, amount);
    }

    /// After the hunt's end date, or as soon as the swarm rejects the case, with no lead waiting, the hirer takes
    /// back what is left.
    function closeBounty(uint256 caseId) external {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (msg.sender != h.hirer) revert NotHirer();
        if ((block.timestamp <= h.openUntil && c.status != Status.Rejected) || h.inFlight != 0) revert WrongStatus();
        uint256 back = c.bounty + h.checks;
        c.bounty = 0;
        h.checks = 0;
        if (back > 0) _push(msg.sender, back);
        emit BountyClosed(caseId, back);
    }

    /// If the swarm never answers a lead, the hunter gets the stake back after two days. The check is spent.
    /// Only the hunter or the hirer may give up on a lead: a late answer to a reclaimed lead pays nobody.
    function reclaimStake(uint256 leadId) external {
        Lead storage l = _leads[leadId];
        if (msg.sender != l.hunter && msg.sender != hunts[l.caseId].hirer) revert NotHirer();
        if (l.status != Status.Asked || block.timestamp <= l.askedAt + 2 days) revert WrongStatus();
        l.status = Status.NoAnswer;
        hunts[l.caseId].inFlight--;
        _release(leadId);
        uint256 s = _stake[leadId];
        _stake[leadId] = 0;
        _push(l.hunter, s);
    }

    function _newLead(uint256 caseId, address from, address to, uint8 kind) internal returns (uint256 leadId) {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (h.hirer == address(0) || block.timestamp > h.openUntil || c.status == Status.Rejected || h.checks < price) {
            revert WrongStatus();
        }
        _pull(price); // the stake
        leadId = _leads.length;
        Lead storage l = _leads.push();
        l.caseId = caseId;
        l.from = from;
        l.to = to;
        l.hunter = msg.sender;
        l.status = Status.Asked;
        l.kind = kind;
        l.askedAt = block.timestamp;
        _stake[leadId] = price;
        h.checks -= price;
        h.inFlight++;
    }

    /// A hop or page that was wrong or never judged can be submitted again.
    function _release(uint256 leadId) internal {
        Lead storage l = _leads[leadId];
        if (l.kind == 1) _claimed[l.caseId][l.to] = false;
        else _linkUsed[_linkKey[leadId]] = false;
    }

    // ---------------------------------------------------------------- the audit

    /// Hire the swarm to read a contract. Costs the swarm's price plus `auditFee`, which goes to the victims' pool.
    function requestAudit(uint64 chainId, address target) external returns (uint256 auditId, bytes32 requestId) {
        if (target == address(0) || !supportedChain[chainId]) revert BadInput();
        _pull(price + auditFee);
        if (auditFee > 0) {
            pool += auditFee;
            emit PoolFunded(msg.sender, auditFee, pool);
        }
        auditId = _audits.length;
        Audit storage au = _audits.push();
        au.target = target;
        au.chainId = chainId;
        au.asker = msg.sender;
        au.finding = Finding.Asked;
        if (auditOf[chainId][target] == Finding.None) auditOf[chainId][target] = Finding.Asked;
        (bytes memory body,) = _question(4, address(0), target, chainId, 0, 0, "");
        requestId = _ask(3, auditId, body, bytes32(0));
        emit AuditAsked(auditId, chainId, target, msg.sender, requestId);
    }

    /// If the swarm never answers an audit (a refused body, a split panel, a lost callback), anyone can mark it
    /// unanswered after two days so the asker knows the fee is spent and the target can be asked about again.
    function reclaimAudit(bytes32 requestId) external {
        Pending storage p = pending[requestId];
        uint256 m = p.meta;
        if (uint8(m) != 3 || block.timestamp <= uint40(m >> 8) + 2 days) revert WrongStatus();
        uint256 auditId = p.id;
        delete pending[requestId];
        Audit storage au = _audits[auditId];
        au.finding = Finding.NoAnswer;
        if (auditOf[uint64(au.chainId)][au.target] == Finding.Asked) {
            auditOf[uint64(au.chainId)][au.target] = Finding.None;
        }
        emit AuditUnanswered(auditId, requestId);
    }

    // ---------------------------------------------------------------- the answer

    /// Called by the Intake with the swarm's signed answer (selector 0x510379c7). It gets 200,000 gas, once.
    /// The answer is judged against the intake, attester and panel recorded when the request was asked and paid for.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        Pending storage p = pending[requestId];
        uint256 m = p.meta;
        uint8 kind = uint8(m);
        if (kind == 0) revert UnknownRequest();
        if (msg.sender != address(p.intake)) revert NotIntake();
        uint256 id = p.id;
        bytes32 questionHash = p.questionHash;
        bool yes = _accept(a, signature, address(uint160(m >> 80)), uint16(m >> 48), uint16(m >> 64));
        delete pending[requestId];
        // the signature covers the question's hash: an answer to any other question is refused, whoever paired them
        if (questionHash != bytes32(0) && a.questionHash != questionHash) revert BadAttestation();
        if (kind == 1) {
            Case storage c = _cases[id];
            c.status = yes ? Status.Confirmed : Status.Rejected;
            if (yes) {
                flagged[c.suspect] = true;
                compromised[c.wallet] = true;
            }
            emit Verdict(id, yes, a.requestId, a.agreed, a.panelSize);
        } else if (kind == 2) {
            _settleLead(id, yes);
        } else {
            Audit storage au = _audits[id];
            au.finding = yes ? Finding.CanTakeFunds : Finding.NoPowerFound;
            // a signed "can take funds" stays on the public record: a cheaper re-roll cannot erase it
            if (yes || auditOf[uint64(au.chainId)][au.target] != Finding.CanTakeFunds) {
                auditOf[uint64(au.chainId)][au.target] = au.finding;
            }
            emit AuditResult(id, yes, a.agreed, a.panelSize);
        }
    }

    function _settleLead(uint256 leadId, bool yes) internal {
        Lead storage l = _leads[leadId];
        if (l.status != Status.Asked) return; // the stake was already reclaimed
        Case storage c = _cases[l.caseId];
        Hunt storage h = hunts[l.caseId];
        l.status = yes ? Status.Confirmed : Status.Rejected;
        h.inFlight--;
        uint256 s = _stake[leadId];
        _stake[leadId] = 0;
        uint256 paid;
        if (yes) {
            if (l.kind == 1) reached[l.caseId][l.to] = true;
            paid = c.bounty / 4;
            c.bounty -= paid;
            _push(l.hunter, paid + s);
        } else {
            _release(leadId);
            h.checks += s; // a wrong lead pays for its own check
        }
        emit LeadVerdict(leadId, yes, paid);
    }

    /// The signer, the panel and the quorum must be at least what the request asked for, and the panel must have agreed.
    function _accept(
        OracleAttestation.Attestation calldata a,
        bytes calldata signature,
        address signer_,
        uint16 panel_,
        uint16 quorum_
    ) internal view returns (bool) {
        if (
            _recover(attestationDigest(a), signature) != signer_ || a.answerType != 0 || a.agreed < a.quorum
                || a.quorum < quorum_ || a.panelSize < panel_ || block.timestamp > a.expiresAt
        ) revert BadAttestation();
        return abi.decode(a.answer, (bool));
    }

    /// A 65-byte r‖s‖v signature, as the oracle's signer produces. A malleated copy recovers the same signer and
    /// cannot replay: the pending id is deleted before the signature is checked.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address who) {
        if (sig.length != 65) revert BadAttestation();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        who = ecrecover(digest, v, r, s);
        if (who == address(0)) revert BadAttestation();
    }

    /// The EIP-712 digest the oracle signs for this contract: domain "IdentityMD Oracle" version "2", this chain, this address.
    function attestationDigest(OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked("\x19\x01", domain, _structHash(a)));
    }

    /// EIP-712 hashStruct of the attestation: the type hash, then the 15 fields as the ABI already lays them out in
    /// calldata (every one a static word, `answer` as an offset), with the `answer` word replaced by keccak256(answer).
    function _structHash(OracleAttestation.Attestation calldata a) internal pure returns (bytes32 h) {
        bytes32 answerHash = keccak256(a.answer);
        bytes32 typehash = OracleAttestation.TYPEHASH;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, typehash)
            calldatacopy(add(p, 32), a, 480)
            mstore(add(p, 160), answerHash)
            h := keccak256(p, 512)
        }
    }

    // ---------------------------------------------------------------- the pool

    function donate(uint256 amount) external {
        _pull(amount);
        pool += amount;
        emit PoolFunded(msg.sender, amount, pool);
    }

    /// IMD is a plain ERC-20 that returns true; a transfer that returns false or reverts stops the call.
    function _pull(uint256 amount) internal {
        if (!asset.transferFrom(msg.sender, address(this), amount)) revert BadInput();
    }

    function _push(address to, uint256 amount) internal {
        if (!asset.transfer(to, amount)) revert BadInput();
    }

    function _pay() internal returns (bool fromPool) {
        if (pool >= price) {
            pool -= price;
            return true;
        }
        _pull(price);
        return false;
    }

    function _question(
        uint8 kind,
        address a,
        address b,
        uint256 chainId,
        uint256 fromBlock,
        uint256 toBlock,
        string memory url
    ) internal view returns (bytes memory, bytes32) {
        return questions.build(kind, a, b, uint64(chainId), uint64(fromBlock), uint64(toBlock), panelSize, quorum, url);
    }

    function _ask(uint8 kind, uint256 id, bytes memory body, bytes32 questionHash)
        internal
        returns (bytes32 requestId)
    {
        if (!asset.approve(address(intake), price)) revert BadInput();
        requestId = intake.request(
            action, body, IIntake.Callback(address(this), this.onOracleResult.selector), address(asset), price
        );
        uint256 meta = uint256(kind) | (block.timestamp & 0xFFFFFFFFFF) << 8 | uint256(panelSize) << 48
            | uint256(quorum) << 64 | uint256(uint160(attester)) << 80;
        pending[requestId] = Pending(meta, intake, id, questionHash);
    }

    // ---------------------------------------------------------------- reading

    function counts() external view returns (uint256 cases, uint256 leads, uint256 audits) {
        return (_cases.length, _leads.length, _audits.length);
    }

    function getCase(uint256 id)
        external
        view
        returns (
            address wallet,
            address suspect,
            address opener,
            uint64 chainId,
            uint64 fromBlock,
            uint64 toBlock,
            uint64 askedAt,
            Status status,
            uint256 bounty
        )
    {
        Case storage c = _cases[id];
        return (
            c.wallet,
            c.suspect,
            c.opener,
            uint64(c.chainId),
            uint64(c.fromBlock),
            uint64(c.toBlock),
            uint64(c.askedAt),
            c.status,
            c.bounty
        );
    }

    // ---------------------------------------------------------------- owner settings

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert BadInput();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    /// Takes an address off `flagged` and `compromised`: a listing the swarm confirmed on a question that was true
    /// of a relayer, bundler or solver acting for the wallet, or that a later answer contradicts, can be undone.
    function delist(address who) external onlyOwner {
        flagged[who] = false;
        compromised[who] = false;
        emit Delisted(who);
    }

    function setOracle(IIntake intake_, bytes32 action_, IERC20 asset_, uint256 price_, address attester_)
        external
        onlyOwner
    {
        // donated, bounty and prepaid IMD stay in the old token, so the token itself can only change while the contract holds none
        if (address(asset_) != address(asset) && asset.balanceOf(address(this)) != 0) revert BadInput();
        intake = intake_;
        action = action_;
        asset = asset_;
        price = price_;
        attester = attester_;
    }

    function setAuditFee(uint256 fee) external onlyOwner {
        auditFee = fee;
    }

    function setSupportedChain(uint64 chainId, bool ok) external onlyOwner {
        supportedChain[chainId] = ok;
    }

    function setPanel(uint16 panelSize_, uint16 quorum_) external onlyOwner {
        if (quorum_ < 2 || quorum_ > panelSize_) revert BadInput();
        panelSize = panelSize_;
        quorum = quorum_;
    }
}

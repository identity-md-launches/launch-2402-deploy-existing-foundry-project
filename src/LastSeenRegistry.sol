// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IIntake, OracleAttestation} from "./IIntake.sol";

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
contract LastSeenRegistry is EIP712, Ownable {
    using SafeERC20 for IERC20;
    using Strings for address;
    using Strings for uint256;

    enum Status { None, Open, Asked, Confirmed, Rejected, NoAnswer }
    enum Finding { None, Asked, NoPowerFound, CanTakeFunds }

    struct Case {
        address wallet;     // the victim's wallet
        address suspect;    // the address said to be taking funds out of it
        address opener;
        uint64 chainId;     // where it happened
        uint64 fromBlock;
        uint64 toBlock;
        uint64 askedAt;
        Status status;
        uint256 bounty;     // IMD reward left for hunters
    }

    struct Hunt {
        address hirer;      // who posted the bounty; only they can pay private tips or close it
        uint64 openUntil;
        uint32 inFlight;    // leads waiting for the swarm
        uint256 checks;     // IMD the hirer prepaid so the swarm can judge leads
        bytes32 tipKey;     // sha-256 of the hirer's public key; private tips are encrypted to it before they leave the hunter's browser
    }

    struct Lead {
        uint256 caseId;
        address from;       // on-chain hop: the suspect, or an address an earlier confirmed lead reached
        address to;         // on-chain hop: where the hunter says the funds went next; zero for a link
        address hunter;     // any address the hunter chooses; nothing ties it to a person
        Status status;
        uint8 kind;         // 1 = on-chain hop, 2 = public page
        uint64 askedAt;
    }

    struct Audit {
        address target;
        uint64 chainId;
        address asker;
        Finding finding;
    }

    struct Pending {
        uint8 kind;         // 1 = case verdict, 2 = lead, 3 = audit
        uint256 id;
    }

    // the oracle connection: owner settings, so a new oracle version needs no redeploy
    IIntake public intake;
    bytes32 public action;
    IERC20 public asset;
    uint256 public price;
    address public attester;
    uint16 public panelSize = 5;
    uint16 public quorum = 4;
    uint256 public auditFee;  // on top of the swarm's price; goes to the pool

    uint256 public pool;     // IMD anyone can donate so that verdicts are free for victims
    // chains the oracle can read evidence on; a question about any other chain is refused and the 0.5 IMD is lost
    mapping(uint64 => bool) public supportedChain;
    Case[] internal _cases;
    Lead[] internal _leads;
    Audit[] internal _audits;
    mapping(uint256 => Hunt) public hunts;
    mapping(bytes32 => Pending) public pending;
    mapping(address => bool) public flagged;      // confirmed to take funds from other people's wallets
    mapping(address => bool) public compromised;  // confirmed to have a key in someone else's hands
    mapping(uint256 => mapping(address => bool)) public reached; // case => addresses the confirmed trail has reached
    mapping(uint256 => mapping(address => bool)) internal _claimed; // case => hop targets already confirmed or waiting
    mapping(bytes32 => bool) internal _linkUsed;
    mapping(uint64 => mapping(address => Finding)) public auditOf; // chain => contract => the swarm's latest finding
    mapping(uint256 => uint256) internal _stake;  // lead => IMD the hunter put down

    event CaseOpened(uint256 indexed caseId, address indexed wallet, address indexed suspect, uint64 chainId, uint64 fromBlock, uint64 toBlock);
    event VerdictAsked(uint256 indexed caseId, bytes32 requestId, bool fromPool);
    event Verdict(uint256 indexed caseId, bool confirmed, bytes32 oracleRequestId, uint16 agreed, uint16 panel);
    event BountyPosted(uint256 indexed caseId, address indexed hirer, uint256 reward, uint256 checks, uint64 openUntil, bytes32 tipKey);
    event BountyFunded(uint256 indexed caseId, uint256 amount, uint256 total);
    event BountyClosed(uint256 indexed caseId, uint256 returned);
    event LeadSubmitted(uint256 indexed leadId, uint256 indexed caseId, address from, address to, address hunter, bytes32 requestId);
    event LinkSubmitted(uint256 indexed leadId, uint256 indexed caseId, string url, address hunter, bytes32 requestId);
    event LeadVerdict(uint256 indexed leadId, bool confirmed, uint256 paid);
    event TipPaid(uint256 indexed caseId, bytes32 indexed tipId, address to, uint256 amount);
    event AuditAsked(uint256 indexed auditId, uint64 chainId, address indexed target, address asker, bytes32 requestId);
    event AuditResult(uint256 indexed auditId, bool canTakeFunds, uint16 agreed, uint16 panel);
    event PoolFunded(address indexed from, uint256 amount, uint256 total);

    error BadInput();
    error WrongStatus();
    error NotIntake();
    error NotHirer();
    error UnknownRequest();
    error BadAttestation();

    constructor(address owner_, IIntake intake_, bytes32 action_, IERC20 asset_, uint256 price_, address attester_)
        EIP712("IdentityMD Oracle", "2")
        Ownable(owner_)
    {
        intake = intake_;
        action = action_;
        asset = asset_;
        price = price_;
        attester = attester_;
        auditFee = price_;
        uint64[5] memory ids = [uint64(1), 56, 4663, 8453, 42161];
        for (uint256 i; i < ids.length; i++) supportedChain[ids[i]] = true;
    }

    // ---------------------------------------------------------------- cases

    function openCase(address wallet, address suspect, uint64 chainId, uint64 fromBlock, uint64 toBlock) external returns (uint256 id) {
        if (wallet == address(0) || suspect == address(0) || wallet == suspect || !supportedChain[chainId] || fromBlock >= toBlock) revert BadInput();
        id = _cases.length;
        _cases.push(Case(wallet, suspect, msg.sender, chainId, fromBlock, toBlock, 0, Status.Open, 0));
        emit CaseOpened(id, wallet, suspect, chainId, fromBlock, toBlock);
    }

    /// Ask the swarm whether the case is true. Paid from the pool when it can cover it, otherwise by the caller.
    /// A case can be asked again if the last answer never arrived (after a day) or the panel could not agree.
    function requestVerdict(uint256 caseId) external returns (bytes32 requestId) {
        Case storage c = _cases[caseId];
        bool retry = c.status == Status.NoAnswer || (c.status == Status.Asked && block.timestamp > c.askedAt + 1 days);
        if (c.status != Status.Open && !retry) revert WrongStatus();
        bool fromPool = _pay();
        requestId = _ask(_verdictBody(c));
        pending[requestId] = Pending(1, caseId);
        c.status = Status.Asked;
        c.askedAt = uint64(block.timestamp);
        emit VerdictAsked(caseId, requestId, fromPool);
    }

    // ---------------------------------------------------------------- the hunt

    /// Hire hunters for a case: `reward` IMD for them, and `checks` swarm judgements paid up front (price each).
    /// One hirer per case; they can top up later. Open for `days_` (7 to 365) from now.
    function postBounty(uint256 caseId, uint256 reward, uint16 checks, bytes32 tipKey, uint16 days_) external {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (c.status == Status.None || c.status == Status.Rejected) revert WrongStatus();
        if (h.hirer != address(0) && h.hirer != msg.sender) revert NotHirer();
        if (days_ < 7 || days_ > 365 || (h.hirer == address(0) && checks == 0)) revert BadInput();
        uint256 fees = uint256(checks) * price;
        asset.safeTransferFrom(msg.sender, address(this), reward + fees);
        h.hirer = msg.sender;
        h.checks += fees;
        c.bounty += reward;
        if (tipKey != bytes32(0)) h.tipKey = tipKey;
        uint64 until = uint64(block.timestamp + uint256(days_) * 1 days);
        if (until > h.openUntil) h.openUntil = until;
        emit BountyPosted(caseId, msg.sender, c.bounty, h.checks, h.openUntil, h.tipKey);
    }

    /// Anyone can add to the reward of a case that has a hunt.
    function fundBounty(uint256 caseId, uint256 amount) external {
        Case storage c = _cases[caseId];
        if (hunts[caseId].hirer == address(0) || c.status == Status.Rejected || amount == 0) revert WrongStatus();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        c.bounty += amount;
        emit BountyFunded(caseId, amount, c.bounty);
    }

    /// An on-chain lead: funds went from `from` to `to`. `from` must be the suspect or an address the confirmed trail reached.
    function submitLead(uint256 caseId, address from, address to) external returns (uint256 leadId, bytes32 requestId) {
        Case storage c = _cases[caseId];
        if (to == address(0) || to == from || _claimed[caseId][to] || (from != c.suspect && !reached[caseId][from])) revert BadInput();
        _claimed[caseId][to] = true;
        leadId = _newLead(caseId, from, to, 1);
        requestId = _askForHunt(leadId, _leadBody(c, from, to));
        emit LeadSubmitted(leadId, caseId, from, to, msg.sender, requestId);
    }

    /// A public page that ties the suspect to an account, an exchange deposit or a person. The swarm reads the page.
    /// The address is whatever the hunter wants paid; post it from a fresh wallet to stay anonymous.
    function submitLink(uint256 caseId, string calldata url) external returns (uint256 leadId, bytes32 requestId) {
        bytes32 k = keccak256(abi.encodePacked(caseId, url));
        if (!_safeUrl(bytes(url)) || _linkUsed[k]) revert BadInput();
        _linkUsed[k] = true;
        leadId = _newLead(caseId, address(0), address(0), 2);
        requestId = _askForHunt(leadId, _linkBody(_cases[caseId], url));
        emit LinkSubmitted(leadId, caseId, url, msg.sender, requestId);
    }

    /// For a private tip the swarm cannot check: the hirer reads it and pays from the reward directly.
    function payTip(uint256 caseId, bytes32 tipId, address to, uint256 amount) external {
        Case storage c = _cases[caseId];
        if (msg.sender != hunts[caseId].hirer) revert NotHirer();
        if (to == address(0) || amount == 0 || amount > c.bounty) revert BadInput();
        c.bounty -= amount;
        asset.safeTransfer(to, amount);
        emit TipPaid(caseId, tipId, to, amount);
    }

    /// After the hunt's end date, with no lead waiting, the hirer takes back what is left.
    function closeBounty(uint256 caseId) external {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (msg.sender != h.hirer) revert NotHirer();
        if (block.timestamp <= h.openUntil || h.inFlight != 0) revert WrongStatus();
        uint256 back = c.bounty + h.checks;
        c.bounty = 0;
        h.checks = 0;
        if (back > 0) asset.safeTransfer(msg.sender, back);
        emit BountyClosed(caseId, back);
    }

    /// If the swarm never answers a lead, the hunter gets the stake back after two days. The check is spent.
    function reclaimStake(uint256 leadId) external {
        Lead storage l = _leads[leadId];
        if (l.status != Status.Asked || block.timestamp <= l.askedAt + 2 days) revert WrongStatus();
        l.status = Status.NoAnswer;
        hunts[l.caseId].inFlight--;
        if (l.kind == 1) _claimed[l.caseId][l.to] = false;
        uint256 s = _stake[leadId];
        _stake[leadId] = 0;
        asset.safeTransfer(l.hunter, s);
    }

    function _newLead(uint256 caseId, address from, address to, uint8 kind) internal returns (uint256 leadId) {
        Case storage c = _cases[caseId];
        Hunt storage h = hunts[caseId];
        if (h.hirer == address(0) || block.timestamp > h.openUntil || c.status == Status.Rejected || h.checks < price) revert WrongStatus();
        asset.safeTransferFrom(msg.sender, address(this), price); // the stake
        leadId = _leads.length;
        _leads.push(Lead(caseId, from, to, msg.sender, Status.Asked, kind, uint64(block.timestamp)));
        _stake[leadId] = price;
        h.checks -= price;
        h.inFlight++;
    }

    function _askForHunt(uint256 leadId, bytes memory body) internal returns (bytes32 requestId) {
        requestId = _ask(body);
        pending[requestId] = Pending(2, leadId);
    }

    // ---------------------------------------------------------------- the audit

    /// Hire the swarm to read a contract. Costs the swarm's price plus `auditFee`, which goes to the victims' pool.
    function requestAudit(uint64 chainId, address target) external returns (uint256 auditId, bytes32 requestId) {
        if (target == address(0) || !supportedChain[chainId]) revert BadInput();
        asset.safeTransferFrom(msg.sender, address(this), price + auditFee);
        if (auditFee > 0) {
            pool += auditFee;
            emit PoolFunded(msg.sender, auditFee, pool);
        }
        auditId = _audits.length;
        _audits.push(Audit(target, chainId, msg.sender, Finding.Asked));
        if (auditOf[chainId][target] == Finding.None) auditOf[chainId][target] = Finding.Asked;
        requestId = _ask(_auditBody(chainId, target));
        pending[requestId] = Pending(3, auditId);
        emit AuditAsked(auditId, chainId, target, msg.sender, requestId);
    }

    // ---------------------------------------------------------------- the answer

    /// Called by the Intake with the swarm's signed answer (selector 0x510379c7). It gets 200,000 gas, once.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature) external {
        if (msg.sender != address(intake)) revert NotIntake();
        Pending memory p = pending[requestId];
        if (p.kind == 0) revert UnknownRequest();
        delete pending[requestId];
        bool yes = _accept(a, signature);
        if (p.kind == 1) {
            Case storage c = _cases[p.id];
            c.status = yes ? Status.Confirmed : Status.Rejected;
            if (yes) {
                flagged[c.suspect] = true;
                compromised[c.wallet] = true;
            }
            emit Verdict(p.id, yes, a.requestId, a.agreed, a.panelSize);
        } else if (p.kind == 2) {
            _settleLead(p.id, yes);
        } else {
            Audit storage au = _audits[p.id];
            au.finding = yes ? Finding.CanTakeFunds : Finding.NoPowerFound;
            auditOf[au.chainId][au.target] = au.finding;
            emit AuditResult(p.id, yes, a.agreed, a.panelSize);
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
            asset.safeTransfer(l.hunter, paid + s);
        } else {
            if (l.kind == 1) _claimed[l.caseId][l.to] = false;
            h.checks += s; // a wrong lead pays for its own check
        }
        emit LeadVerdict(leadId, yes, paid);
    }

    function _accept(OracleAttestation.Attestation calldata a, bytes calldata signature) internal view returns (bool) {
        address signer = ECDSA.recover(_hashTypedDataV4(OracleAttestation.hash(a)), signature);
        if (signer != attester || a.answerType != 0 || a.agreed < a.quorum || a.panelSize < panelSize || block.timestamp > a.expiresAt) revert BadAttestation();
        return abi.decode(a.answer, (bool));
    }

    // ---------------------------------------------------------------- the pool

    function donate(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        pool += amount;
        emit PoolFunded(msg.sender, amount, pool);
    }

    function _pay() internal returns (bool fromPool) {
        if (pool >= price) {
            pool -= price;
            return true;
        }
        asset.safeTransferFrom(msg.sender, address(this), price);
        return false;
    }

    function _ask(bytes memory body) internal returns (bytes32) {
        asset.forceApprove(address(intake), price);
        return intake.request(action, body, IIntake.Callback(address(this), this.onOracleResult.selector), address(asset), price);
    }

    // ---------------------------------------------------------------- the questions, as the swarm reads them

    function _panel() internal view returns (bytes memory) {
        return abi.encodePacked('"answerType":"bool","panelSize":', uint256(panelSize).toString(), ',"quorum":', uint256(quorum).toString(), ',"validForSeconds":86400');
    }

    function _window(Case storage c) internal view returns (bytes memory) {
        return abi.encodePacked(
            '"chainId":', uint256(c.chainId).toString(), ',"window":{"fromBlock":', uint256(c.fromBlock).toString(), ',"toBlock":', uint256(c.toBlock).toString(),
            '},"evidence":"chain",', _panel()
        );
    }

    function _verdictBody(Case storage c) internal view returns (bytes memory) {
        string memory w = c.wallet.toHexString();
        string memory s = c.suspect.toHexString();
        return abi.encodePacked(
            '{"v":1,"question":"Within the window, did address ', s, ' take tokens or native coin out of wallet ', w,
            ' using transactions that ', s, ' sent itself? Count a transfer out of ', w, ' when the transaction sender is ', s,
            ', including EIP-7702 transactions that run code as ', w, '. Answer true if there is at least one.",',
            _window(c),
            ',"definitions":{"take":"A token transfer event or native coin movement from ', w, ' to any address, inside a transaction whose sender (tx.from) is ', s,
            '.","not counted":"Transactions that ', w, ' itself signed and sent."}}'
        );
    }

    function _leadBody(Case storage c, address from, address to) internal view returns (bytes memory) {
        return abi.encodePacked(
            '{"v":1,"question":"Within the window, did address ', from.toHexString(), ' send tokens or native coin to address ', to.toHexString(),
            '? Answer true if there is at least one such transfer.",',
            _window(c),
            ',"definitions":{"send":"A token transfer event or native coin movement whose sender is the first address and whose receiver is the second."}}'
        );
    }

    function _linkBody(Case storage c, string calldata url) internal view returns (bytes memory) {
        string memory s = c.suspect.toHexString();
        return abi.encodePacked(
            '{"v":1,"question":"Does the public page at ', url, ' show evidence that ties address ', s,
            ' to a specific online account, exchange account, service or person? Address ', s, ' took funds from wallet ', c.wallet.toHexString(),
            '. Answer true only if the page itself shows that link.","chainId":', uint256(c.chainId).toString(),
            ',"window":{"hours":24},"evidence":"panel",', _panel(),
            // the hunter's page is unknown to the wording screen, so the reading is pinned in definitions and the screen skipped
            ',"definitions":{"ties":"The page shows the address together with an account name, handle, deposit record or other identifier, in a way a reader can check.","missing":"If the page cannot be opened, report inability rather than guessing."},"guards":{"sources":["',
            url, '"],"minSources":1},"allowAmbiguous":true}'
        );
    }

    function _auditBody(uint64 chainId, address target) internal view returns (bytes memory) {
        string memory t = target.toHexString();
        string memory id = uint256(chainId).toString();
        return abi.encodePacked(
            '{"v":1,"question":"Can a single privileged account (an owner, an admin, or a hard-coded address) use the contract at ', t, ' on chain ', id,
            ' to move tokens or native coin that users deposited in it or approved to it, to an address of its choosing, without that user signing for the move? Read the contract\'s verified source code. Answer true if yes.","chainId":', id,
            ',"window":{"hours":24},"evidence":"panel",', _panel(),
            ',"definitions":{"source":"The verified source on Sourcify: https://sourcify.dev/server/v2/contract/', id, '/', t,
            '?fields=sources . Include code reached through a proxy or delegatecall.","privileged":"Any role or address ordinary users do not hold, including an upgrade admin who can replace the code.","missing":"If no verified source exists, report inability rather than guessing."},"guards":{"sources":["https://sourcify.dev/","https://repo.sourcify.dev/"],"minSources":1}}'
        );
    }

    /// https:// followed by 4 to 292 printable characters, none of which could break the JSON the swarm reads.
    function _safeUrl(bytes calldata u) internal pure returns (bool) {
        if (u.length < 12 || u.length > 300) return false;
        bytes8 head = bytes8(u[:8]);
        if (head != bytes8("https://")) return false;
        for (uint256 i = 8; i < u.length; i++) {
            bytes1 ch = u[i];
            if (ch <= 0x20 || ch >= 0x7f || ch == '"' || ch == "\\") return false;
        }
        return true;
    }

    // ---------------------------------------------------------------- reading

    function caseCount() external view returns (uint256) { return _cases.length; }
    function leadCount() external view returns (uint256) { return _leads.length; }
    function auditCount() external view returns (uint256) { return _audits.length; }
    function getCase(uint256 id) external view returns (Case memory) { return _cases[id]; }
    function getLead(uint256 id) external view returns (Lead memory) { return _leads[id]; }
    function getAudit(uint256 id) external view returns (Audit memory) { return _audits[id]; }
    function verdictBody(uint256 caseId) external view returns (string memory) { return string(_verdictBody(_cases[caseId])); }
    function auditBody(uint64 chainId, address target) external view returns (string memory) { return string(_auditBody(chainId, target)); }

    // ---------------------------------------------------------------- owner settings

    function setOracle(IIntake intake_, bytes32 action_, IERC20 asset_, uint256 price_, address attester_) external onlyOwner {
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

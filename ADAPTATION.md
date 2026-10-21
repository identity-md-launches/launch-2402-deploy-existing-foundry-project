# Adaptation for the Robinhood Chain launch

Launch: `evm_contracts`, chain 4663, one application contract, `LastSeenRegistry`, with the six constructor
arguments the brief lists (`owner_` = `$owner`, then the Intake, action id, IMD, price and attester). No token,
no pool. The constructor arguments, the public read surface used by wallets (`flagged`, `compromised`,
`auditOf`), every event and every user function keep their names and behaviour, except where a launch rule or
a reproduced audit finding required a change. Each change is listed below with the file and the reason.
Tests: `forge test` runs 50 tests (the 20 original, `Bodies.t.sol`, 14 in `test/Adaptation.t.sol` for the first
round and 15 in `test/Revision.t.sol` for the two review rounds).

## Launch rules

1. **Runtime size (audit, high, reproduced).** `forge build --sizes` with the project's own `foundry.toml`
   reported a 35,689-byte runtime; the launch floor refuses anything over 24,576 bytes and `foundry.toml` is
   protected, so the optimizer cannot be turned on. Changes, all in `src/LastSeenRegistry.sol` unless noted:
   - The question texts moved to a new stateless contract, `src/LastSeenQuestions.sol`, which the registry
     creates in its constructor (no outside contract is called, as the empty-chain floor requires) and reads
     with STATICCALL through one entry point, `build`. The runtime is now 24,372 bytes
     (`test_runtimeFitsEip170`), the helper 11,340.
   - OpenZeppelin `EIP712` and `ECDSA` were replaced by an inline domain separator (`attestationDigest`), a
     calldata-copy `hashStruct` and a direct `ecrecover`. The digest is unchanged: `test_digestMatchesTheProtocol`
     reproduces the protocol's signed vector and the original signature tests still pass. `eip712Domain()`
     (ERC-5267) is no longer exposed.
   - OpenZeppelin `Ownable` was replaced by an `owner` set from the constructor argument, `onlyOwner` and
     `transferOwnership`; there is no `renounceOwnership`. The error is `NotOwner`.
   - `getCase` returns its fields as a flat tuple instead of a `Case` struct; `getLead` and `getAudit` were
     removed (leads and audits are fully described by `LeadSubmitted`/`LinkSubmitted`/`LeadVerdict` and
     `AuditAsked`/`AuditResult`/`AuditUnanswered`, and `auditOf` holds the finding); `caseCount`, `leadCount`
     and `auditCount` became one `counts()`; `verdictBody`/`auditBody` views were removed (call
     `LastSeenQuestions.build` instead, as the tests do); `pending` is internal; `forceApprove` is a plain
     `approve` checked for `true`.
   - `Status.NoAnswer` is no longer a retry condition in `requestVerdict`: no case ever receives it (the audit
     noted the branch was dead).
   - Review round (the fixes below needed about 1,700 bytes the runtime did not have): the internal storage
     structs `Case`, `Lead` and `Audit` use one slot per field instead of solc's packing (each packed field
     costs hundreds of bytes of mask-and-shift code unoptimized; these arrays have no public getter, so no ABI
     changed; `getCase` casts back to the `uint64` widths it returned before). `Hunt.openUntil` and
     `Hunt.inFlight` are `uint256`, so the public `hunts(id)` getter and the `BountyPosted` event now carry
     `openUntil` as `uint256` (same values, wider type). `SafeERC20` was replaced by two checked helpers,
     `_pull` and `_push`, which revert `BadInput` when IMD returns `false`: IMD is the launch's fixed
     plain ERC-20 and the asset can only be changed by the owner while the contract holds none
     (`test_transferReturningFalseReverts`). The request record `Pending` packs its small fields into one
     word by hand (`meta`). No behaviour changed with any of these; gas per lead and case rose by a few
     storage slots, which Robinhood Chain prices in fractions of a cent.
2. **Owner is a constructor argument, never `msg.sender`** (already so). `test_ownerIsTheArgumentNotTheDeployer`
   and `test_constructorNeedsNoOtherContract` pin it. `script/Deploy.s.sol` is unchanged; IMD's deployer launches
   the contract, the script is only the project's own record of the arguments.

## Audit findings that reproduced, fixed with a test (first round)

3. **Retry leaves the earlier request pending (medium).** `requestVerdict` now remembers the case's current
   request (`_caseRequest`) and deletes the earlier pending entry when it asks again, so a stale answer is
   `UnknownRequest`. `test_retryInvalidatesTheEarlierRequest` (the audit's proof).
4. **`payTip` empties the reward under a waiting lead (medium).** `payTip` reverts `WrongStatus` while
   `hunts[caseId].inFlight != 0`; tips are paid between leads. `test_hirerCannotEmptyTheRewardUnderAWaitingLead`
   (the audit's proof, plus the tip going through once nothing waits).
5. **Audits have no failure or retry path (low).** `Pending` records when a request was asked; `reclaimAudit(requestId)`
   marks an audit `Finding.NoAnswer` after two days, clears its pending entry, resets `auditOf` to `None` if the
   target was only ever `Asked`, and emits `AuditUnanswered`. `test_unansweredAuditCanBeReclaimed`.
   `requestWithFailure` was not adopted: the Intake interface and the mock would grow and the registry has no
   bytes to spare; the deadline path covers a refused body, a split panel and a lost callback alike.
6. **`_linkUsed` never cleared (low).** Each page lead keeps its key (`_linkKey`); a rejected or reclaimed page
   lead frees it (`_release`). `test_pageCanBeResubmittedAfterRejectionOrNoAnswer`.
7. **Callback does not check `questionHash` (low).** Case verdicts and on-chain hops use absolute windows, so
   their question is pinned: `LastSeenQuestions` builds those bodies in the oracle's canonical member order
   (keys sorted, chain evidence left out as the default) and returns `keccak256(document)`, which the registry
   stores in `Pending.questionHash` and compares before anything else in `onOracleResult`. Page leads and
   audits use a relative window and stay unpinned (hash zero). `test_answerToAnotherQuestionRefused`,
   `test_questionHashIsTheCanonicalDocument`. The verdict and hop bodies therefore changed shape (member order,
   definitions sorted, no `"evidence":"chain"`); the question texts are unchanged. `a.chainId` is covered by the
   pinned document, so no separate check was added. `a.requestId` is not consumed separately: a pending id is
   deleted before the signature is checked, and two requests that share a hash ask the same facts.
8. **`fundBounty` after the hunt ended (low).** Refused with `WrongStatus` once `block.timestamp > openUntil`.
   `test_fundBountyRefusedAfterTheHuntEnds`.
9. **`guards` body member (info).** The oracle-consumer reference lists the body keys and says an unknown key
   refuses the whole request with the price spent; `guards` is not among them and `POST /requests/check` cannot
   validate it. It was dropped from the page and audit bodies; the Sourcify URL and the page URL stay in the
   question and definitions. `test_bodiesCarryNoUnknownMember`. The question texts are unchanged.

## Review findings that reproduced, fixed with a test (review round)

All in `src/LastSeenRegistry.sol` unless noted; tests in `test/Revision.t.sol`. The reviewer's four proofs
(`Proof_9626666f9cc9`, `Proof_1837fa626aa2`, `Proof_a76cdef9d474`, `Proof_69880037c65f`) failed on the tree
as it arrived and pass now; `.imd-responses.json` answers every finding.

13. **Anyone could take the hirer's seat and lock the opener out (medium).** The proof requires the pre-empt
    variant (a stranger's first post goes through, the opener then takes the seat), so `postBounty` now lets an
    empty seat be anyone's, lets the case's opener take it from any stranger and the victim's wallet take it
    from anyone; a stranger can never take it back, and a new hirer never inherits the previous tip key (the
    key is reset to what they pass, even zero). Revised in the second review round (item 21): the earlier hirer
    is paid back on a takeover, and the wallet no longer outranks the opener. `test_openerAndWalletTakeTheSeatFromAStranger`.
14. **Page-lead dedupe keyed on the raw URL (medium).** `LastSeenQuestions.pageKey(url)` (`src/LastSeenQuestions.sol`)
    hashes the URL without its fragment or query string, without trailing slashes and with the host lowercased;
    `build` returns it for kind 3 and `submitLink` keys `_linkUsed` on `(caseId, pageKey)`. The question still
    carries the URL as given. Paths keep their case. Extended in the second review round (item 22).
    `test_samePageCountsOnceWhateverTheUrlVariant`.
15. **Oracle settings checked at settlement, not at ask time (medium).** `Pending` records the intake, attester,
    panel size and quorum of the moment the request was asked and paid for; `onOracleResult` requires
    `msg.sender` to be that intake and `_accept` judges the signer, `panelSize` and `quorum` against the
    recorded values, so `setPanel` and `setOracle` while requests are in flight lose nothing.
    `test_answerIsJudgedAgainstTheSettingsWhenAsked`.
16. **A hunt on a rejected case locks the checks until `openUntil` (medium).** `closeBounty` treats
    `c.status == Rejected` as the end of the hunt (still with no lead in flight). `test_rejectedCaseHuntClosesAtOnce`.
17. **A listing can never be cleared, and the question counts relayed moves (medium).** Two of the three parts
    the finding asks for: `delist(address)` (owner only, emits `Delisted`) clears `flagged` and `compromised`
    for an address the swarm confirmed on a question that was true of a bundler, solver or relayer acting for
    the wallet, or that a later answer contradicts (`test_ownerCanDelist`); and the verdict's definitions
    (`src/LastSeenQuestions.sol`) now exclude movements the wallet authorised with its own signature and another
    sender only relayed (ERC-4337 user operations, permits and Permit2, signed orders, meta-transactions), and
    define "take" as a movement the wallet did not authorise (`test_verdictDefinitionsExcludeAuthorisedMoves`).
    The question text itself is unchanged and was run through `POST /requests/check` again on 21 Oct 2026:
    `judged: true`, no blockers. The third part, making a stranger pay or stake when the pool pays, is the
    "anyone asks" design the authors chose (item 12) and is left as it is; see also item 20.
18. **A hop to the victim's wallet or the suspect is paid (medium).** `submitLead` refuses `to == c.wallet` and
    `to == c.suspect`. `test_hopToTheWalletOrSuspectRefused`.
19. **Advisory findings fixed.** `_accept` requires `a.quorum >= quorum asked` (a 1-of-5 or 0-of-5 answer is
    refused: `test_quorumBelowTheAskedQuorumRefused`); `openCase` refuses `toBlock > 2^53 - 1`, which the oracle
    cannot carry as a JSON number (`test_unsafeBlockWindowRefused`); `reclaimStake` is for the lead's hunter or
    the hunt's hirer only (`test_onlyHunterOrHirerReclaimsAStake`); a signed `CanTakeFunds` in `auditOf` is not
    overwritten by a later `NoPowerFound` (`test_canTakeFundsIsNotErasedByALaterNo`); `transferOwnership`
    refuses the zero address (`test_ownershipCannotGoToZero`); `fundBounty` documents that a donation is at the
    hirer's disposal, the finding's own second option.

## Second review round

The reviewer's proof `Proof_4fcf58d27d87` failed on the tree as it arrived and passes now; `.imd-responses.json`
answers every finding of the round.

21. **Taking over the hirer's seat handed the earlier hirer's deposit to the new one (high, reproduced).** Item
    13's takeover left the reward and prepaid checks in the hunt, where `payTip` and `closeBounty` put them at the
    new seat holder's disposal, and the new holder needed to deposit nothing; the wallet outranked everyone though
    the case's own premise is that its key is the thief's. `postBounty` (`src/LastSeenRegistry.sol`) now: lets
    the opener or the wallet take the seat only from a hirer who is neither (a stranger), so neither takes it from
    the other; refuses a takeover while a lead is waiting (`WrongStatus`), so a waiting lead is paid from the
    reward it was submitted against (the rule of item 4); pays the outgoing hirer the reward and checks left
    (emitting `BountyClosed`), restarts the end date from the new post, and requires the new hirer to prepay at
    least one check. The payout is the body of `closeBounty`, moved into an internal `_close` both use; the
    runtime grew 30 bytes to 24,402. `test_openerAndWalletTakeTheSeatFromAStranger` (changed with the
    behaviour: the stranger is paid back, the wallet cannot take the seat from the opener),
    `test_walletTakesTheSeatFromAStrangerButNotTheOpenerFromIt`, `test_seatTakeoverCannotTakeTheEarlierHirersDeposit`.
22. **Page keys (low, advisory; partly changed).** `LastSeenQuestions.pageKey` also drops a leading `www.` of the
    host, the default port `:443` and repeated slashes in the path, so `https://www.x.com:443//p` can no longer be
    paid again as a new page. The query string is still dropped: keeping it would let anyone append `?x=1` and be
    paid a second time for the same page out of the hirer's reward and checks, which costs more than the false
    refusal the reviewer found (two pages a forum tells apart only by query string count as one per case). That
    limit is documented in the README and on `pageKey`. Asserted in `test_samePageCountsOnceWhateverTheUrlVariant`.
23. **Owner routes funds through `setOracle` (info).** The trust assumption of item 10, unchanged.

## Findings not changed, and why

10. **Owner can point the oracle at their own contract and key (medium).** The oracle skill requires the intake,
    action, asset, price and attester to be owner-settable, and the brief says not to change the logic. It is a
    trust assumption, documented at the top of `LastSeenRegistry.sol` and in the README (whose "no way to
    withdraw" sentence was corrected). A timelock would be a redesign; the owner key should be a multisig.
11. **A lead is paid for any true transfer in the window (medium).** The defect is in what the question asks,
    not in a guard; it cannot be reproduced in Foundry and the brief forbids changing the logic. Left as is;
    hirers should size rewards and checks with it in mind. The two guardable instances (hops back to the wallet
    or the suspect) are closed by item 18.
12. **The donated pool pays for anyone's question (medium, and the review's low 97a6d14).** The authors chose
    "anyone asks"; it is a design choice the audit itself calls design-level and the review calls acknowledged.
    Left as is; donors should know it. Item 19 removes the unanswerable-window vector the review used.
20. **Review items left alone.** An unanswered lead returns the stake while the check is spent: the README
    promises the stake back and an honest hunter cannot make the swarm answer, so punishing no-answer would
    charge hunters for oracle downtime; low, left. A stray wei blocks `setOracle` from changing the asset: the
    fix needs a `held` counter at every transfer site and the runtime has no room; the asset is the launch's
    IMD, every other oracle setting stays changeable, and a new token would be a redeploy in any case; left.
    `reclaimAudit` resetting `auditOf` while a second audit of the same target is pending (info): the second
    answer sets it again; left. Reading `Intake.priceOf` at ask time (info): the reference lists the price as
    an owner setting, `setOracle` follows a price move; left. A two-step ownership handover was not added for
    bytes; the zero check was.

## Not done

- `requestWithFailure` (see 5). `eip712Domain()`, `getLead`, `getAudit`, the three count views, the two body
  views and `renounceOwnership` are gone for size (see 1); the app that reads this contract needs its ABI
  regenerated from `out/` (`hunts(id)` and `BountyPosted` now carry `openUntil` as `uint256`, and there is a new
  `delist(address)` and `Delisted` event).
- No deployment, broadcast or key handling: IMD's deployer launches the attested source through the factory.

# Adaptation for the Robinhood Chain launch

Launch: `evm_contracts`, chain 4663, one application contract, `LastSeenRegistry`, with the six constructor
arguments the brief lists (`owner_` = `$owner`, then the Intake, action id, IMD, price and attester). No token,
no pool. The constructor arguments, the public read surface used by wallets (`flagged`, `compromised`,
`auditOf`), every event and every user function keep their names and behaviour, except where a launch rule or
a reproduced audit finding required a change. Each change is listed below with the file and the reason.
Tests: `forge test` runs 35 tests (the 20 original, `Bodies.t.sol`, and 14 in `test/Adaptation.t.sol`).

## Launch rules

1. **Runtime size (audit, high, reproduced).** `forge build --sizes` with the project's own `foundry.toml`
   reported a 35,689-byte runtime; the launch floor refuses anything over 24,576 bytes and `foundry.toml` is
   protected, so the optimizer cannot be turned on. Changes, all in `src/LastSeenRegistry.sol` unless noted:
   - The question texts moved to a new stateless contract, `src/LastSeenQuestions.sol`, which the registry
     creates in its constructor (no outside contract is called, as the empty-chain floor requires) and reads
     with STATICCALL through one entry point, `build`. The runtime is now 24,257 bytes
     (`test_runtimeFitsEip170`), the helper 9,703.
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
2. **Owner is a constructor argument, never `msg.sender`** (already so). `test_ownerIsTheArgumentNotTheDeployer`
   and `test_constructorNeedsNoOtherContract` pin it. `script/Deploy.s.sol` is unchanged; IMD's deployer launches
   the contract, the script is only the project's own record of the arguments.

## Audit findings that reproduced, fixed with a test

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

## Findings not changed, and why

10. **Owner can point the oracle at their own contract and key (medium).** The oracle skill requires the intake,
    action, asset, price and attester to be owner-settable, and the brief says not to change the logic. It is a
    trust assumption, documented at the top of `LastSeenRegistry.sol` and in the README (whose "no way to
    withdraw" sentence was corrected). A timelock would be a redesign; the owner key should be a multisig.
11. **A lead is paid for any true transfer in the window (medium).** The defect is in what the question asks,
    not in a guard; it cannot be reproduced in Foundry and the brief forbids changing the logic. Left as is;
    hirers should size rewards and checks with it in mind.
12. **The donated pool pays for anyone's question (medium).** The authors chose "anyone asks"; it is a design
    choice the audit itself calls design-level. Left as is; donors should know it.

## Not done

- `requestWithFailure` (see 5). `eip712Domain()`, `getLead`, `getAudit`, the three count views, the two body
  views and `renounceOwnership` are gone for size (see 1); the app that reads this contract needs its ABI
  regenerated from `out/`.
- No deployment, broadcast or key handling: IMD's deployer launches the attested source through the factory.

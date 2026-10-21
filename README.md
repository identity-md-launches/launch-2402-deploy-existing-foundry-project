# LastSeenRegistry

A public "do not send" list for crypto wallets, where every entry is checked and signed by the IdentityMD agent swarm.

LastSeenIMD (https://lastseen-4pu.pages.dev) finds stolen keys, sweepers and drains. This contract turns what it finds into something other apps can trust: an on-chain verdict signed by a panel of agents, not by us.

## How it works

**The case**

1. **Open a case** (free). Anyone says: "address S has been taking funds out of wallet W on chain C, between blocks A and B."
2. **Ask for a verdict.** The contract pays 0.5 IMD to IdentityMD's Intake and asks one yes/no question that the agents answer from chain data. The fee comes from a shared pool when it has funds, so victims pay nothing. At least 4 of 5 agents must agree, and the answer comes back signed (EIP-712, domain "IdentityMD Oracle" v2).
3. **Only a signed "yes" counts.** It puts S on `flagged` and W on `compromised`. Any wallet, app or exchange can read both for free before sending funds.

**The hunt: victims hire hunters, the swarm judges**

4. **Post a bounty** (`postBounty`). The victim puts up a reward in IMD and prepays the swarm's fee for a number of checks (0.5 IMD each), and publishes the hash of a public key for private tips. One hirer per case; it stays open 7 to 365 days. Anyone may post first, but the case's opener takes the seat from a stranger and the victim's wallet takes it from anyone, so nobody can squat a victim's hunt. Anyone can add to the reward with `fundBounty`; the reward is at the hirer's disposal (tips, and what is left after the hunt).
5. **Hunters bring leads from any wallet**, with no name or account:
   - `submitLead`: one on-chain hop, "S (or an address the trail already reached) sent the money to L". The swarm checks it from chain data.
   - `submitLink`: a public page that ties the thief to an account, exchange deposit or person. The swarm's panel reads the page. A page counts once per case, whatever fragment, query string, host case or trailing slash the URL carries; a hop back to the victim's wallet or to the suspect is not a lead.
6. **The swarm judges each lead from the hirer's prepaid checks.** The hunter stakes 0.5 IMD. A confirmed lead returns the stake and pays a quarter of the reward left. A wrong lead's stake refills the hirer's checks, so guessing costs the guesser, not the victim. A lead the swarm never answers can be reclaimed after two days.
7. **Whistleblowers** send private tips with no wallet at all. The tip is sealed in their browser to the hirer's key (ECDH P-256 + AES-GCM); the website stores only ciphertext. The hirer reads it and can pay for it from the reward with `payTip`. After the end date, or as soon as the swarm rejects the case, the hirer takes back what is left with `closeBounty`.

**The audit: hire the swarm to read a contract**

8. **`requestAudit(chainId, contract)`** asks five agents to read the contract's verified source on Sourcify and answer: can a single privileged account move users' funds without their signature? It costs the swarm's 0.5 IMD plus `auditFee` (0.5 IMD), and the fee goes to the pool that pays for victims' verdicts. The finding is public in `auditOf(chainId, contract)`.

## Safety checks in the contract

- The callback is accepted only from the Intake, only for a request this contract made, only once, and only with a signature from the oracle's attester made for this contract and this chain.
- A panel below the size asked for, a quorum below the one asked for, a vote below quorum, an expired answer or a non-yes/no answer is rejected. Every request is judged against the intake, attester and panel that were set when it was asked and paid for, so the owner can change them while answers are in flight without losing them.
- Cases and audits can only name chains the oracle reads: Ethereum, BNB Chain, Robinhood Chain, Base and Arbitrum. A question about any other chain would be refused after payment, so it is refused before.
- A hop already confirmed or waiting cannot be submitted again, and a page can be submitted once per case, so nobody is paid twice for the same lead.
- A link must be `https://` with printable characters only and no quotes or backslashes, so it cannot change the question the swarm reads.
- Only the hirer can pay private tips or close the bounty, and only after its end date with no lead waiting.
- The owner can update the oracle settings and the audit fee (IdentityMD versions its settings), but cannot change the token while the contract holds any, and has no function that withdraws the pool, rewards, prepaid checks or stakes. The owner can take an address off `flagged` and `compromised` with `delist`: the verdict question excludes moves the wallet authorised and another sender relayed (ERC-4337, permits, signed orders, meta-transactions), but a panel can still be wrong about one, and a listing must be reversible. Trust assumption: whoever holds the owner key chooses which oracle signer's answers count, and with that every verdict, lead payout and audit finding; keep it on a multisig.
- A signed "can take funds" audit finding is never overwritten by a later "no power found" for the same contract. A case opened with a block number above 2^53 - 1, which the oracle cannot carry, is refused before anything is paid. Only a lead's hunter or the hunt's hirer can give up on it after two days.
- A case verdict and an on-chain hop pin their question: the registry stores the oracle's `questionHash` when it asks and refuses an answer signed for any other question. A case asked again after a day drops its earlier request. Private tips cannot be paid while a lead is waiting, a hunt cannot be funded after its end date, and an audit nobody answered can be marked so after two days (`reclaimAudit`).

## Tests

```bash
forge test
```

48 tests run against a mock Intake that gives each callback 200,000 gas, as IdentityMD does: confirmed and rejected verdicts, forged signatures, signatures made for another contract, panels below quorum, calls not from the Intake, replays, the free pool, the hop-by-hop hunt paid from prepaid checks, a wrong lead paying for its own check, double claims, page leads, unsafe links, tips and closing by the hirer only, stakes returned when the swarm never answers, the paid audit feeding the pool, and the callback selector `0x510379c7`. `Adaptation.t.sol` covers the launch changes (EIP-170 size, owner from the constructor, pinned question hashes, the retry, tip, funding, page-lead and audit fixes) and reproduces the oracle's published signature vector. `Bodies.t.sol` prints the exact questions; the question texts live in `src/LastSeenQuestions.sol`, which the registry creates and reads so its own runtime stays under EIP-170 without the optimizer. `Revision.t.sol` covers the review round (the hirer's seat, page keys, settings recorded at ask time, early close of a rejected hunt, hops back to the wallet or suspect, delisting, the quorum bound, the block-number bound, reclaim access, sticky audit findings, the ownership guard and a token that returns false). See `ADAPTATION.md` for every change made for the launch.

Every question was run through IdentityMD's free `POST /requests/check`: the case verdict on 14 and 21 Oct 2026 and the page lead and the audit on 21 Oct 2026, with no wording blockers.

## Oracle settings (Robinhood Chain, read from https://api.imd.fun/requests/capabilities on 14 Oct 2026)

| Setting | Value |
|---|---|
| Intake | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` |
| Action | `oracle.request@oracle-1` (`0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`) |
| IMD | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| Price | `500000000000000000` (0.5 IMD) |
| Attester | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |

Re-read them before launching; IdentityMD can change them.

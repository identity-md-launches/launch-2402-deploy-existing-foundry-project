# Launching LastSeenRegistry through IdentityMD

The hackathon requires the project to launch through the IMD Protocol. These are the steps. Steps 1, 4 and 6 need you; nothing here spends money until step 4.

## 1. The public repository

The contracts are public at https://github.com/Alok-mad98/lastseenimd-registry, a Foundry project at the top level with `foundry.toml` set to `bytecode_hash = "none"`. The app that uses them is https://github.com/Alok-mad98/lastseenimd.

## 2. Check the request for free

Open https://explorer.imd.fun/launch → **Launch a company** → choose **Contracts**, chain **Robinhood Chain**, and paste this description. Press **Check**: nothing is paid at this step.

> Deploy the existing Foundry project at https://github.com/Alok-mad98/lastseenimd-registry (contract `LastSeenRegistry` in `src/LastSeenRegistry.sol`) on Robinhood Chain, contracts only, no token and no pool.
> Constructor arguments, in order:
> 1. `owner_`: $owner
> 2. `intake_`: 0xa43e6F75ee006411F79Ac1C84120606C2330DE82
> 3. `action_`: 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000
> 4. `asset_`: 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127
> 5. `price_`: 500000000000000000
> 6. `attester_`: 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982
> Do not change the contract's logic. It already has 20 passing Foundry tests (`forge test`).

## 3. Read the check

If it reports blockers, fix them before paying. A refused paid request is not refunded.

## 4. Pay

0.5 IMD from the wallet that should own the contract (it becomes `$owner`). Prizes are paid to the deployer address the hackathon sees, so use the wallet you want prizes sent to.

## 5. Connect the app

When the launch completes, it gives the deployed address. Set it on the site:

```bash
npx wrangler pages secret put REGISTRY_ADDRESS --project-name lastseen
```

Also set `REGISTRY_FROM_BLOCK` to the deployment block as hex (for example `0x1a2b3c`) so the bounty board reads events from there, then redeploy. The swarm panel, the bounty board and the paid swarm audit switch on by themselves.

## 6. Fund the free pool (optional)

Send IMD to the contract with `donate(amount)` after approving it. Each verdict costs 0.5 IMD, so 10 IMD pays for 20 free verdicts for victims.

## 7. Submit

Create the project's X account, then submit at https://imdradar.site/hackathon with the contract address. A ready text is in `../SUBMISSION.md`.

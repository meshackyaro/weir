# Weir

A Uniswap v4 hook that turns MEV into an LP dividend instead of a leak.

Built for the Atrium Academy Uniswap Hook Incubator (UHI10) Hookathon — theme: **Sustainable Liquidity & MEV Protection**.

## The idea

Searchers already extract value from every volatile pool, every block. Weir makes them pay for it, and routes that payment back to the liquidity providers who bear the cost.

Each epoch, searchers bid for **priority execution** — the right to take the opening swap of the epoch (first-swap position / exclusive backrun rights). The winning bid does not go to a validator or a separate venue. It goes into a `RebateVault` and is distributed pro-rata to the pool's liquidity providers.

The price a searcher pays to jump the queue becomes the LP's compensation for the adverse selection that flow imposes.

## Why not just use an existing MEV-redistribution system

Two gaps in what exists today:

1. **They need their own venue.** Systems that already return auction proceeds to LPs run a separate DEX with its own clearing-price matching engine. Weir ships as a single composable hook — any v4 pool can adopt it directly, no new venue, no liquidity migration.
2. **Their bids are public.** Plaintext priority auctions let searchers observe each other and shade their bids, which suppresses what LPs ultimately collect. Weir replaces the bid value with a Fhenix CoFHE ciphertext, so no competitor sees a rival's bid before the epoch closes and only the winning bid is ever decrypted.

## Partner integrations

Weir integrates two hookathon partners. Both are load-bearing — remove either and the mechanism it supports stops working.

### Fhenix — CoFHE

`WeirSealedAuction` holds the running highest bid and the address holding it as CoFHE ciphertexts (`euint128`, `eaddress`), folded forward with homomorphic comparison and `FHE.select` as each bid arrives. Only the winning pair is ever decrypted, via `FHE.decrypt` and read back with `FHE.getDecryptResultSafe`. Losing bids stay sealed permanently.

This is the project's differentiator, and it dictated two structural decisions documented under [Sealed bids](#sealed-bids): collateral is posted separately from the bid, because a matching `msg.value` would publish it; and bidding runs two epochs ahead, because CoFHE decrypts asynchronously and a winner must be on record before their epoch begins.

Built against `cofhe-contracts` v0.0.13 and tested against Fhenix's `cofhe-mock-contracts`, which reproduce the asynchronous decryption the live coprocessor imposes. `demo/weir.mjs` encrypts bids with `cofhejs` — a sealed bid cannot be produced from Solidity, since CoFHE only accepts a ciphertext its verifier has signed.

### Chainlink — Price Feeds and Automation

**Price Feeds.** `FairPriceOracle` wraps `AggregatorV3` with staleness and decimal normalisation, and `WeirAuctionBase.reservePrice` uses it to keep the auction's reserve worth a fixed amount as ETH moves. See [The reserve floor](#the-reserve-floor).

**Automation.** `WeirKeeper` is an `AutomationCompatible` upkeep that closes and settles each sealed epoch on schedule. The sealed auction has two transactions per epoch that nobody has a private reason to send on time, and a winner has to be decrypted before their epoch starts — Automation is what makes that deadline somebody's job. See [Who closes and settles](#who-closes-and-settles).

No other partner integrations.

## Architecture

| Contract | Role |
|---|---|
| `WeirHook` | v4 hook. Reserves each epoch's opening swap for the auction winner; reports LP liquidity changes to the vault. |
| `WeirAuction` | Plaintext per-epoch priority auction. The simple baseline. |
| `WeirSealedAuction` | The same auction over Fhenix CoFHE ciphertexts. Bids are never readable; only the winning pair is decrypted. |
| `RebateVault` | Accrues auction proceeds and pays them out pro-rata to LPs via a reward-per-liquidity accumulator. |
| `WeirPositionRouter` | Liquidity entrypoint that lets the hook credit rebates to the actual provider. |
| `FairPriceOracle` | Chainlink-backed reference price. Keeps the auction reserve worth a fixed amount as ETH moves. |
| `WeirKeeper` | Chainlink Automation upkeep that closes and settles each sealed epoch on time. |

Both auctions implement `IWeirAuction`, so the hook drives either one.

### Epoch and priority window

Bidding for epoch `N+1` happens during epoch `N`, so an epoch's winner is already fixed before its first swap can land.

Within `priorityWindowBlocks` of an epoch's start, only the winner may swap. After that window the pool is open to everyone — a winner who never shows up forfeits their bid rather than freezing the pool.

## Sealed bids

A priority auction whose bids are visible is a priority auction searchers can game. Rivals read each other, shade down to just above second place, and the difference comes out of the LPs' rebate. `WeirSealedAuction` closes that: the running highest bid and the address holding it are both CoFHE ciphertexts, folded forward with homomorphic `max` as each bid arrives. Only the winning pair is ever decrypted; every losing bid stays sealed forever.

Two properties of FHE dictate the rest of the design.

**Money cannot ride along with the bid.** A `msg.value` matching the bid would publish it. So a searcher posts collateral up front and later bids against a cap they choose. What an observer learns is the cap, not the bid — and searchers posting the same round cap are indistinguishable from each other. A bid above its cap is clamped rather than rejected, so "bid everything I have" stays a single transaction and a winner can always cover what they owe.

**Decryption is asynchronous.** CoFHE answers a decryption request in a later block, never the requesting one, so a winner cannot be revealed in the transaction that closes the bidding. Bidding therefore runs two epochs ahead:

```
epoch N        epoch N+1              epoch N+2
bids for N+2   closeBidding(N+2)      winner holds the priority slot
               settleEpoch(N+2)
```

That leaves a full epoch for the coprocessor to answer. If it does not, `winnerOf` stays zero and the epoch trades openly — a stalled auction can slow a rebate, but it can never freeze a pool.

### Who closes and settles

Both of those transactions have to happen on schedule, and nobody has a private reason to send them on time. A bidder will settle eventually, to unlock their collateral — but eventually is after the slot they paid for has passed.

`WeirKeeper` makes it somebody's job. It is a Chainlink Automation upkeep that watches a set of registered pools and, each block, sends at most one transaction: settle an epoch whose decryption has landed, or close one whose bidding is over. Settling outranks closing, because a closed epoch is one whose deadline is already running. Pools nobody bid on are skipped rather than closed for nothing.

The keeper holds no privilege the public does not. Both calls behind it are permissionless on the auction and guard themselves, so `performData` needs no trust and an Automation outage costs punctuality, not funds — the bidders whose collateral is locked can always drive the auction by hand.

### The reserve floor

A reserve fixed in wei silently changes meaning every time ETH moves. Set it at five dollars when ETH is two thousand, and it is a ten dollar reserve when ETH halves — quietly pricing searchers out and starving LPs of the rebate the reserve exists to protect.

Governance can set the floor in the feed's quote unit instead, and `FairPriceOracle` converts it at the current price. The wei figure stays underneath as a hard minimum, so the oracle can raise the bar and never lower it: a feed reporting an absurd price cannot make bids nearly free. A missing, zeroed or stale feed falls back to that floor rather than reverting — failing closed would stop bidding altogether, which is the opposite of what a reserve is for.

Weir prices bids in ETH, so the feed registered for a pool must price ETH in the reserve's unit. For an ETH-paired pool that is one feed doing both jobs: the same ETH/USD feed keeps a dollar reserve honest and judges execution quality after the fact.

### Who a rebate belongs to

Uniswap v4 records whoever calls `modifyLiquidity` as the position owner, so a hook sees a router, never the person behind it. Left alone, that sends every rebate to the router.

`WeirPositionRouter` closes the gap. It names the caller as beneficiary in `hookData`, and derives each v4 position salt from the caller so one provider can never withdraw another's liquidity. The hook honours a declared beneficiary only for routers governance has allowlisted — anyone else is credited as themselves, so an untrusted caller cannot redirect a rebate or decrement a stranger's tracked liquidity.

Liquidity is tracked per position, not per tick range. True in-range weighting needs per-tick accounting and is deferred.

## Build roadmap

- **Phase 1 — plaintext auction.** Auction, rebate vault, position router, Chainlink price feed, hook. Done.
- **Phase 2 — sealed bids.** Bid values as Fhenix CoFHE ciphertexts. Done.
- **Phase 3 — automation and oracles.** Chainlink Automation for punctual settlement, and the fair-price oracle behind the reserve. Done. Post-trade clawback against the oracle, and an EigenLayer AVS for decentralised winner resolution, remain.

## Development

```bash
forge build
forge test
```

Deploying:

```bash
export PRIVATE_KEY=... POOL_MANAGER=...
forge script script/DeployWeir.s.sol:DeployWeir --rpc-url unichain_sepolia --broadcast --verify
```

`GOVERNANCE` and `PRIORITY_WINDOW_BLOCKS` are optional; governance defaults to the deployer, and the script wires the vault authorizations and router trust for you when those match.

See [DEPLOY.md](DEPLOY.md) for the full runbook, including which chains can host a sealed-bid deployment and how to drive an epoch end to end.

`SEALED_BIDS=true` deploys `WeirSealedAuction` and its keeper instead of the plaintext auction. It needs a chain where CoFHE is live — without the coprocessor the auction deploys but no bid can be verified. Register each pool on the keeper and point a Chainlink Automation upkeep at it afterwards; the script prints the calls.

## Status

Phases 1 and 2 complete, Automation and the oracle reserve landed — 136 tests. Sealed bidding is tested against Fhenix's mock coprocessor, which reproduces the asynchronous decryption the real one imposes.

Known limits, all deliberate:

- Rebates are weighted by position liquidity, not by tick-range overlap. True in-range weighting needs per-tick accounting.
- `isWithinTolerance` exists but nothing calls it yet: post-trade clawback is designed, not built.
- The keeper's catch-up window is bounded at three epochs; anything older falls to the permissionless path.

Not audited. Not for production use — the deploy scripts refuse to run anywhere but a testnet.

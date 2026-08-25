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
2. **Their bids are public.** Plaintext priority auctions let searchers observe each other and shade their bids, which suppresses what LPs ultimately collect. Weir's roadmap replaces the bid value with a Fhenix CoFHE ciphertext, so no competitor sees a rival's bid before the epoch closes and only the winning bid is ever decrypted.

## Architecture

| Contract | Role |
|---|---|
| `WeirHook` | v4 hook. Reserves each epoch's opening swap for the auction winner; reports LP liquidity changes to the vault. |
| `WeirAuction` | Runs the per-epoch priority auction. Tracks bids, resolves the winner, forwards proceeds to the vault, refunds losers. |
| `RebateVault` | Accrues auction proceeds and pays them out pro-rata to LPs via a reward-per-liquidity accumulator. |
| `WeirPositionRouter` | Liquidity entrypoint that lets the hook credit rebates to the actual provider. |
| `FairPriceOracle` | Chainlink-backed reference price. Floors the auction reserve and checks executions after the fact. |

### Epoch and priority window

Bidding for epoch `N+1` happens during epoch `N`, so an epoch's winner is already fixed before its first swap can land.

Within `priorityWindowBlocks` of an epoch's start, only the winner may swap. After that window the pool is open to everyone — a winner who never shows up forfeits their bid rather than freezing the pool.

### Who a rebate belongs to

Uniswap v4 records whoever calls `modifyLiquidity` as the position owner, so a hook sees a router, never the person behind it. Left alone, that sends every rebate to the router.

`WeirPositionRouter` closes the gap. It names the caller as beneficiary in `hookData`, and derives each v4 position salt from the caller so one provider can never withdraw another's liquidity. The hook honours a declared beneficiary only for routers governance has allowlisted — anyone else is credited as themselves, so an untrusted caller cannot redirect a rebate or decrement a stranger's tracked liquidity.

Liquidity is tracked per position, not per tick range. True in-range weighting needs per-tick accounting and is deferred.

## Build roadmap

- **Phase 1 — plaintext auction.** Auction, rebate vault, Chainlink price feed. Fully working on its own.
- **Phase 2 — sealed bids.** Swap plaintext bid values for Fhenix CoFHE ciphertexts. This is the differentiator.
- **Phase 3 — stretch.** Chainlink Automation for keeper-free settlement; EigenLayer AVS for decentralised winner resolution.

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

## Status

Phase 1 complete: auction, rebate vault, position router, Chainlink price feed, hook, deploy script — 67 tests. Phase 2 (sealed bids) next.

Not audited. Not for production use.

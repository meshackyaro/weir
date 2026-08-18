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
| `FairPriceOracle` | Chainlink-backed reference price. Floors the auction reserve and checks executions after the fact. |

### Epoch and priority window

Bidding for epoch `N+1` happens during epoch `N`, so an epoch's winner is already fixed before its first swap can land.

Within `priorityWindowBlocks` of an epoch's start, only the winner may swap. After that window the pool is open to everyone — a winner who never shows up forfeits their bid rather than freezing the pool.

## Build roadmap

- **Phase 1 — plaintext auction.** Auction, rebate vault, Chainlink price feed. Fully working on its own.
- **Phase 2 — sealed bids.** Swap plaintext bid values for Fhenix CoFHE ciphertexts. This is the differentiator.
- **Phase 3 — stretch.** Chainlink Automation for keeper-free settlement; EigenLayer AVS for decentralised winner resolution.

## Development

```bash
forge build
forge test
```

## Status

Phase 1, in progress. Not audited. Not for production use.

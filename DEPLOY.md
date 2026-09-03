# Deploying Weir

**Testnets only.** Weir is unaudited and not for production use. Both deploy scripts allowlist
testnet chain IDs and revert with `NotATestnet` anywhere else, so a stray `--rpc-url` cannot put
this code in front of real funds.

Weir needs two things on the same chain: a Uniswap v4 `PoolManager` and Fhenix's CoFHE
coprocessor. **Ethereum Sepolia (11155111) is the only network where both are live**, so that is
the target for a sealed-bid deployment.

Verified on chain:

| | Ethereum Sepolia | Base Sepolia | Arbitrum Sepolia | Unichain Sepolia |
|---|---|---|---|---|
| v4 `PoolManager` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317` | `0x00b036b58a818b1bc34d502d3fe730db729e62ac` |
| CoFHE `TaskManager` | yes | yes | yes | no |
| CoFHE `ACL` | yes | yes | **no** | no |

Without CoFHE, `SEALED_BIDS` must be left off and the plaintext `WeirAuction` drives the hook.

## 1. Deploy the stack

```bash
export PRIVATE_KEY=0x...
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
export SEALED_BIDS=true

forge script script/DeployWeir.s.sol:DeployWeir --rpc-url sepolia --broadcast
```

Prints the vault, auction, hook, position router, oracle and keeper addresses, and wires the
vault authorizations and router trust when the deployer is also governance.

## 2. Stand up a pool

```bash
export WEIR_HOOK=... WEIR_AUCTION=... WEIR_POSITION_ROUTER=... WEIR_KEEPER=...

forge script script/SetupDemoPool.s.sol:SetupDemoPool --rpc-url sepolia --broadcast
```

Mints a demo token pair, initialises the pool behind the hook, opens the auction on it, registers
it with the keeper, and seeds liquidity **through `WeirPositionRouter`** — which is what makes the
deployer a rebate-earning provider rather than an anonymous router. Prints the pool id.

`EPOCH_BLOCKS` defaults to 30 (~6 minutes on Sepolia). It has to comfortably exceed CoFHE's
decryption latency, because the winner of epoch `N+2` is decrypted during epoch `N+1`.

## 3. Run a sealed epoch

A sealed bid **cannot be produced from Solidity**. CoFHE only accepts a ciphertext its verifier
has signed, and that signature comes from encrypting client-side. So bidding happens through the
Node client rather than a forge script.

```bash
cd client && npm install

export RPC_URL=$SEPOLIA_RPC WEIR_AUCTION=... POOL_ID=0x...

node weir.mjs status
node weir.mjs deposit 0.02
node weir.mjs bid 0.004 0.01     # bid 0.004 ETH behind a 0.01 ETH collateral cap
node weir.mjs status             # note the epoch the bid is competing for

# once the preceding epoch begins
node weir.mjs close <epoch>
node weir.mjs settle <epoch>     # retry until the coprocessor has answered
node weir.mjs status
```

The keeper does steps `close` and `settle` on its own once registered as a Chainlink Automation
upkeep; driving them by hand is how you demonstrate that they are permissionless.

Register the upkeep at [automation.chain.link](https://automation.chain.link) against the keeper
address, then `keeper.setForwarder(<forwarder>)` to lock `performUpkeep` to Automation.

## What to look for

`bidSealed` carries a ciphertext handle and a collateral cap. **The bid value is not recoverable
from the transaction, the logs, or contract storage** — `winnerOf` stays zero and `epochState`
exposes nothing until settlement decrypts the winning pair. Losing bids are never decrypted at
all.

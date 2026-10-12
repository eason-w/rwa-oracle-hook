# Fee specification

Let `P` be the pool price, `R` the accepted reference, and `b = baseFee / 1,000,000`. Prices are quote tokens per whole asset, normalized to 18 decimals.

```text
bid = R × (1 − b)
ask = R / (1 − b)

buy opening fee  = clamp(1 − P × (1 − b) / R, 0, maxFee)
sell opening fee = clamp(1 − R × (1 − b) / P, 0, maxFee)
```

These formulas use fractional fees. Solidity floors the retained fraction in millionths, then subtracts it from 1,000,000. This rounds the fee upward by less than one fee unit. At `P = R`, both fees equal `baseFee`. Inside the spread, the effective marginal buy and sell prices approximate ask and bid before AMM price impact.

Outside the spread, corrective flow buys below the reference or sells above it. Its opening fee is capped at `maxFee`. The other direction has zero fee.

```text
floor = min(openingFee, 2 × baseFee)
fee = openingFee − floor((openingFee − floor) × min(elapsed, duration) / duration)
```

The inner `floor(...)` means integer rounding down. Small gaps can already be at the fee floor. Fees inside the spread do not decay.

## Observation and caching

A successful swap or permissionless `refreshFees()` records the reference and spread region. A changed accepted reference, or a change between below-spread, inside-spread and above-spread states, starts a new observation. Repeated observations of the same outside state do not restart its clock. A view quote does not advance state.

Directional fees use the first observed pool price in a block while the accepted reference remains unchanged. This prevents splitting a correction into smaller same-block swaps solely to obtain progressively cheaper fees. Each swap still validates the oracle; a changed reference reprices immediately. The fee is selected before the swap and does not price every point along a large trade's path.

Two packed state slots hold the auction and block cache. The hook returns a v4 LP-fee override; tokens and fees settle through PoolManager. There is no separate custody or LP reward ledger.

## Failure behavior and limits

Invalid reference data selects `maxFee` in both directions. Initialization requires a valid reference and a pool price within `initialBandBps`; subsequent swaps have no distance guard. Normal v4 price limits, liquidity availability and router slippage limits still apply.

The fee shares an arbitrage opportunity with LPs but can also delay correction or divert flow to another venue. Fee income alone is not LP performance: inventory value, foregone volume, stale references, price impact and transaction costs matter. Frequent reference updates can keep resetting decay. These mechanisms and example parameters do not establish optimality or profitability.

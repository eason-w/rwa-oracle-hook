# RWA oracle hook

A Uniswap v4 dynamic-fee hook for assets with an external reference price. Fees quote a spread around the oracle and let LPs retain part of the opportunity when traders correct a mispriced pool.

The hook uses native v4 liquidity and fee accounting. It holds no tokens, moves no LP positions, and has no owner or upgrade mechanism. Each deployment is bound to one pool and an immutable fee policy.

## Contracts

| Contract | Purpose |
| --- | --- |
| [RwaOracleHook](src/RwaOracleHook.sol) | Directional fees, a declining corrective fee, and per-block price caching. |
| [IPriceOracle](src/interfaces/IPriceOracle.sol) | Reference-price interface with explicit validity and quote-per-asset units. |
| [ChainlinkOracle](src/oracle/ChainlinkOracle.sol) | Validates two Chainlink feeds and calculates asset/USD ÷ quote/USD. |
| [OraclePriceMath](src/libraries/OraclePriceMath.sol) | Price normalization and deviation math for either token ordering. |
| [MarketCalendar](src/oracle/MarketCalendar.sol) | Optional reference-validity calendar. Disabled by default; it does not pause swaps. |

## How fees work

At the oracle price, both directions pay the base fee. Near it, asymmetric fees quote a bid/ask spread. Outside that spread, a trader buying underpriced inventory or selling overpriced inventory pays the corrective fee; the opposite direction pays zero.

For an unchanged reference and side, the corrective fee declines toward a nonzero floor. The clock starts when a successful swap or `refreshFees()` observes the gap. An unchanged observation cannot restart it. Quotes alone do not start the clock.

| Example configuration | Value |
| --- | --- |
| Base fee | 0.05% |
| Maximum / invalid-oracle fee | 0.30% |
| Corrective floor | Smaller of the opening fee and 0.10% |
| Decay duration | 300 seconds |
| Initialization tolerance | 5% from a valid reference |

A missing, invalid or expired reference selects the flat maximum fee. Trading has no oracle-distance or market-close pause. Standard v4 liquidity and execution limits still apply. The hook implements `beforeInitialize` and `beforeSwap`; its permission bits are `0x2080`.

See [the fee specification](docs/FEES.md) for formulas, rounding and caching, and [integration notes](docs/INTEGRATION.md) for oracle and deployment requirements. These parameters are examples, not calibrated optima. Higher fees do not guarantee higher LP returns.

## Development

Requires [Foundry](https://getfoundry.sh/) (CI uses v1.4.4). Uniswap dependencies are pinned as Git submodules; Node.js is not required.

```sh
git clone --recurse-submodules https://github.com/eason-w/rwa-oracle-hook.git
cd rwa-oracle-hook
forge build
forge test
forge fmt --check
forge lint src -D warnings
```

For an existing checkout, run `git submodule update --init --recursive` first.

Tests cover both token orderings, actual v4 swaps and LP accounting, PositionManager and V4Quoter compatibility, invalid oracle reports, rounding, fuzz cases and stateful invariants. Settlement helpers and mock feeds live under `test/`; they are not deployment contracts.

## Deployment

The [Arbitrum Sepolia deployment](deployments/421614.json) uses the canonical Uniswap v4 PoolManager. Its [hook](https://sepolia.arbiscan.io/address/0x88F649701B8C92D2f0537BdD19ABc5cE22756080#code) and [Chainlink adapter](https://sepolia.arbiscan.io/address/0x9f7ee9772805cc47868095532Fb099D96313407a#code) have verified source on Arbiscan. The pool was seeded full-range with 1,000,000 demo USDC and approximately 1,285 demo SPY.

This demonstration binds the hook to a testnet-only oracle wrapper that forwards Chainlink by default and permits manual experiments. The wrapper, unbacked tokens and website are outside this repository. Production integrations should bind directly to a reviewed oracle. Deployment metadata records the exact binding and runtime hash.

[DeployChainlinkOracle](script/DeployChainlinkOracle.s.sol) configures the external reference. [DeployRwaHook](script/DeployRwaHook.s.sol) mines the required CREATE2 address and deploys the hook. [VerifyPool](script/VerifyPool.s.sol) checks pool wiring, code hash, active liquidity and quotes. Use [Uniswap's deployment registry](https://developers.uniswap.org/docs/protocols/v4/deployments) for the manager and periphery addresses on the selected chain.

## Security and license

Experimental and not independently audited. A stock price feed is not automatically a valid tokenized-stock price: issuer conversion, corporate actions, transfer restrictions, market hours and executable liquidity require separate validation. Oracle failure preserves AMM trading, not reference-price protection.

[MIT](LICENSE). Dependencies retain their respective licenses. This is an independent project, not an official Uniswap product.

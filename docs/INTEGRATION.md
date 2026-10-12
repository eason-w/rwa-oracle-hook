# Integration

## Pool and oracle

`RwaOracleHook` binds one PoolManager, sorted ERC20 pair, tick spacing, oracle and fee configuration at construction. Use v4's dynamic-fee flag (`0x800000`) in the PoolKey. The hook address must end in the `beforeInitialize | beforeSwap` permission bits (`0x2080`); the deployment script mines an appropriate CREATE2 salt.

Token decimals must be at most 18. The price scale handles either token ordering. Rebasing, fee-on-transfer and issuer-restricted assets require their own compatibility review. The included tests exercise the canonical PositionManager, V4Router execution harness and V4Quoter implementations; deployments should use reviewed periphery rather than the test settlement helper.

The hook reads [IPriceOracle](../src/interfaces/IPriceOracle.sol). An observation supplies a positive quote-per-asset price at 18 decimals, its publication timestamp, an exclusive validity deadline and reference availability. Oracle call failures, invalid values, expired data and unavailable references select flat fees rather than reverting ordinary swaps.

[ChainlinkOracle](../src/oracle/ChainlinkOracle.sol) divides asset/USD by quote/USD. It checks both reports independently: round completion, positive values, timestamp ordering, unchanged decimals, age limits and price bounds. Its observation uses the older timestamp and earliest expiry. Set the hook's age bound to accommodate both feed-specific limits; the adapter still enforces the stricter limit for each leg.

Optional sequencer validation rejects downtime and the recovery grace period. Both price reports must be at least as recent as recovery. The optional market calendar restricts reference validity, not pool trading. No calendar is used by default.

## Deployment scripts

Use Foundry's encrypted keystore (`cast wallet import`) or a hardware wallet. Do not commit signing keys or RPC credentials.

| Script | Required configuration |
| --- | --- |
| [DeployChainlinkOracle](../script/DeployChainlinkOracle.s.sol) | `ASSET_USD_FEED`, `QUOTE_USD_FEED`; each feed's `*_MAX_AGE`, `*_MIN_PRICE`, `*_MAX_PRICE`; `IS_L2`, `SEQUENCER_FEED`, `SEQUENCER_GRACE_PERIOD`. |
| [DeployRwaHook](../script/DeployRwaHook.s.sol) | `POOL_MANAGER`, `PRICE_ORACLE`, `ASSET`, `QUOTE`. Reads token decimals and adapter age bounds. |
| [VerifyPool](../script/VerifyPool.s.sol) | `EXPECTED_CHAIN_ID`, `RWA_HOOK`, `HOOK_CODE_HASH`, `POOL_MANAGER`, `PRICE_ORACLE`, `V4_QUOTER`, `ASSET`, `QUOTE`, `IS_L2`, `ASSET_PROBE_AMOUNT`, `QUOTE_PROBE_AMOUNT`. |

Feed price bounds use 18-decimal USD units and ages use seconds. `ENFORCE_MARKET_HOURS` defaults to false; when enabled, provide `MARKET_CALENDAR`. A nonzero sequencer feed is required by the deployment script when `IS_L2=true`; review network-specific availability rather than silently bypassing that check. `DeployRwaHook` uses the example policy in the README and tick spacing 60. Review those constants before broadcast; they cannot be changed later.

Run a simulation first, then broadcast after checking the chain, feeds and predicted address:

```sh
forge script script/DeployChainlinkOracle.s.sol --rpc-url "$RPC_URL" --account deployer
forge script script/DeployRwaHook.s.sol --rpc-url "$RPC_URL" --account deployer
```

Add `--broadcast` only for an intended deployment. Both scripts create contracts; they do not initialize or fund the pool. Initialize the exact PoolKey near a valid oracle price and seed liquidity through the chosen periphery. Verify source on the chain explorer using the same compiler, optimizer settings, dependency revisions and constructor arguments. Then run `VerifyPool` without `--broadcast` and record the addresses, deployment commit and runtime code hash.

Deployment does not automatically list a pool in Uniswap's interface. The separately hosted demonstration may use unbacked tokens and explicit test controls; those controls are not part of this hook release.

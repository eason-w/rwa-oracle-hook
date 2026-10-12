// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { OraclePriceMath } from "./libraries/OraclePriceMath.sol";

/// @title RWA oracle hook
/// @notice Quotes an oracle-relative spread and sells price-correction opportunities through declining LP fees.
/// @dev Uses standard v4 accounting. No swap is rejected solely for its distance from the reference.
///      No token custody, upgrade path, administrative pause, or liquidity-removal callbacks.
contract RwaOracleHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Immutable spread, auction and oracle policy. Fees are millionths; time is seconds.
    struct Config {
        /// @notice LP fee at the reference; determines the normal bid/ask spread.
        uint24 baseFee;
        /// @notice Fee cap, also used when the oracle is unavailable. At most 10%.
        uint24 maxFee;
        /// @notice Time for a corrective fee to decline to its floor; 1 through 3,600 seconds.
        uint32 decaySeconds;
        /// @notice Maximum deviation allowed only at initialization, in basis points.
        uint16 initialBandBps;
        /// @notice Maximum observation age; stricter per-feed checks remain in the adapter.
        uint32 maxOracleAge;
    }

    /// @notice One packed slot records the current outside-band auction.
    struct Auction {
        /// @notice Reference that the auction was opened against, scaled by 1e18.
        uint128 referencePrice;
        /// @notice First observation of this gap; refreshes cannot restart an unchanged auction.
        uint64 startedAt;
        /// @notice -1 below the bid, +1 above the ask, or zero inside the spread/unavailable.
        int8 side;
    }

    /// @notice One packed slot fixes both directional fees for a block and unchanged reference.
    struct BlockQuote {
        /// @notice First observed quote-per-asset price for this block, scaled by 1e18.
        uint128 poolPrice;
        /// @notice Block in which both fees were calculated.
        uint64 number;
        /// @notice Asset-buy LP fee in millionths.
        uint24 buyFee;
        /// @notice Asset-sell LP fee in millionths.
        uint24 sellFee;
    }

    /// @notice Current auction. The first corrective swap starts it automatically; refreshFees is optional.
    Auction public auction;
    /// @notice First observed pool price and directional fees for the current cached block.
    BlockQuote public blockQuote;

    /// @notice Precomputed identity of the only pool accepted by this hook.
    PoolId public immutable poolId;
    /// @notice Validated quote-per-asset price source; immutable for the pool lifetime.
    IPriceOracle public immutable oracle;
    /// @notice RWA token address. Ordinary non-rebasing ERC20 behavior is required.
    address public immutable asset;
    /// @notice Quote token address; its USD value is handled by the adapter.
    address public immutable quote;
    /// @notice Whether address ordering places the asset first in the pool key.
    bool public immutable assetIsCurrency0;
    /// @notice The only tick spacing accepted by this hook.
    int24 public immutable tickSpacing;
    /// @notice Decimal conversion factor: 10 ** (18 + assetDecimals - quoteDecimals).
    uint256 public immutable priceScale;
    /// @notice LP fee at the reference, in millionths; inventory-improving trades can pay zero.
    uint24 public immutable baseFee;
    /// @notice Maximum LP fee in millionths.
    uint24 public immutable maxFee;
    /// @notice Corrective fee decay duration, in seconds.
    uint32 public immutable decaySeconds;
    /// @notice Initialization-only distance limit; there is no swap corridor.
    uint16 public immutable initialBandBps;
    /// @notice Maximum observation age, in seconds.
    uint32 public immutable maxOracleAge;

    /// @notice Maximum gas forwarded to the reference adapter, including its underlying feeds.
    /// @dev Calibrate against deployed proxies before release. Exhaustion selects the flat fallback fee.
    uint256 public constant ORACLE_READ_GAS = 200_000;

    /// @notice Records the starting prices and LP fee selected for a swap.
    /// @param poolPrice Cached quote-per-asset pool price, scaled by 1e18.
    /// @param referencePrice Validated oracle price in the same units; zero marks flat-fee fallback, including extreme pool prices.
    /// @param fee LP fee in millionths, without the v4 override flag.
    /// @param corrective Whether the input direction moves toward the oracle from the cached price.
    event SwapPolicy(uint256 poolPrice, uint256 referencePrice, uint24 fee, bool corrective);

    /// @notice Constructor parameters violate the supported fee, price, token or age bounds.
    error InvalidConfig();
    /// @notice The supplied pool key differs from this hook's immutable pool configuration.
    error UnsupportedPool();
    /// @notice The oracle timestamp is zero or in the future.
    error InvalidObservation();
    /// @notice The oracle observation exceeds the configured maximum age.
    error StaleObservation();
    /// @notice The oracle marks the market closed or its exclusive expiry has passed.
    error MarketClosed();
    /// @notice Initialization is too far from the validated reference.
    error InvalidInitialPrice();
    /// @notice Supply enough transaction gas to forward the full oracle budget under EIP-150.
    error InsufficientOracleGas();

    /// @notice Creates a hook for one ERC20 pair and one immutable fee policy.
    /// @dev BaseHook validates the address permission bits. Token decimals must match token metadata.
    /// @param manager Canonical v4 PoolManager on the deployment chain.
    /// @param oracle_ Oracle adapter denominated in quote tokens per asset token.
    /// @param asset_ Asset token address; must differ from quote_.
    /// @param quote_ Quote token address; native ETH is not supported.
    /// @param assetDecimals Whole-token decimals of asset_, from 0 through 18.
    /// @param quoteDecimals Whole-token decimals of quote_, from 0 through 18.
    /// @param tickSpacing_ Accepted positive tick spacing, no greater than 32,767.
    /// @param config Spread, cap, decay duration, initialization bound and maximum oracle age.
    constructor(
        IPoolManager manager,
        IPriceOracle oracle_,
        address asset_,
        address quote_,
        uint8 assetDecimals,
        uint8 quoteDecimals,
        int24 tickSpacing_,
        Config memory config
    ) BaseHook(manager) {
        if (
            address(manager) == address(0) || address(oracle_) == address(0) || asset_ == address(0)
                || quote_ == address(0) || asset_ == quote_ || assetDecimals > 18 || quoteDecimals > 18
                || tickSpacing_ <= 0 || tickSpacing_ > 32767 || config.baseFee == 0
                || uint256(config.baseFee) * 2 > config.maxFee || config.maxFee > 100_000
                || config.initialBandBps == 0 || config.initialBandBps > 5000 || config.decaySeconds == 0
                || config.decaySeconds > 1 hours || config.maxOracleAge == 0
        ) revert InvalidConfig();
        poolId = PoolKey({
                currency0: Currency.wrap(asset_ < quote_ ? asset_ : quote_),
                currency1: Currency.wrap(asset_ < quote_ ? quote_ : asset_),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: tickSpacing_,
                hooks: this
            }).toId();
        oracle = oracle_;
        asset = asset_;
        quote = quote_;
        assetIsCurrency0 = asset_ < quote_;
        tickSpacing = tickSpacing_;
        priceScale = 10 ** (18 + uint256(assetDecimals) - quoteDecimals);
        baseFee = config.baseFee;
        maxFee = config.maxFee;
        decaySeconds = config.decaySeconds;
        initialBandBps = config.initialBandBps;
        maxOracleAge = config.maxOracleAge;
    }

    /// @notice Reads the current oracle and pool prices and calculates the directional LP fee.
    /// @dev A rejected oracle returns maxFee and referencePrice = 0. Does not predict price impact or fill size.
    /// @param key Full dynamic-fee pool key for this hook.
    /// @param zeroForOne True for currency0 input; false for currency1 input.
    /// @return fee LP fee in millionths, without the override flag.
    /// @return corrective Whether the direction initially moves toward the oracle.
    /// @return poolPrice Current or same-block cached quote-per-asset price, scaled by 1e18.
    /// @return referencePrice Validated oracle price, scaled by 1e18; zero means flat-fee fallback.
    function previewFee(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint24 fee, bool corrective, uint256 poolPrice, uint256 referencePrice)
    {
        _validatePool(key);
        referencePrice = _referenceOrZero();
        poolPrice = _readPoolPrice();
        if (referencePrice == 0 || !_priceInDomain(poolPrice)) return (maxFee, false, poolPrice, 0);
        BlockQuote memory cached = blockQuote;
        if (cached.number == block.number && auction.referencePrice == referencePrice) {
            poolPrice = cached.poolPrice;
            fee = zeroForOne != assetIsCurrency0 ? cached.buyFee : cached.sellFee;
            corrective = _corrective(poolPrice, referencePrice, zeroForOne);
        } else {
            (fee, corrective) =
                feeForPricesAtAge(poolPrice, referencePrice, zeroForOne, _age(poolPrice, referencePrice));
        }
    }

    /// @notice Observes the current gap and advances its fee auction without buying or selling tokens.
    /// @dev Optional permissionless keeper action. A swap starts the same auction automatically, so
    ///      normal users never need to call this function. It can be useful when an operator wants
    ///      the fee clock running before a trade is submitted.
    ///      An unchanged outside-band reference and side retain their original startedAt timestamp.
    ///      Reads revalidate the oracle even when this block's fee is cached.
    function refreshFees() external {
        _updateQuote();
    }

    /// @notice Reads the pool's spot price without consulting the oracle.
    /// @dev Remains available during a market closure; reverts for an uninitialized or unsupported pool.
    /// @param key Full dynamic-fee pool key for this hook.
    /// @return price Quote tokens per whole asset, scaled by 1e18.
    function getPoolPrice(PoolKey calldata key) external view returns (uint256 price) {
        _validatePool(key);
        return _readPoolPrice();
    }

    /// @notice Enables initialization validation and the pre-swap callback only.
    /// @return permissions v4 permissions corresponding to address mask 0x2080.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
    }

    /// @notice Calculates an opening fee without reading or changing auction state.
    /// @param poolPrice Quote per asset, scaled by 1e18.
    /// @param referencePrice Validated reference in the same units.
    /// @param zeroForOne True for currency0 input.
    /// @return fee LP fee in millionths, rounded upward by at most one unit.
    /// @return corrective Direction relative to the supplied starting price.
    function feeForPrices(uint256 poolPrice, uint256 referencePrice, bool zeroForOne)
        public
        view
        returns (uint24 fee, bool corrective)
    {
        return feeForPricesAtAge(poolPrice, referencePrice, zeroForOne, 0);
    }

    /// @notice Quotes a spread near the reference, zero for favorable inventory flow outside it,
    ///         and a capped, linearly declining fee for corrective flow outside it.
    /// @dev Bid = R*(1-b), ask = R/(1-b), where b is baseFee/1e6. Before price impact, the
    ///      uncapped in-band buy and sell quotes equal those edges. Floors round toward higher fees.
    ///      Outside, the opening fee is capped and declines to min(opening, 2*baseFee).
    ///      A fee fixed over a trade does not price its full path or guarantee net LP returns.
    /// @param poolPrice Quote per asset, scaled by 1e18 and within OraclePriceMath bounds.
    /// @param referencePrice Oracle cross-rate in the same domain.
    /// @param zeroForOne Currency0 input if true; currency1 input otherwise.
    /// @param elapsed Seconds since this outside-band auction began; capped at decaySeconds.
    /// @return fee LP fee in millionths.
    /// @return corrective Whether the trade direction moves the supplied price toward the reference.
    function feeForPricesAtAge(uint256 poolPrice, uint256 referencePrice, bool zeroForOne, uint256 elapsed)
        public
        view
        returns (uint24 fee, bool corrective)
    {
        OraclePriceMath.validate(poolPrice);
        OraclePriceMath.validate(referencePrice);
        corrective = _corrective(poolPrice, referencePrice, zeroForOne);
        bool buy = zeroForOne != assetIsCurrency0;
        uint256 retained = buy
            ? FullMath.mulDiv(poolPrice, 1_000_000 - baseFee, referencePrice)
            : FullMath.mulDiv(referencePrice, 1_000_000 - baseFee, poolPrice);
        if (retained >= 1_000_000) return (0, corrective);
        uint256 opening = 1_000_000 - retained;
        if (opening > maxFee) opening = maxFee;
        if (_side(poolPrice, referencePrice) != 0 && corrective) {
            uint256 floor = uint256(baseFee) * 2;
            if (floor > opening) floor = opening;
            uint256 duration = elapsed < decaySeconds ? elapsed : decaySeconds;
            opening -= (opening - floor) * duration / decaySeconds;
        }
        // opening is explicitly bounded by the uint24 maxFee above.
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = uint24(opening);
    }

    /// @dev Initialization validates a reference and its distance; later swaps have no price guard.
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        _validatePool(key);
        uint256 referencePrice = _readOraclePrice();
        uint256 price = OraclePriceMath.price(sqrtPriceX96, assetIsCurrency0, priceScale);
        if (OraclePriceMath.distance(price, referencePrice) * 10_000 > referencePrice * initialBandBps) {
            revert InvalidInitialPrice();
        }
        return this.beforeInitialize.selector;
    }

    /// @dev No custom deltas or post-swap checks. Standard v4 owns execution, fee growth and settlement.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePool(key);
        uint24 fee = _swapFee(params.zeroForOne);
        return
            (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    /// @dev Keep event construction separate from the v4 callback's ABI arguments.
    function _swapFee(bool zeroForOne) private returns (uint24 fee) {
        (uint256 price, uint256 referencePrice, uint24 buyFee, uint24 sellFee) = _updateQuote();
        fee = zeroForOne != assetIsCurrency0 ? buyFee : sellFee;
        emit SwapPolicy(
            price, referencePrice, fee, referencePrice != 0 && _corrective(price, referencePrice, zeroForOne)
        );
    }

    /// @dev Cache identity includes the validated reference. A changed reference reprices immediately,
    ///      even within one block; unchanged references cannot be repriced by splitting same-block flow.
    function _updateQuote() private returns (uint256 price, uint256 referencePrice, uint24 buy, uint24 sell) {
        referencePrice = _referenceOrZero();
        price = _readPoolPrice();
        Auction memory state = auction;
        if (referencePrice == 0 || !_priceInDomain(price)) {
            if (state.referencePrice != 0) delete auction;
            return (price, 0, maxFee, maxFee);
        }
        BlockQuote memory cached = blockQuote;
        if (cached.number == block.number && state.referencePrice == referencePrice) {
            return (cached.poolPrice, referencePrice, cached.buyFee, cached.sellFee);
        }
        int8 side = _side(price, referencePrice);
        uint256 elapsed = _age(price, referencePrice);
        if (state.referencePrice != referencePrice || state.side != side) {
            // OraclePriceMath bounds references to 1e30; block time fits uint64.
            auction = Auction({
                // forge-lint: disable-next-line(unsafe-typecast)
                referencePrice: uint128(referencePrice),
                startedAt: uint64(block.timestamp),
                side: side
            });
        }
        (buy,) = feeForPricesAtAge(price, referencePrice, !assetIsCurrency0, elapsed);
        (sell,) = feeForPricesAtAge(price, referencePrice, assetIsCurrency0, elapsed);
        // Validated prices fit uint128. Block heights remain far below uint64.
        blockQuote = BlockQuote({
            // forge-lint: disable-next-line(unsafe-typecast)
            poolPrice: uint128(price),
            number: uint64(block.number),
            buyFee: buy,
            sellFee: sell
        });
    }

    /// @dev An auction begins when a swap or optional refresh transaction first observes an outside-band reference/side.
    function _age(uint256 price, uint256 referencePrice) private view returns (uint256) {
        Auction memory state = auction;
        int8 side = _side(price, referencePrice);
        if (side == 0 || state.side != side || state.referencePrice != referencePrice) return 0;
        return block.timestamp - state.startedAt;
    }

    /// @dev Exact spread comparisons avoid a whole-basis-point boundary approximation.
    function _side(uint256 price, uint256 referencePrice) private view returns (int8) {
        if (price * 1_000_000 < referencePrice * (1_000_000 - baseFee)) return -1;
        if (price * (1_000_000 - baseFee) > referencePrice * 1_000_000) return 1;
        return 0;
    }

    function _corrective(uint256 price, uint256 referencePrice, bool zeroForOne) private view returns (bool) {
        bool buy = zeroForOne != assetIsCurrency0;
        return price < referencePrice ? buy : price > referencePrice && !buy;
    }

    /// @dev Reads exactly four ABI words into a fixed buffer. Failed calls, malformed data and rejected
    ///      observations select fallback; no expired price is cached or used as an execution anchor.
    ///      The gas precondition prevents a caller from selecting fallback by starving a healthy read.
    ///      15,000 covers the cold call, EIP-150 reserve and instructions before STATICCALL.
    function _referenceOrZero() private view returns (uint256) {
        bytes memory input = abi.encodeCall(IPriceOracle.latestObservation, ());
        uint256[4] memory words;
        address target = address(oracle);
        uint256 budget = ORACLE_READ_GAS;
        if (gasleft() < budget + 15_000) revert InsufficientOracleGas();
        bool success;
        uint256 size;
        assembly ("memory-safe") {
            success := staticcall(budget, target, add(input, 32), mload(input), words, 128)
            size := returndatasize()
        }
        if (!success || size != 128) return 0;
        // Validate raw words before narrowing timestamps or decoding a potentially malformed bool.
        if (
            words[0] < OraclePriceMath.MIN_PRICE || words[0] > OraclePriceMath.MAX_PRICE || words[1] == 0
                || words[1] > block.timestamp || words[1] > type(uint64).max || words[2] > type(uint64).max
                || block.timestamp >= words[2] || words[3] != 1 || block.timestamp - words[1] > maxOracleAge
        ) return 0;
        return words[0];
    }

    /// @dev Oracle reverts propagate. Timestamp age is inclusive; validUntil is exclusive.
    function _readOraclePrice() private view returns (uint256) {
        IPriceOracle.Observation memory observation = oracle.latestObservation();
        OraclePriceMath.validate(observation.price);
        if (observation.updatedAt == 0 || observation.updatedAt > block.timestamp) {
            revert InvalidObservation();
        }
        if (!observation.marketOpen || block.timestamp >= observation.validUntil) revert MarketClosed();
        if (block.timestamp - observation.updatedAt > maxOracleAge) revert StaleObservation();
        return observation.price;
    }

    /// @dev Orients v4 raw currency1/currency0 into whole quote tokens per asset.
    function _readPoolPrice() private view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return OraclePriceMath.poolPrice(sqrtPriceX96, assetIsCurrency0, priceScale);
    }

    /// @dev Extreme v4 prices use flat fees rather than blocking a trade back into the normal domain.
    function _priceInDomain(uint256 price) private pure returns (bool) {
        return price >= OraclePriceMath.MIN_PRICE && price <= OraclePriceMath.MAX_PRICE;
    }

    /// @dev A single hash comparison validates the currencies, fee, spacing and hook together.
    ///      Reads reuse the precomputed identity; no per-swap pool registry is needed.
    function _validatePool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnsupportedPool();
    }
}

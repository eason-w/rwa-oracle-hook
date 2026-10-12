// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { IMarketCalendar } from "../interfaces/IMarketCalendar.sol";
import { OraclePriceMath } from "../libraries/OraclePriceMath.sol";

/// @notice Converts Chainlink token/USD and quote/USD feeds into a quote-per-token reference.
/// @dev Feed selection must match the token issuer. No administrator can publish or override prices here.
contract ChainlinkOracle is IPriceOracle {
    /// @notice Feed-specific validity limits, fixed at deployment.
    struct FeedConfig {
        /// @notice Chainlink proxy for the whole-token USD price.
        IAggregatorV3 feed;
        /// @notice Maximum age in seconds, from 1 through 172,800.
        uint32 maxAge;
        /// @notice Minimum accepted USD price per whole token, scaled by 1e18.
        uint128 minPrice;
        /// @notice Maximum accepted normalized USD price; must exceed minPrice.
        uint128 maxPrice;
    }

    /// @dev Normalized input with an inclusive observation timestamp and exclusive expiry.
    struct Reading {
        uint256 price;
        uint64 updatedAt;
        uint64 expiresAt;
    }

    /// @notice Immutable whole-asset USD feed; must match issuer conversion and corporate-action rules.
    IAggregatorV3 public immutable assetFeed;
    /// @notice Immutable whole-quote-token USD feed; avoids assuming a fixed dollar peg.
    IAggregatorV3 public immutable quoteFeed;
    /// @notice Optional L2 uptime feed; zero on L1.
    IAggregatorV3 public immutable sequencerFeed;
    /// @notice Optional trading-session source; zero means feed validity alone determines availability.
    IMarketCalendar public immutable calendar;
    /// @notice Asset answer decimals captured at deployment and checked on every read.
    uint8 public immutable assetFeedDecimals;
    /// @notice Quote answer decimals captured at deployment and checked on every read.
    uint8 public immutable quoteFeedDecimals;
    /// @notice Maximum asset report age, in seconds.
    uint32 public immutable assetMaxAge;
    /// @notice Maximum quote report age, in seconds.
    uint32 public immutable quoteMaxAge;
    /// @notice Required seconds after sequencer recovery; the boundary is exclusive.
    uint32 public immutable sequencerGracePeriod;
    /// @notice Minimum accepted asset/USD value, scaled by 1e18.
    uint128 public immutable assetMinPrice;
    /// @notice Maximum accepted asset/USD value, scaled by 1e18.
    uint128 public immutable assetMaxPrice;
    /// @notice Minimum accepted quote/USD value, scaled by 1e18.
    uint128 public immutable quoteMinPrice;
    /// @notice Maximum accepted quote/USD value, scaled by 1e18.
    uint128 public immutable quoteMaxPrice;

    /// @notice A feed, bound, decimal scale, age limit or sequencer configuration is invalid.
    error InvalidConfiguration();
    /// @notice The named feed returned an incomplete round, nonpositive answer or invalid timestamp.
    error InvalidRound(address feed);
    /// @notice The named feed exceeds its own maximum age.
    error StaleFeed(address feed);
    /// @notice The normalized USD answer is outside the configured inclusive bounds.
    error PriceOutOfBounds(address feed, uint256 price);
    /// @notice The proxy now reports a different decimal scale; migration requires a new adapter.
    error FeedDecimalsChanged(address feed);
    /// @notice The calendar does not currently permit trading.
    error MarketClosed();
    /// @notice The asset report predates the current opening or resumption timestamp.
    error AwaitingOpeningPrice();
    /// @notice The sequencer is down or its transition record is invalid.
    error SequencerUnavailable();
    /// @notice The configured recovery interval has not fully elapsed.
    error SequencerGracePeriod();
    /// @notice The named price report predates the latest sequencer recovery.
    error AwaitingPostRecoveryPrice(address feed);

    /// @notice Binds two USD feeds to a session policy and optional L2 recovery checks.
    /// @dev Feed addresses, scales and limits cannot be changed. Values within bounds can still be wrong;
    ///      selecting the correct issuer feed is an external deployment responsibility.
    /// @param assetConfig Asset/USD proxy with its own age and normalized value bounds.
    /// @param quoteConfig Quote/USD proxy with independently calibrated limits.
    /// @param calendar_ Optional trading-session calendar; zero disables market-hour restrictions.
    /// @param sequencerFeed_ L2 uptime proxy, or zero when no sequencer check applies.
    /// @param gracePeriod Recovery delay in seconds; positive with a sequencer, zero without one.
    constructor(
        FeedConfig memory assetConfig,
        FeedConfig memory quoteConfig,
        IMarketCalendar calendar_,
        IAggregatorV3 sequencerFeed_,
        uint32 gracePeriod
    ) {
        _validateConfig(assetConfig);
        _validateConfig(quoteConfig);
        if (
            (address(calendar_) != address(0) && address(calendar_).code.length == 0)
                || address(assetConfig.feed) == address(quoteConfig.feed)
                || (address(sequencerFeed_) != address(0)
                    && (address(sequencerFeed_).code.length == 0 || gracePeriod == 0))
                || (address(sequencerFeed_) == address(0) && gracePeriod != 0)
        ) revert InvalidConfiguration();
        assetFeed = assetConfig.feed;
        quoteFeed = quoteConfig.feed;
        assetFeedDecimals = assetConfig.feed.decimals();
        quoteFeedDecimals = quoteConfig.feed.decimals();
        if (assetFeedDecimals > 18 || quoteFeedDecimals > 18) revert InvalidConfiguration();
        assetMaxAge = assetConfig.maxAge;
        quoteMaxAge = quoteConfig.maxAge;
        assetMinPrice = assetConfig.minPrice;
        assetMaxPrice = assetConfig.maxPrice;
        quoteMinPrice = quoteConfig.minPrice;
        quoteMaxPrice = quoteConfig.maxPrice;
        calendar = calendar_;
        sequencerFeed = sequencerFeed_;
        sequencerGracePeriod = gracePeriod;
    }

    /// @inheritdoc IPriceOracle
    /// @dev Reads each feed once per observation, verifies its scale, then floors assetUSD / quoteUSD.
    ///      The older input timestamp is returned. Expiry is the earliest feed expiry, also capped by session close when a calendar is enabled.
    ///      Rejected inputs revert; there is no last-good-price fallback or administrator override.
    function latestObservation() external view returns (Observation memory observation) {
        uint256 recoveredAt = _checkSequencer();
        uint64 opensAt;
        uint64 closesAt = type(uint64).max;
        if (address(calendar) != address(0)) {
            bool isOpen;
            (opensAt, closesAt, isOpen) = calendar.currentSession();
            if (!isOpen) revert MarketClosed();
        }
        Reading memory asset = _read(assetFeed, assetFeedDecimals, assetMaxAge, assetMinPrice, assetMaxPrice);
        Reading memory quote = _read(quoteFeed, quoteFeedDecimals, quoteMaxAge, quoteMinPrice, quoteMaxPrice);
        if (asset.updatedAt < opensAt) revert AwaitingOpeningPrice();
        if (asset.updatedAt < recoveredAt) revert AwaitingPostRecoveryPrice(address(assetFeed));
        if (quote.updatedAt < recoveredAt) revert AwaitingPostRecoveryPrice(address(quoteFeed));
        observation.price = FullMath.mulDiv(asset.price, 1e18, quote.price);
        OraclePriceMath.validate(observation.price);
        observation.updatedAt = asset.updatedAt < quote.updatedAt ? asset.updatedAt : quote.updatedAt;
        uint64 expiry = asset.expiresAt < quote.expiresAt ? asset.expiresAt : quote.expiresAt;
        observation.validUntil = closesAt < expiry ? closesAt : expiry;
        observation.marketOpen = true;
    }

    /// @dev Bounds the answer before normalization, preventing multiplication overflow for 0-18 decimals.
    ///      maxAge is inclusive; expiresAt adds one second for the hook's exclusive deadline comparison.
    function _read(IAggregatorV3 feed, uint8 decimals_, uint32 maxAge, uint128 minPrice, uint128 maxPrice)
        private
        view
        returns (Reading memory reading)
    {
        if (feed.decimals() != decimals_) revert FeedDecimalsChanged(address(feed));
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0) revert InvalidRound(address(feed));
        // The positive-answer check above makes this sign conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 unsignedAnswer = uint256(answer);
        if (
            roundId == 0 || answeredInRound < roundId || unsignedAnswer > type(uint128).max || startedAt == 0
                || startedAt > updatedAt || updatedAt > block.timestamp
                || updatedAt > type(uint64).max - uint256(maxAge) - 1
        ) revert InvalidRound(address(feed));
        if (block.timestamp - updatedAt > maxAge) revert StaleFeed(address(feed));
        reading.price = unsignedAnswer * 10 ** (18 - decimals_);
        if (reading.price < minPrice || reading.price > maxPrice) {
            revert PriceOutOfBounds(address(feed), reading.price);
        }
        // The timestamp bound above reserves enough uint64 space for maxAge + 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        reading.updatedAt = uint64(updatedAt);
        // Hook expiry is exclusive; a feed remains valid at exactly maxAge seconds.
        // forge-lint: disable-next-line(unsafe-typecast)
        reading.expiresAt = uint64(updatedAt + maxAge + 1);
    }

    /// @dev Uptime feeds report transitions, not periodic prices; an old unchanged "up" record is valid.
    /// @return recoveredAt Last "up" transition timestamp, or zero when sequencer checks are disabled.
    function _checkSequencer() private view returns (uint256 recoveredAt) {
        if (address(sequencerFeed) == address(0)) return 0;
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt,) =
            sequencerFeed.latestRoundData();
        if (
            roundId == 0 || answer != 0 || startedAt == 0 || startedAt > block.timestamp
                || updatedAt < startedAt || updatedAt > block.timestamp
        ) {
            revert SequencerUnavailable();
        }
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod();
        // Uptime feeds signal transitions; they do not have a normal price-feed heartbeat.
        return startedAt;
    }

    /// @dev Rejects missing code, zero/overlong age limits, and inverted or zero value bounds.
    function _validateConfig(FeedConfig memory config) private view {
        if (
            address(config.feed).code.length == 0 || config.maxAge == 0 || config.maxAge > 2 days
                || config.minPrice == 0 || config.minPrice >= config.maxPrice
        ) revert InvalidConfiguration();
    }
}

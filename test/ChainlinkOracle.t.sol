// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ChainlinkOracle } from "../src/oracle/ChainlinkOracle.sol";
import { MarketCalendar } from "../src/oracle/MarketCalendar.sol";
import { MockAggregator } from "./mocks/MockAggregator.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IMarketCalendar } from "../src/interfaces/IMarketCalendar.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";

contract ChainlinkOracleTest is Test {
    ChainlinkOracle internal adapter;
    MarketCalendar internal calendar;
    MockAggregator internal assetFeed;
    MockAggregator internal quoteFeed;
    MockAggregator internal sequencer;
    uint64 internal sessionOpen;
    uint64 internal sessionClose;

    function setUp() public virtual {
        vm.warp(1_800_014_400); // A fixed UTC day, safely inside the local session.
        sessionOpen = uint64(block.timestamp - 60);
        sessionClose = uint64((block.timestamp / 1 days + 1) * 1 days);
        calendar = new MarketCalendar(address(this), address(0x1234));
        MarketCalendar.Session[] memory windows = new MarketCalendar.Session[](1);
        windows[0] = MarketCalendar.Session(sessionOpen, sessionClose);
        calendar.schedule(windows);
        assetFeed = new MockAggregator(8, "SPY / USD", address(this));
        quoteFeed = new MockAggregator(6, "USDC / USD", address(this));
        sequencer = new MockAggregator(0, "Sequencer", address(this));
        assetFeed.publish(150e8);
        quoteFeed.publish(1e6);
        adapter = _adapter(IAggregatorV3(address(0)), 0);
    }

    function test_WithoutCalendarFreshPricesRemainUsableAfterMarketClose() public {
        adapter = new ChainlinkOracle(
            ChainlinkOracle.FeedConfig(assetFeed, 300, 1e18, 10000e18),
            ChainlinkOracle.FeedConfig(quoteFeed, 3600, 0.8e18, 1.2e18),
            IMarketCalendar(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        vm.warp(sessionClose + 2 days);
        assetFeed.publish(150e8);
        quoteFeed.publish(1e6);
        assertTrue(adapter.latestObservation().marketOpen);
        assertEq(adapter.latestObservation().validUntil, block.timestamp + 301);
        vm.warp(block.timestamp + 301);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.StaleFeed.selector, address(assetFeed)));
        adapter.latestObservation();
    }

    function test_DailyHeartbeatToleranceExpiresAtConfiguredAge() public {
        adapter = new ChainlinkOracle(
            ChainlinkOracle.FeedConfig(assetFeed, 26 hours, 1e18, 10000e18),
            ChainlinkOracle.FeedConfig(quoteFeed, 26 hours, 0.8e18, 1.2e18),
            IMarketCalendar(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        uint256 publishedAt = block.timestamp;
        vm.warp(publishedAt + 26 hours);
        assertEq(adapter.latestObservation().price, 150e18);
        assertEq(adapter.latestObservation().validUntil, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.StaleFeed.selector, address(assetFeed)));
        adapter.latestObservation();
    }

    function _adapter(IAggregatorV3 uptime, uint32 grace) internal returns (ChainlinkOracle) {
        return new ChainlinkOracle(
            ChainlinkOracle.FeedConfig(assetFeed, 300, 1e18, 10000e18),
            ChainlinkOracle.FeedConfig(quoteFeed, 3600, 0.8e18, 1.2e18),
            calendar,
            uptime,
            grace
        );
    }

    function test_CrossRateNormalizesDifferentDecimals() public view {
        IPriceOracle.Observation memory observation = adapter.latestObservation();
        assertEq(observation.price, 150e18);
        assertEq(observation.updatedAt, block.timestamp);
        assertEq(observation.validUntil, block.timestamp + 301);
    }

    function test_QuoteDepegChangesPriceInQuoteUnits() public {
        quoteFeed.publish(0.96e6);
        assertEq(adapter.latestObservation().price, 156.25e18);
    }

    function testFuzz_QuoteConversion(uint64 answer) public {
        answer = uint64(bound(answer, 800_000, 1_200_000));
        quoteFeed.publish(int256(uint256(answer)));
        uint256 price = adapter.latestObservation().price;
        // Converting back to USD must recover the asset price, with bounded integer rounding.
        assertApproxEqAbs(price * answer / 1e6, 150e18, 2);
    }

    function test_FeedAgesAreIndependent() public {
        vm.warp(block.timestamp + 301);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.StaleFeed.selector, address(assetFeed)));
        adapter.latestObservation();
        assetFeed.publish(150e8);
        assertEq(adapter.latestObservation().price, 150e18); // Quote heartbeat is longer.
        vm.warp(block.timestamp + 3300);
        assetFeed.publish(150e8);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.StaleFeed.selector, address(quoteFeed)));
        adapter.latestObservation();
    }

    function test_FreshnessBoundaryIsInclusive() public {
        vm.warp(block.timestamp + 300);
        assertEq(adapter.latestObservation().validUntil, block.timestamp + 1);
    }

    function test_BothFeedsMustBeFreshAndPositive() public {
        assetFeed.publish(0);
        _invalidRound(assetFeed);
        assetFeed.publish(-1);
        _invalidRound(assetFeed);
        assetFeed.publish(150e8);
        quoteFeed.publish(0);
        _invalidRound(quoteFeed);
    }

    function test_IncompleteAndFutureRoundsRejected() public {
        _round(assetFeed, 2, 150e8, block.timestamp, block.timestamp, 1);
        _invalidRound(assetFeed);
        _round(assetFeed, 2, 150e8, block.timestamp, block.timestamp + 1, 2);
        _invalidRound(assetFeed);
        _round(assetFeed, 2, 150e8, 0, 0, 2);
        _invalidRound(assetFeed);
        _round(assetFeed, 0, 150e8, block.timestamp, block.timestamp, 0);
        _invalidRound(assetFeed);
    }

    function test_ConfiguredValueBoundsRejectUnexpectedPrices() public {
        quoteFeed.publish(0.5e6);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.PriceOutOfBounds.selector, address(quoteFeed), 0.5e18)
        );
        adapter.latestObservation();
        quoteFeed.publish(1e6);
        assetFeed.publish(10001e8);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.PriceOutOfBounds.selector, address(assetFeed), 10001e18)
        );
        adapter.latestObservation();
    }

    function test_ProxyDecimalChangeFailsClosed() public {
        vm.mockCall(address(assetFeed), abi.encodeCall(IAggregatorV3.decimals, ()), abi.encode(uint8(18)));
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.FeedDecimalsChanged.selector, address(assetFeed))
        );
        adapter.latestObservation();
    }

    function test_FeedRevertPropagates() public {
        vm.mockCallRevert(
            address(assetFeed), abi.encodeCall(IAggregatorV3.latestRoundData, ()), "feed unavailable"
        );
        vm.expectRevert();
        adapter.latestObservation();
    }

    function test_CalendarPauseAndFreshReopeningPrice() public {
        calendar.setPaused(true);
        vm.expectRevert(ChainlinkOracle.MarketClosed.selector);
        adapter.latestObservation();
        vm.warp(block.timestamp + 1);
        calendar.setPaused(false);
        vm.expectRevert(ChainlinkOracle.AwaitingOpeningPrice.selector);
        adapter.latestObservation();
        assetFeed.publish(150e8);
        assertEq(adapter.latestObservation().price, 150e18);
    }

    function test_SessionCloseAndUnscheduledDaysAreClosed() public {
        vm.warp(sessionClose);
        vm.expectRevert(ChainlinkOracle.MarketClosed.selector);
        adapter.latestObservation();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(ChainlinkOracle.MarketClosed.selector);
        adapter.latestObservation();
    }

    function test_PreviousSessionPriceNotUsedAtOpen() public {
        _round(assetFeed, 2, 150e8, sessionOpen - 1, sessionOpen - 1, 2);
        vm.expectRevert(ChainlinkOracle.AwaitingOpeningPrice.selector);
        adapter.latestObservation();
    }

    function test_SessionExpiryCapsFeedExpiry() public {
        vm.warp(sessionClose - 10);
        assetFeed.publish(150e8);
        quoteFeed.publish(1e6);
        assertEq(adapter.latestObservation().validUntil, sessionClose);
    }

    function test_SequencerDownAndUninitializedRejected() public {
        adapter = _adapter(sequencer, 60);
        sequencer.publish(1);
        vm.expectRevert(ChainlinkOracle.SequencerUnavailable.selector);
        adapter.latestObservation();
        _round(sequencer, 2, 0, 0, block.timestamp, 2);
        vm.expectRevert(ChainlinkOracle.SequencerUnavailable.selector);
        adapter.latestObservation();
    }

    function test_SequencerGraceAndPostRecoveryDataRequired() public {
        adapter = _adapter(sequencer, 60);
        vm.warp(block.timestamp + 1);
        sequencer.publish(0);
        vm.warp(block.timestamp + 60);
        vm.expectRevert(ChainlinkOracle.SequencerGracePeriod.selector);
        adapter.latestObservation();
        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.AwaitingPostRecoveryPrice.selector, address(assetFeed))
        );
        adapter.latestObservation();
        assetFeed.publish(150e8);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.AwaitingPostRecoveryPrice.selector, address(quoteFeed))
        );
        adapter.latestObservation();
        quoteFeed.publish(1e6);
        assertEq(adapter.latestObservation().price, 150e18);
    }

    function test_UptimeFeedDoesNotNeedPriceHeartbeat() public {
        adapter = _adapter(sequencer, 60);
        _round(sequencer, 2, 0, block.timestamp - 30 days, block.timestamp - 30 days, 2);
        assertEq(adapter.latestObservation().price, 150e18);
    }

    function test_RevertWhen_DeploymentFeedConfigurationIsInvalid() public {
        ChainlinkOracle.FeedConfig memory asset = ChainlinkOracle.FeedConfig(assetFeed, 300, 1e18, 10000e18);
        ChainlinkOracle.FeedConfig memory quote = ChainlinkOracle.FeedConfig(quoteFeed, 3600, 0.8e18, 1.2e18);
        asset.maxAge = 0;
        _rejectConfiguration(asset, quote);
        asset.maxAge = 172801;
        _rejectConfiguration(asset, quote);
        asset.maxAge = 300;
        asset.minPrice = 0;
        _rejectConfiguration(asset, quote);
        asset.minPrice = asset.maxPrice;
        _rejectConfiguration(asset, quote);
        asset.minPrice = 1e18;
        asset.feed = IAggregatorV3(address(0xdead));
        _rejectConfiguration(asset, quote);
        asset.feed = quoteFeed;
        _rejectConfiguration(asset, quote);
    }

    function test_RevertWhen_FeedDecimalsAreUnsupportedAtDeployment() public {
        vm.mockCall(address(assetFeed), abi.encodeCall(IAggregatorV3.decimals, ()), abi.encode(uint8(19)));
        vm.expectRevert(ChainlinkOracle.InvalidConfiguration.selector);
        _adapter(IAggregatorV3(address(0)), 0);
    }

    function test_RevertWhen_SequencerConfigurationIsInconsistent() public {
        vm.expectRevert(ChainlinkOracle.InvalidConfiguration.selector);
        _adapter(IAggregatorV3(address(0)), 60);
        vm.expectRevert(ChainlinkOracle.InvalidConfiguration.selector);
        _adapter(sequencer, 0);
        vm.expectRevert(ChainlinkOracle.InvalidConfiguration.selector);
        _adapter(IAggregatorV3(address(0xdead)), 60);
    }

    function test_RevertWhen_RoundStartIsAfterItsUpdate() public {
        _round(assetFeed, 2, 150e8, block.timestamp + 1, block.timestamp, 2);
        _invalidRound(assetFeed);
    }

    function test_RevertWhen_AnswerCannotBeNormalizedWithinSupportedBounds() public {
        _round(assetFeed, 2, type(int256).max, block.timestamp, block.timestamp, 2);
        _invalidRound(assetFeed);
    }

    function test_QuoteExpiryCanBeEarlierThanAssetExpiry() public {
        _round(quoteFeed, 2, 1e6, block.timestamp - 3599, block.timestamp - 3599, 2);
        IPriceOracle.Observation memory observation = adapter.latestObservation();
        assertEq(observation.updatedAt, block.timestamp - 3599);
        assertEq(observation.validUntil, block.timestamp + 2);
    }

    function test_LocalFeedPublisherIsRestricted() public {
        vm.prank(address(0xdead));
        vm.expectRevert(MockAggregator.Unauthorized.selector);
        assetFeed.publish(1);
    }

    function _rejectConfiguration(
        ChainlinkOracle.FeedConfig memory asset,
        ChainlinkOracle.FeedConfig memory quote
    ) private {
        vm.expectRevert(ChainlinkOracle.InvalidConfiguration.selector);
        new ChainlinkOracle(asset, quote, calendar, IAggregatorV3(address(0)), 0);
    }

    function _round(
        MockAggregator feed,
        uint80 id,
        int256 answer,
        uint256 start,
        uint256 updated,
        uint80 answered
    ) internal {
        vm.mockCall(
            address(feed),
            abi.encodeCall(IAggregatorV3.latestRoundData, ()),
            abi.encode(id, answer, start, updated, answered)
        );
    }

    function _invalidRound(MockAggregator feed) private {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.InvalidRound.selector, address(feed)));
        adapter.latestObservation();
    }
}

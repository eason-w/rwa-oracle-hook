// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { OracleFixture } from "./fixtures/OracleFixture.sol";

/// @notice Full path: feeds -> adapter -> hook -> real PoolManager -> settlement.
contract OraclePoolIntegrationTest is OracleFixture {
    function setUp() public {
        _setupOracle(false);
    }

    function test_RealAdapterFeeAccruesToLP() public {
        assetFeed.publish(153e8);
        (uint24 fee,,,) = hook.previewFee(key, false);
        _buy(100e6);
        uint256 beforeBalance = quote.balanceOf(address(this));
        router.modifyLiquidity(0, 0, 0, block.timestamp);
        assertApproxEqAbs(quote.balanceOf(address(this)) - beforeBalance, uint256(fee) * 100e6 / 1e6, 2);
    }

    function test_QuoteDepegChangesSwapDirectionAndFee() public {
        quoteFeed.publish(0.96e8);
        (uint24 buyFee, bool corrective,, uint256 referencePrice) = hook.previewFee(key, false);
        (uint24 sellFee,,,) = hook.previewFee(key, true);
        assertEq(referencePrice, 156.25e18);
        assertTrue(corrective);
        assertGt(buyFee, sellFee);
        _buy(100e6);
    }

    function test_SlowQuoteHeartbeatDoesNotOverrestrictHook() public {
        vm.warp(block.timestamp + 301);
        assetFeed.publish(150e8);
        _buy(100e6);
    }

    function test_StaleFeedUsesFallbackAndAllowsCompleteWithdrawal() public {
        vm.warp(block.timestamp + 301);
        (uint24 fee,,, uint256 referencePrice) = hook.previewFee(key, false);
        assertEq(fee, hook.maxFee());
        assertEq(referencePrice, 0);
        _buy(100e6);
        _exit();
    }

    function test_InvalidFeedCannotTrapLiquidity() public {
        quoteFeed.publish(0);
        (uint24 fee,,, uint256 referencePrice) = hook.previewFee(key, false);
        assertEq(fee, hook.maxFee());
        assertEq(referencePrice, 0);
        _buy(100e6);
        _exit();
    }

    function test_ClosedMarketWithFreshFeedsStillTradesAndWithdraws() public {
        calendar.setPaused(true);
        _buy(100e6);
        _exit();
    }

    function test_InformationalCalendarDoesNotInvalidateFreshPrices() public {
        calendar.setPaused(true);
        vm.warp(block.timestamp + 1);
        calendar.setPaused(false);
        _buy(100e6);
        assetFeed.publish(150e8);
        _buy(100e6);
    }

    function _exit() private {
        router.modifyLiquidity(-int256(uint256(SEED_LIQUIDITY)), 0, 0, block.timestamp);
        assertEq(router.liquidityOf(address(this)), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(quote.balanceOf(address(adapter)), 0);
    }
}

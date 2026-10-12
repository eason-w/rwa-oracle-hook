// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolFixture } from "./fixtures/PoolFixture.sol";
import { RwaOracleHook } from "../src/RwaOracleHook.sol";
import { PoolRouter } from "./helpers/PoolRouter.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";
import { OraclePriceMath } from "../src/libraries/OraclePriceMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract RwaOracleHookTest is PoolFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function setUp() public virtual {
        _setup(false);
    }

    function test_MinedPermissionsAndPriceUnits() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x2080);
        assertApproxEqAbs(hook.getPoolPrice(key), 150e18, 2);
    }

    function test_DirectionalPolicy() public view {
        (uint24 correction, bool corrective) =
            hook.feeForPrices(147e18, 150e18, address(quote) < address(asset));
        (uint24 divergence, bool diverging) =
            hook.feeForPrices(147e18, 150e18, address(asset) < address(quote));
        assertTrue(corrective);
        assertFalse(diverging);
        assertEq(correction, 3000);
        assertEq(divergence, 0);
    }

    function test_ReferenceSpreadAndInventoryImprovingFlow() public view {
        (uint24 fee,) = hook.feeForPrices(150e18, 150e18, true);
        assertEq(fee, 500);
        (fee,) = hook.feeForPrices(150.3e18, 150e18, address(quote) < address(asset));
        assertEq(fee, 0);
        (fee,) = hook.feeForPrices(149.7e18, 150e18, address(asset) < address(quote));
        assertEq(fee, 0);
    }

    function test_BuyThenSellMovesPriceInExpectedDirection() public {
        _buy(100e6);
        assertGt(hook.getPoolPrice(key), 150e18);
        _sell(2e18);
        assertLt(hook.getPoolPrice(key), 150e18);
    }

    function test_FeesAccrueToLPWithoutHookCustody() public {
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        _buy(1000e6);
        uint256 beforeQuote = quote.balanceOf(address(this));
        router.modifyLiquidity(0, 0, 0, block.timestamp);
        assertApproxEqAbs(quote.balanceOf(address(this)) - beforeQuote, 1000e6 * uint256(fee) / 1e6, 2);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(asset.balanceOf(address(hook)), 0);
    }

    function test_GapFeeAccruesToLP() public {
        _publish(153e18);
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertGt(fee, 500);
        _buy(100e6);
        uint256 beforeQuote = quote.balanceOf(address(this));
        router.modifyLiquidity(0, 0, 0, block.timestamp);
        assertApproxEqAbs(quote.balanceOf(address(this)) - beforeQuote, 100e6 * uint256(fee) / 1e6, 2);
    }

    function test_FirstCorrectiveSwapStartsDecayAutomatically() public {
        _publish(153e18);
        (, uint64 beforeStart,) = hook.auction();
        assertEq(beforeStart, 0);
        _buy(100e6);
        (, uint64 start, int8 side) = hook.auction();
        assertEq(start, block.timestamp);
        assertEq(side, -1);
        vm.warp(block.timestamp + 150);
        vm.roll(block.number + 1);
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 2000);
    }

    function test_OracleJumpAllowsIncrementalRecovery() public {
        _publish(180e18);
        uint256 beforePrice = hook.getPoolPrice(key);
        _buy(100e6);
        uint256 afterPrice = hook.getPoolPrice(key);
        assertGt(afterPrice, beforePrice);
        assertGt(OraclePriceMath.deviationBps(afterPrice, 180e18), 500);
        _sell(1e18);
    }

    function test_DownwardOracleJumpAllowsRecovery() public {
        _publish(120e18);
        _sell(1e18);
        assertLt(hook.getPoolPrice(key), 150e18);
        _buy(100e6);
    }

    function test_LargeTradesUsePriceImpactAndUserSlippageWithoutOracleRejection() public {
        _buy(10_000e6);
        assertGt(hook.getPoolPrice(key), 157.5e18);
        _publish(180e18);
        _buy(40_000e6);
        assertGt(hook.getPoolPrice(key), 189e18);
    }

    function test_ExtremePoolPriceUsesFallbackAndAllowsRecovery() public {
        quote.mint(address(this), 1e22);
        _buy(1e22);
        assertGt(hook.getPoolPrice(key), 1e30);
        _assertFallback();
        _sell(1e18);
        assertLt(hook.getPoolPrice(key), 1e30);
        (uint24 fee,,, uint256 referencePrice) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(referencePrice, 150e18);
        assertEq(fee, 0);
    }

    function test_ViewQuotesDoNotStartOrAdvanceAuctionState() public {
        _publish(153e18);
        hook.previewFee(key, true);
        (uint128 referencePrice,,) = hook.auction();
        assertEq(referencePrice, 0);
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 3000);
    }

    function test_NewReportWithUnchangedPriceKeepsAuctionAge() public {
        _publish(153e18);
        hook.refreshFees();
        (, uint64 startedAt,) = hook.auction();
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 1);
        _publish(153e18);
        hook.refreshFees();
        (, uint64 nextStart,) = hook.auction();
        assertEq(nextStart, startedAt);
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 2800);
    }

    function test_SameBlockSplitPaysTheSameFeeRateToLPs() public {
        _publish(153e18);
        hook.refreshFees();
        _buy(200e6);
        _buy(300e6);
        uint256 balanceBefore = quote.balanceOf(address(this));
        router.modifyLiquidity(0, 0, 0, block.timestamp);
        assertApproxEqAbs(quote.balanceOf(address(this)) - balanceBefore, 1.5e6, 2);
    }

    function test_RefreshStartsDecayWithoutARequiredTradeAndCannotRestartIt() public {
        _publish(153e18);
        vm.prank(makeAddr("keeper"));
        hook.refreshFees();
        (, uint64 start,) = hook.auction();
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 1);
        hook.refreshFees();
        (, uint64 unchanged,) = hook.auction();
        assertEq(unchanged, start);
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 2800);
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 1);
        (fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 2600);
    }

    function test_NewReferenceResetsAuctionAndInvalidatesSameBlockCache() public {
        _publish(153e18);
        hook.refreshFees();
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        hook.refreshFees();
        _publish(156e18);
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 3000);
        hook.refreshFees();
        (uint128 referencePrice, uint64 start,) = hook.auction();
        assertEq(referencePrice, 156e18);
        assertEq(start, block.timestamp);
    }

    function test_SameBlockLegsKeepTheirFeeEvenWhenTheSpotCrossesReference() public {
        _publish(153e18);
        hook.refreshFees();
        _buy(5000e6);
        assertGt(hook.getPoolPrice(key), 153e18);
        (uint24 buyFee,,,) = hook.previewFee(key, address(quote) < address(asset));
        (uint24 sellFee,,,) = hook.previewFee(key, address(asset) < address(quote));
        assertEq(buyFee, 3000);
        assertEq(sellFee, 0);
        _buy(100e6);
        vm.roll(block.number + 1);
        (buyFee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(buyFee, 0);
        hook.refreshFees();
        (,, int8 side) = hook.auction();
        assertEq(side, 1);
    }

    function test_UnavailableDataClearsAuctionAndHealthyRecoveryReprices() public {
        _publish(153e18);
        hook.refreshFees();
        oracle.publish(153e18, false, uint64(block.timestamp + 300));
        hook.refreshFees();
        (uint128 referencePrice,,) = hook.auction();
        assertEq(referencePrice, 0);
        _publish(153e18);
        hook.refreshFees();
        (uint24 fee,,,) = hook.previewFee(key, address(quote) < address(asset));
        assertEq(fee, 3000);
    }

    function testFuzz_CorrectiveFeeDecaysAndNeverExceedsOpening(uint32 elapsed) public view {
        (uint24 opening,) = hook.feeForPrices(147e18, 150e18, address(quote) < address(asset));
        (uint24 decayed,) = hook.feeForPricesAtAge(147e18, 150e18, address(quote) < address(asset), elapsed);
        assertLe(decayed, opening);
        assertGe(decayed, 1000);
        if (elapsed >= 300) assertEq(decayed, 1000);
    }

    function test_StaleOracleUsesFlatFeeAndAllowsWithdrawal() public {
        vm.warp(block.timestamp + 301);
        _assertFallback();
        _buy(100e6);
        uint256 beforeQuote = quote.balanceOf(address(this));
        router.modifyLiquidity(0, 0, 0, block.timestamp);
        assertApproxEqAbs(quote.balanceOf(address(this)) - beforeQuote, 0.3e6, 2);
        router.modifyLiquidity(-int256(uint256(SEED_LIQUIDITY)), 0, 0, block.timestamp);
        assertEq(router.liquidityOf(address(this)), 0);
    }

    function test_ClosedObservationUsesFlatFee() public {
        oracle.publish(150e18, false, uint64(block.timestamp + 8 hours));
        _assertFallback();
        _buy(1e6);
        _sell(1e16);
    }

    function test_ExclusiveExpirySelectsFallback() public {
        oracle.publish(150e18, true, uint64(block.timestamp + 300));
        vm.warp(block.timestamp + 299);
        (uint24 fee,,,) = hook.previewFee(key, true);
        assertApproxEqAbs(fee, hook.baseFee(), 2);
        vm.warp(block.timestamp + 1);
        _assertFallback();
    }

    function test_MaxAgeInclusiveAndRefreshRestoresDirectionalFees() public {
        vm.warp(block.timestamp + 300);
        (uint24 fee,,,) = hook.previewFee(key, true);
        assertApproxEqAbs(fee, hook.baseFee(), 2);
        vm.warp(block.timestamp + 1);
        _assertFallback();
        _buy(1e6);
        _publish(150e18);
        (fee,,,) = hook.previewFee(key, true);
        assertLe(fee, hook.maxFee());
        _buy(1e6);
    }

    function test_InvalidObservationsUseFallback() public {
        IPriceOracle.Observation memory bad =
            IPriceOracle.Observation(150e18, 0, uint64(block.timestamp + 1), true);
        vm.mockCall(address(oracle), abi.encodeCall(oracle.latestObservation, ()), abi.encode(bad));
        _assertFallback();
        bad.updatedAt = uint64(block.timestamp + 1);
        vm.mockCall(address(oracle), abi.encodeCall(oracle.latestObservation, ()), abi.encode(bad));
        _assertFallback();
        bad.price = 0;
        vm.mockCall(address(oracle), abi.encodeCall(oracle.latestObservation, ()), abi.encode(bad));
        _assertFallback();
    }

    function test_UnavailableOracleAllowsSwapsAndWithdrawal() public {
        vm.mockCallRevert(address(oracle), abi.encodeCall(oracle.latestObservation, ()), "unavailable");
        _assertFallback();
        _buy(1e6);
        router.modifyLiquidity(-int256(uint256(SEED_LIQUIDITY)), 0, 0, block.timestamp);
    }

    function test_MalformedOracleResponseUsesFallback() public {
        vm.mockCall(address(oracle), abi.encodeCall(oracle.latestObservation, ()), hex"1234");
        _assertFallback();
        _buy(1e6);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(oracle.latestObservation, ()),
            abi.encode(150e18, block.timestamp, block.timestamp + 300, uint256(2))
        );
        _assertFallback();
    }

    function test_FallbackDoesNotAnchorToExpiredPriceAndFreshRecoveryWorks() public {
        vm.warp(block.timestamp + 301);
        _buy(10_000e6);
        assertGt(hook.getPoolPrice(key), 157.5e18);
        _publish(150e18);
        _buy(1e6);
        _sell(1e18);
    }

    function test_OracleExhaustingItsBudgetStillSelectsFallback() public {
        // An invalid instruction in the test adapter consumes all forwarded gas.
        vm.etch(address(oracle), hex"fe");
        _assertFallback();
        _buy(1e6);
    }

    function test_UnderfundedOracleReadRevertsInsteadOfSelectingFallback() public {
        vm.expectRevert(RwaOracleHook.InsufficientOracleGas.selector);
        hook.previewFee{ gas: 210_000 }(key, true);
    }

    function _assertFallback() internal view {
        for (uint256 i; i < 2; i++) {
            (uint24 fee, bool corrective,, uint256 referencePrice) = hook.previewFee(key, i == 0);
            assertEq(fee, hook.maxFee());
            assertFalse(corrective);
            assertEq(referencePrice, 0);
        }
    }

    function test_OtherPoolConfigurationsRejected() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert(RwaOracleHook.UnsupportedPool.selector);
        hook.previewFee(wrong, true);
        wrong = key;
        wrong.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrong, _sqrtPrice(150e18));
    }

    function test_CallbacksOnlyPoolManager() public {
        vm.expectRevert();
        hook.beforeSwap(address(this), key, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), "");
    }

    function test_ExactOutputWorksThroughStandardV4Router() public {
        PoolSwapTest exactOutputRouter = new PoolSwapTest(manager);
        quote.approve(address(exactOutputRouter), type(uint256).max);
        uint256 beforeAsset = asset.balanceOf(address(this));
        bool direction = address(quote) < address(asset);
        exactOutputRouter.swap(
            key,
            SwapParams(
                direction, 1e18, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(asset.balanceOf(address(this)) - beforeAsset, 1e18);
    }

    function test_RouterPositionIsolation() public {
        address secondLP = makeAddr("second LP");
        vm.prank(secondLP);
        vm.expectRevert();
        router.modifyLiquidity(-1, 0, 0, block.timestamp);
        assertEq(router.liquidityOf(address(this)), SEED_LIQUIDITY);
    }

    function test_RouterDeadlineAndSlippage() public {
        vm.expectRevert(PoolRouter.Expired.selector);
        router.swap(false, 100e6, 0, block.timestamp - 1);
        vm.expectRevert(PoolRouter.Slippage.selector);
        router.swap(address(quote) < address(asset), 100e6, 100e18, block.timestamp);
        vm.expectRevert(PoolRouter.Slippage.selector);
        router.modifyLiquidity(1e15, 0, 0, block.timestamp);
        vm.expectRevert(PoolRouter.Slippage.selector);
        router.modifyLiquidity(-1e15, type(uint256).max, type(uint256).max, block.timestamp);
    }

    function testFuzz_FeeBoundsAndDirectionalOrdering(uint256 price, uint256 referencePrice) public view {
        price = bound(price, 1e12, 1e26);
        referencePrice = bound(referencePrice, 1e12, 1e26);
        (uint24 buyFee,) = hook.feeForPrices(price, referencePrice, address(quote) < address(asset));
        (uint24 sellFee,) = hook.feeForPrices(price, referencePrice, address(asset) < address(quote));
        assertLe(buyFee, hook.maxFee());
        assertLe(sellFee, hook.maxFee());
        if (price < referencePrice) assertGe(buyFee, sellFee);
        else assertLe(buyFee, sellFee);
    }

    function testFuzz_SmallTradesMovePriceInTheirDirection(uint96 amount, bool buy) public {
        if (buy) _buy(bound(amount, 1e6, 1000e6));
        else _sell(bound(amount, 1e15, 5e18));
        if (buy) assertGt(hook.getPoolPrice(key), 150e18);
        else assertLt(hook.getPoolPrice(key), 150e18);
    }
}

/// @dev Run the same integration suite with the 6-decimal quote as currency0.
contract ReversedCurrencyOrderTest is RwaOracleHookTest {
    function setUp() public override {
        _setup(true);
    }
}

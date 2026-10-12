// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

/// @notice Test settlement harness for exercising swaps, LP accounting and caller-owned ranges.
/// @dev Not a deployment artifact; integrations should use the canonical v4 periphery.
contract PoolRouter is IUnlockCallback {
    using SafeTransferLib for ERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Encoded unlock operation; limit0 is minimum output for swaps, token0 limit otherwise.
    struct Request {
        address payer;
        bool isSwap;
        bool zeroForOne;
        int256 amount;
        uint256 limit0;
        uint256 limit1;
        int24 lower;
        int24 upper;
    }

    /// @notice Selected native v4 ticks. An unset range defaults to full range.
    struct Range {
        int24 lower;
        int24 upper;
    }

    mapping(address provider => Range range) private _ranges;

    /// @notice PoolManager used for every operation and the only allowed callback caller.
    IPoolManager public immutable manager;
    /// @notice Lowest usable tick for the configured spacing.
    int24 public immutable tickLower;
    /// @notice Highest usable tick for the configured spacing.
    int24 public immutable tickUpper;
    PoolKey private _key;

    /// @notice A fully filled exact-input trade settled successfully.
    /// @param trader Account paying input and receiving output.
    /// @param zeroForOne True for currency0 input.
    /// @param amountIn Raw input-token units paid.
    /// @param amountOut Raw output-token units received.
    event Trade(address indexed trader, bool zeroForOne, uint256 amountIn, uint256 amountOut);
    /// @notice A caller-owned position changed liquidity or collected fees.
    /// @param provider Owner identified by the position salt.
    /// @param liquidityDelta Signed liquidity-unit change; zero represents fee collection.
    event LiquidityChanged(address indexed provider, int256 liquidityDelta);

    /// @notice Unlock callback caller is not the configured PoolManager.
    error Unauthorized();
    /// @notice The transaction deadline has passed.
    error Expired();
    /// @notice A token amount limit or exact-input fill requirement was not met.
    error Slippage();
    /// @notice An input amount is zero/out of range or the pool uses unsupported native currency.
    error InvalidAmount();
    /// @notice Ticks must be ordered, within bounds and aligned with the pool's spacing.
    error InvalidRange();
    /// @notice Withdraw the existing position fully before selecting a different range.
    error PositionStillOpen();

    /// @notice Configures a settlement harness for a single ERC20 pool.
    /// @param manager_ PoolManager storing the pool.
    /// @param key_ Initialized pool identity; native currency0 is not supported.
    constructor(IPoolManager manager_, PoolKey memory key_) {
        if (Currency.unwrap(key_.currency0) == address(0)) revert InvalidAmount();
        manager = manager_;
        _key = key_;
        tickLower = TickMath.minUsableTick(key_.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key_.tickSpacing);
    }

    /// @notice Returns the fixed pool identity used by this router.
    /// @return configuredKey Sorted currencies, fee, tick spacing and hook address.
    function poolKey() external view returns (PoolKey memory configuredKey) {
        return _key;
    }

    /// @notice Reads liquidity owned by a provider through this router.
    /// @param provider Account whose address is used as the position salt.
    /// @return liquidity Position liquidity units, not token amounts or a USD value.
    function liquidityOf(address provider) external view returns (uint128 liquidity) {
        (,, liquidity) = positionOf(provider);
    }

    /// @notice Reads the provider's selected ticks and current native position liquidity.
    /// @param provider Position owner; unrelated accounts cannot modify this position.
    /// @return lower Lower v4 tick, inclusive.
    /// @return upper Upper v4 tick, exclusive.
    /// @return liquidity Current liquidity units; zero means no active deposit.
    function positionOf(address provider) public view returns (int24 lower, int24 upper, uint128 liquidity) {
        (lower, upper) = _rangeOf(provider);
        (liquidity,,) = manager.getPositionInfo(
            _key.toId(), address(this), lower, upper, bytes32(uint256(uint160(provider)))
        );
    }

    /// @dev Read range selection without an unnecessary PoolManager liquidity read.
    function _rangeOf(address provider) private view returns (int24 lower, int24 upper) {
        Range memory range = _ranges[provider];
        lower = range.lower == range.upper ? tickLower : range.lower;
        upper = range.lower == range.upper ? tickUpper : range.upper;
    }

    /// @notice Calculates both deposit amounts from one token budget at the current pool price.
    /// @dev Uses native tick and liquidity math. Required amounts round up, liquidity rounds down.
    ///      Outside the range, only the required token can determine a deposit. This is a view quote;
    ///      callers must still supply amount limits when submitting against changing pool state.
    /// @param lower Lower aligned tick.
    /// @param upper Upper aligned tick.
    /// @param currency0Input Whether amount is a currency0 budget; otherwise currency1.
    /// @param amount Raw units of the selected token, bounded to int128.max.
    /// @return liquidity Native v4 liquidity units supported by the selected budget.
    /// @return amount0 Required currency0 deposit, before any existing fee credit.
    /// @return amount1 Required currency1 deposit, before any existing fee credit.
    function quoteDeposit(int24 lower, int24 upper, bool currency0Input, uint256 amount)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _validateRange({ lower: lower, upper: upper });
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidAmount();
        (uint160 price,,,) = manager.getSlot0(_key.toId());
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint160 clamped = price < a ? a : price > b ? b : price;
        if (currency0Input) {
            if (clamped == b) revert InvalidAmount();
            liquidity = LiquidityAmounts.getLiquidityForAmount0(clamped, b, amount);
        } else {
            if (clamped == a) revert InvalidAmount();
            liquidity = LiquidityAmounts.getLiquidityForAmount1(a, clamped, amount);
        }
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidAmount();
        if (clamped < b) amount0 = SqrtPriceMath.getAmount0Delta(clamped, b, liquidity, true);
        if (clamped > a) amount1 = SqrtPriceMath.getAmount1Delta(a, clamped, liquidity, true);
    }

    /// @notice Swaps exact input and pays output to the caller; partial fills are rejected.
    /// @dev Requires ERC20 allowance to this router. A failed limit check rolls back settlement.
    /// @param zeroForOne True to pay currency0 and receive currency1.
    /// @param amountIn Positive raw input-token amount, no greater than int128.max.
    /// @param minAmountOut Minimum raw output-token amount, inclusive.
    /// @param deadline Latest acceptable Unix timestamp, inclusive.
    /// @return delta Packed signed caller balance changes: negative means paid, positive means received.
    function swap(bool zeroForOne, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (BalanceDelta delta)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        return abi.decode(
            manager.unlock(
                abi.encode(
                    Request({
                        payer: msg.sender,
                        isSwap: true,
                        zeroForOne: zeroForOne,
                        // amountIn was bounded to positive int128 above.
                        // forge-lint: disable-next-line(unsafe-typecast)
                        amount: int256(amountIn),
                        limit0: minAmountOut,
                        limit1: 0,
                        lower: 0,
                        upper: 0
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    /// @notice Adds or removes caller-owned liquidity; zero delta collects accrued fees.
    /// @dev Uses the caller's selected range, defaulting to full range. Withdrawals never read the oracle.
    /// @param liquidityDelta Signed liquidity-unit change; zero collects fees.
    /// @param limit0 Maximum currency0 paid on deposits; minimum received on withdrawals/collection.
    /// @param limit1 Maximum currency1 paid on deposits; minimum received on withdrawals/collection.
    /// @param deadline Latest acceptable Unix timestamp, inclusive.
    /// @return delta Packed signed token changes, including earned fees.
    function modifyLiquidity(int256 liquidityDelta, uint256 limit0, uint256 limit1, uint256 deadline)
        external
        returns (BalanceDelta delta)
    {
        (int24 lower, int24 upper) = _rangeOf(msg.sender);
        return _modifyPosition(lower, upper, liquidityDelta, limit0, limit1, deadline);
    }

    /// @notice Adds, removes or collects from a caller-owned native v4 range.
    /// @dev Each account owns one open range, identified by its address-derived position salt.
    ///      A different range is accepted only after the previous position has zero liquidity.
    /// @param lower Lower aligned tick, inclusive.
    /// @param upper Upper aligned tick, exclusive.
    /// @param liquidityDelta Signed liquidity change; zero collects fees.
    /// @param limit0 Maximum currency0 paid on deposit; minimum received otherwise.
    /// @param limit1 Maximum currency1 paid on deposit; minimum received otherwise.
    /// @param deadline Latest acceptable Unix timestamp, inclusive.
    /// @return delta Packed signed token changes, including fee credits.
    function modifyPosition(
        int24 lower,
        int24 upper,
        int256 liquidityDelta,
        uint256 limit0,
        uint256 limit1,
        uint256 deadline
    ) external returns (BalanceDelta delta) {
        return _modifyPosition(lower, upper, liquidityDelta, limit0, limit1, deadline);
    }

    /// @dev Validate ownership/range before entering the manager. A failed settlement reverts range selection.
    function _modifyPosition(
        int24 lower,
        int24 upper,
        int256 liquidityDelta,
        uint256 limit0,
        uint256 limit1,
        uint256 deadline
    ) private returns (BalanceDelta) {
        if (block.timestamp > deadline) revert Expired();
        _validateRange({ lower: lower, upper: upper });
        (int24 oldLower, int24 oldUpper) = _rangeOf(msg.sender);
        if (oldLower != lower || oldUpper != upper) {
            (,, uint128 existing) = positionOf(msg.sender);
            if (existing != 0) revert PositionStillOpen();
            _ranges[msg.sender] = Range({ lower: lower, upper: upper });
        }
        if (liquidityDelta > type(int128).max || liquidityDelta < -int256(type(int128).max)) {
            revert InvalidAmount();
        }
        return abi.decode(
            manager.unlock(
                abi.encode(
                    Request({
                        payer: msg.sender,
                        isSwap: false,
                        zeroForOne: false,
                        amount: liquidityDelta,
                        limit0: limit0,
                        limit1: limit1,
                        lower: lower,
                        upper: upper
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Authenticates PoolManager before decoding the payer, then checks limits before transfers.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert Unauthorized();
        Request memory request = abi.decode(data, (Request));
        BalanceDelta delta;
        if (request.isSwap) {
            delta = manager.swap(
                _key,
                SwapParams({
                    zeroForOne: request.zeroForOne,
                    amountSpecified: -request.amount,
                    sqrtPriceLimitX96: request.zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 input = request.zeroForOne ? delta.amount0() : delta.amount1();
            int128 output = request.zeroForOne ? delta.amount1() : delta.amount0();
            if (input != -request.amount || output < 0) revert Slippage();
            // The output sign was checked above, so it fits uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (uint128(output) < request.limit0) revert Slippage();
            // Input is negative and output nonnegative after the checks above.
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Trade(request.payer, request.zeroForOne, uint256(-int256(input)), uint128(output));
        } else {
            (delta,) = manager.modifyLiquidity(
                _key,
                ModifyLiquidityParams({
                    tickLower: request.lower,
                    tickUpper: request.upper,
                    liquidityDelta: request.amount,
                    salt: bytes32(uint256(uint160(request.payer)))
                }),
                ""
            );
            _checkLiquidityLimit(delta.amount0(), request.limit0, request.amount > 0);
            _checkLiquidityLimit(delta.amount1(), request.limit1, request.amount > 0);
            emit LiquidityChanged(request.payer, request.amount);
        }
        _settle(_key.currency0, delta.amount0(), request.payer);
        _settle(_key.currency1, delta.amount1(), request.payer);
        return abi.encode(delta);
    }

    /// @dev Range bounds also ensure TickMath conversion is defined.
    function _validateRange(int24 lower, int24 upper) private view {
        if (
            lower >= upper || lower < tickLower || upper > tickUpper || lower % _key.tickSpacing != 0
                || upper % _key.tickSpacing != 0
        ) revert InvalidRange();
    }

    /// @dev Deposits cap outgoing amounts; withdrawals/collection require nonnegative receipts.
    function _checkLiquidityLimit(int128 delta, uint256 limit, bool deposit) private pure {
        if (deposit) {
            // Promote before negating so int128.min is representable; the result is positive.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (delta < 0 && uint256(-int256(delta)) > limit) revert Slippage();
            // Short-circuiting excludes negative values before the unsigned conversion.
            // forge-lint: disable-next-line(unsafe-typecast)
        } else if (delta < 0 || uint128(delta) < limit) {
            revert Slippage();
        }
    }

    /// @dev Negative deltas transfer the caller's tokens to PoolManager; positive deltas pay the caller.
    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta < 0) {
            manager.sync(currency);
            // Promote before negation; delta is negative, so this amount is positive.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-int256(delta));
            ERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            manager.settle();
        } else if (delta > 0) {
            // This branch requires a positive int128, which fits uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(currency, payer, uint128(delta));
        }
    }
}

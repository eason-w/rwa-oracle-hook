// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Price conversion and deviation math shared by the hook and its read interface.
library OraclePriceMath {
    /// @dev 10^-12 quote tokens per asset, represented with 18 decimal places.
    uint256 internal constant MIN_PRICE = 1e6;
    /// @dev 10^12 quote tokens per asset; keeps deviation products safely within uint256.
    uint256 internal constant MAX_PRICE = 1e30;

    /// @notice The normalized price lies outside the supported nonzero domain.
    error PriceOutOfRange();

    /// @notice Converts a v4 square-root price to quote tokens per whole asset, scaled by 1e18.
    /// @dev Floors the result. Two precision paths avoid overflowing uint256 when squaring uint160.
    /// @param sqrtPriceX96 Square root of raw currency1/currency0, in Q64.96 format.
    /// @param assetIsCurrency0 Whether the asset is currency0; false uses the reciprocal ratio.
    /// @param scale 10 ** (18 + assetDecimals - quoteDecimals); each decimal count must be <= 18.
    /// @return result Normalized price between MIN_PRICE and MAX_PRICE, inclusive.
    function price(uint160 sqrtPriceX96, bool assetIsCurrency0, uint256 scale)
        internal
        pure
        returns (uint256 result)
    {
        result = poolPrice(sqrtPriceX96, assetIsCurrency0, scale);
        validate(result);
    }

    /// @notice Converts a pool price without imposing the oracle adapter's narrower accepted domain.
    /// @dev Covers valid v4 square-root prices and scales up to 1e36. At extreme ratios the
    ///      normalized integer may round to zero. Callers must select a policy for that case.
    /// @param sqrtPriceX96 Nonzero v4 square-root price in Q64.96 format.
    /// @param assetIsCurrency0 Whether the whole-token ratio needs inversion.
    /// @param scale Whole-token decimal conversion, at most 1e36.
    /// @return result Normalized quote per asset; may be outside the supported oracle domain.
    function poolPrice(uint160 sqrtPriceX96, bool assetIsCurrency0, uint256 scale)
        internal
        pure
        returns (uint256 result)
    {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            if (ratioX192 == 0) revert PriceOutOfRange();
            result = assetIsCurrency0
                ? FullMath.mulDiv(ratioX192, scale, 1 << 192)
                : FullMath.mulDiv(1 << 192, scale, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            result = assetIsCurrency0
                ? FullMath.mulDiv(ratioX128, scale, 1 << 128)
                : FullMath.mulDiv(1 << 128, scale, ratioX128);
        }
    }

    /// @notice Reverts when a normalized price is outside the supported domain.
    /// @param value Quote-per-asset price scaled by 1e18.
    function validate(uint256 value) internal pure {
        if (value < MIN_PRICE || value > MAX_PRICE) revert PriceOutOfRange();
    }

    /// @notice Returns the absolute difference without signed arithmetic.
    /// @param a First unsigned value.
    /// @param b Second unsigned value, in the same units.
    /// @return difference Absolute distance between a and b.
    function distance(uint256 a, uint256 b) internal pure returns (uint256 difference) {
        return a > b ? a - b : b - a;
    }

    /// @notice Measures absolute deviation relative to the oracle, rounded down to whole basis points.
    /// @dev Caller must validate both prices first; referencePrice must be nonzero.
    /// @param spotPrice Current normalized pool price.
    /// @param referencePrice Oracle price in the same units.
    /// @return deviation Absolute deviation out of 10,000.
    function deviationBps(uint256 spotPrice, uint256 referencePrice)
        internal
        pure
        returns (uint256 deviation)
    {
        return FullMath.mulDiv(distance(spotPrice, referencePrice), 10_000, referencePrice);
    }
}

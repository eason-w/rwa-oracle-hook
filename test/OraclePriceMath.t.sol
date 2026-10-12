// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { OraclePriceMath } from "../src/libraries/OraclePriceMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract OraclePriceMathTest is Test {
    function test_EqualDecimalsAtParity() public pure {
        assertEq(OraclePriceMath.price(uint160(1 << 96), true, 1e18), 1e18);
        assertEq(OraclePriceMath.price(uint160(1 << 96), false, 1e18), 1e18);
    }

    function test_HighPrecisionBranch() public pure {
        assertEq(OraclePriceMath.price(uint160(1 << 130), true, 1), 1 << 68);
        assertApproxEqAbs(OraclePriceMath.price(uint160(1 << 130), false, 1e36), uint256(1e36) / (1 << 68), 1);
    }

    function testFuzz_FullV4PriceDomainDoesNotOverflow(int24 tick, uint8 exponent) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        exponent = uint8(bound(exponent, 0, 36));
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        OraclePriceMath.poolPrice(sqrtPrice, true, 10 ** uint256(exponent));
        OraclePriceMath.poolPrice(sqrtPrice, false, 10 ** uint256(exponent));
    }

    function testFuzz_ReciprocalPrices(int24 tick) public pure {
        tick = int24(bound(tick, -200_000, 200_000));
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        uint256 direct = OraclePriceMath.price(sqrtPrice, true, 1e18);
        uint256 inverse = OraclePriceMath.price(sqrtPrice, false, 1e18);
        assertApproxEqRel(direct * inverse, 1e36, 1e9);
    }

    function testFuzz_DecimalNormalization(uint8 assetDecimals, uint8 quoteDecimals) public pure {
        assetDecimals = uint8(bound(assetDecimals, 0, 18));
        quoteDecimals = uint8(bound(quoteDecimals, 0, 18));
        // At a raw-token ratio of one, the whole-token price follows the decimal scale.
        uint256 scale = 10 ** (18 + uint256(assetDecimals) - quoteDecimals);
        if (scale >= 1e6 && scale <= 1e30) {
            assertEq(OraclePriceMath.price(uint160(1 << 96), true, scale), scale);
            assertEq(OraclePriceMath.price(uint160(1 << 96), false, scale), scale);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { MockPriceOracle } from "./mocks/MockPriceOracle.sol";
import { OraclePriceMath } from "../src/libraries/OraclePriceMath.sol";

contract MockPriceOracleTest is Test {
    MockPriceOracle private oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new MockPriceOracle(address(this));
    }

    function test_OnlyPublisherCanUpdate() public {
        vm.prank(address(0x1234));
        vm.expectRevert(MockPriceOracle.Unauthorized.selector);
        oracle.publish(150e18, true, uint64(block.timestamp + 1 hours));
    }

    function test_InvalidPublisherRejected() public {
        vm.expectRevert(MockPriceOracle.Unauthorized.selector);
        new MockPriceOracle(address(0));
    }

    function test_PriceAndSessionBounds() public {
        vm.expectRevert(OraclePriceMath.PriceOutOfRange.selector);
        oracle.publish(0, true, uint64(block.timestamp + 1 hours));
        vm.expectRevert(MockPriceOracle.InvalidSession.selector);
        oracle.publish(150e18, true, uint64(block.timestamp));
        vm.expectRevert(MockPriceOracle.InvalidSession.selector);
        oracle.publish(150e18, true, uint64(block.timestamp + 1 days + 1));
        oracle.publish(150e18, true, uint64(block.timestamp + 1 days));
        assertEq(oracle.latestObservation().validUntil, block.timestamp + 1 days);
    }

    function test_CloseAndReopenPublishesFreshObservation() public {
        oracle.publish(150e18, false, uint64(block.timestamp + 1 hours));
        assertFalse(oracle.latestObservation().marketOpen);
        vm.warp(block.timestamp + 60);
        oracle.publish(151e18, true, uint64(block.timestamp + 1 hours));
        assertTrue(oracle.latestObservation().marketOpen);
        assertEq(oracle.latestObservation().updatedAt, block.timestamp);
        assertEq(oracle.latestObservation().price, 151e18);
    }
}

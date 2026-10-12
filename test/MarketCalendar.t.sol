// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { MarketCalendar } from "../src/oracle/MarketCalendar.sol";

contract MarketCalendarTest is Test {
    MarketCalendar private calendar;
    address private constant GUARDIAN = address(0x1234);
    uint64 private start;

    function setUp() public {
        vm.warp(20000 days);
        start = uint64(block.timestamp + 14 hours);
        calendar = new MarketCalendar(address(this), GUARDIAN);
    }

    function test_ExplicitWindowAndHalfOpenBoundary() public {
        _schedule(start, start + 6 hours);
        (,, bool open) = calendar.currentSession();
        assertFalse(open);
        vm.warp(start);
        (,, open) = calendar.currentSession();
        assertTrue(open);
        vm.warp(start + 6 hours);
        (,, open) = calendar.currentSession();
        assertFalse(open);
    }

    function test_ActiveSessionCannotBeRewritten() public {
        _schedule(start, start + 6 hours);
        vm.warp(start);
        vm.expectRevert(MarketCalendar.SessionAlreadyStarted.selector);
        _schedule(start + 1, start + 7 hours);
    }

    function test_GuardianCanPauseButCannotResumeOrSchedule() public {
        vm.prank(GUARDIAN);
        calendar.setPaused(true);
        vm.prank(GUARDIAN);
        vm.expectRevert(MarketCalendar.Unauthorized.selector);
        calendar.setPaused(false);
        vm.prank(GUARDIAN);
        vm.expectRevert(MarketCalendar.Unauthorized.selector);
        _schedule(start, start + 6 hours);
        calendar.setPaused(false);
        assertEq(calendar.resumeAfter(), block.timestamp);
    }

    function test_UnscheduledHolidayIsClosed() public {
        _schedule(start, start + 6 hours);
        vm.warp(start + 1 days);
        (,, bool open) = calendar.currentSession();
        assertFalse(open);
    }

    function test_InvalidWindowsRejected() public {
        vm.expectRevert(MarketCalendar.InvalidSession.selector);
        _schedule(start, start);
        vm.expectRevert(MarketCalendar.InvalidSession.selector);
        _schedule(start, start + 1 days);
    }

    function test_OwnershipRequiresAcceptance() public {
        address next = address(0x5678);
        calendar.transferOwnership(next);
        assertEq(calendar.owner(), address(this));
        vm.prank(next);
        calendar.acceptOwnership();
        assertEq(calendar.owner(), next);
        vm.expectRevert(MarketCalendar.Unauthorized.selector);
        _schedule(start, start + 6 hours);
    }

    function test_RevertWhen_UnknownAccountChangesCalendar() public {
        vm.startPrank(address(0xdead));
        vm.expectRevert(MarketCalendar.Unauthorized.selector);
        calendar.setPaused(true);
        vm.expectRevert(MarketCalendar.Unauthorized.selector);
        calendar.transferOwnership(address(0xbeef));
        vm.expectRevert(MarketCalendar.Unauthorized.selector);
        calendar.acceptOwnership();
        vm.stopPrank();
    }

    function test_RevertWhen_AuthorityIsZero() public {
        vm.expectRevert(MarketCalendar.InvalidOwner.selector);
        new MarketCalendar(address(0), GUARDIAN);
        vm.expectRevert(MarketCalendar.InvalidOwner.selector);
        new MarketCalendar(address(this), address(0));
        vm.expectRevert(MarketCalendar.InvalidOwner.selector);
        calendar.transferOwnership(address(0));
    }

    function test_RevertWhen_SessionBatchIsEmptyOrTooLarge() public {
        vm.expectRevert(MarketCalendar.InvalidSession.selector);
        calendar.schedule(new MarketCalendar.Session[](0));
        vm.expectRevert(MarketCalendar.InvalidSession.selector);
        calendar.schedule(new MarketCalendar.Session[](91));
    }

    function test_RevertWhen_SessionIsPastOrBeyondHorizon() public {
        vm.expectRevert(MarketCalendar.InvalidSession.selector);
        _schedule(uint64(block.timestamp - 1 hours), uint64(block.timestamp));
        vm.expectRevert(MarketCalendar.InvalidSession.selector);
        _schedule(start + 367 days, start + 367 days + 6 hours);
    }

    function test_FutureSessionCanBeCorrectedBeforeOpening() public {
        _schedule(start, start + 6 hours);
        _schedule(start + 1 hours, start + 4 hours);
        vm.warp(start);
        (,, bool open) = calendar.currentSession();
        assertFalse(open);
        vm.warp(start + 1 hours);
        (,, open) = calendar.currentSession();
        assertTrue(open);
    }

    function test_RepeatedResumeDoesNotResetPriceFreshnessFloor() public {
        calendar.setPaused(true);
        vm.warp(start);
        calendar.setPaused(false);
        vm.warp(start + 1);
        calendar.setPaused(false);
        assertEq(calendar.resumeAfter(), start);
    }

    function _schedule(uint64 opensAt, uint64 closesAt) private {
        MarketCalendar.Session[] memory windows = new MarketCalendar.Session[](1);
        windows[0] = MarketCalendar.Session(opensAt, closesAt);
        calendar.schedule(windows);
    }
}

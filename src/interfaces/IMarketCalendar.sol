// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Source of explicit trading windows and emergency pause state.
interface IMarketCalendar {
    /// @notice Returns the current UTC day's session and whether it permits trading now.
    /// @return opensAt Inclusive Unix opening timestamp, advanced to any later resumption time.
    /// @return closesAt Exclusive Unix closing timestamp; zero when no session is scheduled.
    /// @return isOpen True only within the window and while the calendar is not paused.
    function currentSession() external view returns (uint64 opensAt, uint64 closesAt, bool isOpen);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IMarketCalendar } from "../interfaces/IMarketCalendar.sol";

/// @notice Explicit UTC sessions for regular-hours equity trading. Unscheduled days are closed.
/// @dev Governance supplies exchange hours/holidays; the guardian may only pause. No implicit weekday rules.
contract MarketCalendar is IMarketCalendar {
    /// @notice One UTC-day trading window; opensAt is inclusive and closesAt is exclusive.
    struct Session {
        /// @notice Unix timestamp of the session opening.
        uint64 opensAt;
        /// @notice Unix timestamp of the session close, no later than the next UTC midnight.
        uint64 closesAt;
    }

    /// @notice Governance account that schedules sessions and can pause or resume trading.
    address public owner;
    /// @notice Nominated successor; has no authority until accepting ownership.
    address public pendingOwner;
    /// @notice Immutable emergency guardian; may pause but cannot resume or schedule.
    address public immutable guardian;
    /// @notice Whether all trading sessions are temporarily disabled.
    bool public paused;
    /// @notice Most recent resumption timestamp; older asset reports cannot reopen swaps.
    uint64 public resumeAfter;
    /// @notice Scheduled sessions keyed by floor(Unix timestamp / 86,400); missing days are closed.
    mapping(uint256 utcDay => Session) public sessions;

    /// @notice A UTC-day session was created or replaced before it began.
    /// @param utcDay Unix day index used as the session mapping key.
    /// @param opensAt Inclusive opening timestamp.
    /// @param closesAt Exclusive closing timestamp.
    event SessionScheduled(uint256 indexed utcDay, uint64 opensAt, uint64 closesAt);
    /// @notice Trading pause state changed; resumeAfter is the asset-report freshness floor.
    /// @param paused Whether all sessions are disabled.
    /// @param resumeAfter Latest resumption timestamp required of new asset reports.
    event PauseChanged(bool paused, uint64 resumeAfter);
    /// @notice A successor was nominated and must accept ownership.
    /// @param pendingOwner Nominated account; authority has not transferred yet.
    event OwnershipTransferStarted(address indexed pendingOwner);
    /// @notice A nominated successor accepted calendar ownership.
    /// @param owner Account that accepted ownership.
    event OwnershipTransferred(address indexed owner);

    /// @notice Caller lacks authority for the requested calendar operation.
    error Unauthorized();
    /// @notice The batch or a session violates length, timestamp or horizon limits.
    error InvalidSession();
    /// @notice An existing session cannot be replaced once its opening time has arrived.
    error SessionAlreadyStarted();
    /// @notice Owner, guardian or proposed successor is the zero address.
    error InvalidOwner();

    /// @notice Assigns calendar governance and the immutable pause-only guardian.
    /// @param owner_ Initial scheduling and resumption authority; cannot be zero.
    /// @param guardian_ Emergency pause authority; cannot be zero and may equal owner_.
    constructor(address owner_, address guardian_) {
        if (owner_ == address(0) || guardian_ == address(0)) revert InvalidOwner();
        owner = owner_;
        guardian = guardian_;
    }

    /// @notice Schedule up to 90 explicit sessions. Sessions cannot cross UTC midnight.
    /// @dev Owner only. An existing session cannot change after it starts. Windows must end in the
    ///      future and begin within 366 UTC days. Governance is trusted to supply verified exchange hours.
    /// @param windows Nonempty batch of at most 90 opening/closing pairs, in Unix seconds.
    function schedule(Session[] calldata windows) external {
        if (msg.sender != owner) revert Unauthorized();
        if (windows.length == 0 || windows.length > 90) revert InvalidSession();
        for (uint256 i; i < windows.length; ++i) {
            Session calldata window = windows[i];
            uint256 day = window.opensAt / 1 days;
            if (
                window.opensAt >= window.closesAt || (window.closesAt - 1) / 1 days != day
                    || window.closesAt <= block.timestamp || day > block.timestamp / 1 days + 366
            ) revert InvalidSession();
            Session memory existing = sessions[day];
            if (existing.closesAt != 0 && block.timestamp >= existing.opensAt) {
                revert SessionAlreadyStarted();
            }
            sessions[day] = window;
            emit SessionScheduled(day, window.opensAt, window.closesAt);
        }
    }

    /// @notice Guardian or owner can reject session observations; only the owner can restore availability.
    /// @dev Resumption requires an asset timestamp at or after this block in the oracle adapter.
    ///      Repeating the current pause state is a no-op and does not advance resumeAfter.
    /// @param value True to pause every session; false to resume subject to the current schedule.
    function setPaused(bool value) external {
        if (msg.sender != owner && (msg.sender != guardian || !value)) revert Unauthorized();
        if (paused == value) return;
        paused = value;
        if (!value) resumeAfter = uint64(block.timestamp);
        emit PauseChanged(value, resumeAfter);
    }

    /// @inheritdoc IMarketCalendar
    /// @dev An unscheduled day returns isOpen=false. opensAt also reflects a later resumption time.
    function currentSession() external view returns (uint64 opensAt, uint64 closesAt, bool isOpen) {
        Session memory window = sessions[block.timestamp / 1 days];
        opensAt = window.opensAt > resumeAfter ? window.opensAt : resumeAfter;
        closesAt = window.closesAt;
        isOpen = !paused && block.timestamp >= opensAt && block.timestamp < closesAt;
    }

    /// @notice Nominates a new owner without transferring authority immediately.
    /// @param nextOwner Nonzero account that must call acceptOwnership.
    function transferOwnership(address nextOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (nextOwner == address(0)) revert InvalidOwner();
        pendingOwner = nextOwner;
        emit OwnershipTransferStarted(nextOwner);
    }

    /// @notice Accepts the pending ownership transfer and clears the nomination.
    /// @dev Only the pending owner can call; the immutable guardian is unaffected.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(msg.sender);
    }
}

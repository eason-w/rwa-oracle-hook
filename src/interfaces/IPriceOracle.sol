// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RWA price oracle interface
/// @notice A whole-token asset price already denominated in the pool's quote currency.
/// @dev The adapter is responsible for quote FX, issuer conversion rules and report validity.
interface IPriceOracle {
    struct Observation {
        /// @notice Whole quote tokens per whole asset token, scaled by 1e18.
        uint256 price;
        /// @notice Unix timestamp of the oldest price input contributing to this observation.
        uint64 updatedAt;
        /// @notice Exclusive Unix expiry, bounded by price reports and any optional session policy.
        uint64 validUntil;
        /// @notice Whether this reference is eligible for oracle pricing; the hook defines fallback behavior.
        bool marketOpen;
    }

    /// @notice Returns a validated asset/quote observation or reverts when inputs are unavailable.
    /// @dev The hook additionally enforces its own timestamp, expiry and supported price-domain checks.
    /// @return observation Normalized price, input timestamp, exclusive expiry and session status.
    function latestObservation() external view returns (Observation memory observation);
}

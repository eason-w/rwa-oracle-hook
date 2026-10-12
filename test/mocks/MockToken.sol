// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";

/// @notice ERC20 test token with unrestricted minting.
contract MockToken is ERC20 {
    /// @notice Creates an unbacked ERC20 for local testing.
    /// @param name_ Display name.
    /// @param symbol_ Display ticker; does not identify a real issuer.
    /// @param decimals_ Whole-token decimal precision.
    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_, decimals_)
    { }

    /// @notice Mints arbitrary balances for test setup.
    /// @param to Recipient of the test tokens.
    /// @param amount Raw token units to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

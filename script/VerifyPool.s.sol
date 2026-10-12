// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { RwaOracleHook } from "../src/RwaOracleHook.sol";
import { ChainlinkOracle } from "../src/oracle/ChainlinkOracle.sol";

interface IERC20Metadata {
    /// @notice Whole-token decimal precision.
    function decimals() external view returns (uint8);
}

/// @notice Simulates integration checks against a configured deployment without broadcasting.
/// @dev Run with fresh feeds and seeded liquidity; an enabled calendar must also permit the session. Passing checks verifies
///      wiring and current quotes, not issuer correctness, router discovery, or future availability.
contract VerifyPool is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Checks chain, runtime hash, pool identity, oracle age configuration and both quote directions.
    /// @dev All expected addresses and the hook runtime hash must come from a reviewed deployment record.
    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "Wrong chain");
        RwaOracleHook hook = RwaOracleHook(vm.envAddress("RWA_HOOK"));
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        ChainlinkOracle oracle = ChainlinkOracle(vm.envAddress("PRICE_ORACLE"));
        IV4Quoter quoter = IV4Quoter(vm.envAddress("V4_QUOTER"));
        address asset = vm.envAddress("ASSET");
        address quote = vm.envAddress("QUOTE");
        require(address(hook).codehash == vm.envBytes32("HOOK_CODE_HASH"), "Hook bytecode mismatch");
        require(uint160(address(hook)) & 0x3fff == 0x2080, "Wrong hook permissions");
        require(address(manager).code.length > 0 && address(quoter).code.length > 0, "Missing infrastructure");
        require(address(hook.poolManager()) == address(manager), "Wrong PoolManager");
        require(address(quoter.poolManager()) == address(manager), "Wrong quoter manager");
        require(address(hook.oracle()) == address(oracle), "Wrong oracle");
        require(hook.asset() == asset && hook.quote() == quote, "Wrong tokens");
        require(hook.assetIsCurrency0() == (asset < quote), "Wrong token orientation");
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint8 quoteDecimals = IERC20Metadata(quote).decimals();
        require(assetDecimals <= 18 && quoteDecimals <= 18, "Unsupported token decimals");
        require(hook.priceScale() == 10 ** (18 + uint256(assetDecimals) - quoteDecimals), "Wrong price scale");
        require(
            hook.maxOracleAge() >= oracle.assetMaxAge() && hook.maxOracleAge() >= oracle.quoteMaxAge(),
            "Oracle age mismatch"
        );
        require(
            !vm.envBool("IS_L2") || address(oracle.sequencerFeed()) != address(0), "Missing sequencer feed"
        );
        if (!vm.envOr("ENFORCE_MARKET_HOURS", false)) {
            require(address(oracle.calendar()) == address(0), "Unexpected market-hours restriction");
        } else {
            require(address(oracle.calendar()) == vm.envAddress("MARKET_CALENDAR"), "Wrong calendar");
        }
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(asset < quote ? asset : quote),
            currency1: Currency.wrap(asset < quote ? quote : asset),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: hook.tickSpacing(),
            hooks: hook
        });
        require(PoolId.unwrap(key.toId()) == PoolId.unwrap(hook.poolId()), "Wrong pool identity");
        require(manager.getLiquidity(key.toId()) > 0, "No active liquidity");
        uint256 priceBefore = hook.getPoolPrice(key);
        hook.previewFee(key, true);
        hook.previewFee(key, false);
        _quote(quoter, key, asset < quote, vm.envUint("ASSET_PROBE_AMOUNT"));
        _quote(quoter, key, quote < asset, vm.envUint("QUOTE_PROBE_AMOUNT"));
        require(hook.getPoolPrice(key) == priceBefore, "Quoter changed pool state");
        console2.log("Pool identity, oracle and bidirectional quotes verified on chain", block.chainid);
        console2.log("Pool id:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    /// @dev Probe amounts are raw input-token units, selected small enough for the seeded pool.
    function _quote(IV4Quoter quoter, PoolKey memory key, bool zeroForOne, uint256 amount) private {
        require(amount > 0 && amount <= type(uint128).max, "Invalid probe amount");
        (uint256 output,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(amount), hookData: ""
            })
        );
        require(output > 0, "Empty quote");
    }
}

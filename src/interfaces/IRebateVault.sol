// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IRebateVault
/// @notice Accrues MEV auction proceeds and distributes them pro-rata to liquidity providers
interface IRebateVault {
    event RebateDeposited(PoolId indexed poolId, uint256 amount);
    event RebateClaimed(PoolId indexed poolId, address indexed lp, uint256 amount);
    event LiquidityTracked(PoolId indexed poolId, address indexed lp, uint256 newLiquidity);

    /// @notice Deposits auction proceeds to be distributed to the pool's LPs
    function depositRebate(PoolId poolId) external payable;

    /// @notice Records a change in an LP's tracked liquidity for a pool
    /// @param liquidityDelta Signed change in liquidity units
    function trackLiquidity(PoolId poolId, address lp, int256 liquidityDelta) external;

    /// @notice Rebate an LP can currently withdraw
    function pendingRebate(PoolId poolId, address lp) external view returns (uint256);

    /// @notice Withdraws all rebate accrued to the caller for a pool
    function claimRebate(PoolId poolId) external returns (uint256);
}

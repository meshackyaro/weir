// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title RebateVault
/// @notice Holds MEV auction proceeds and pays them out to a pool's liquidity providers
/// @dev Uses a reward-per-liquidity accumulator so payouts stay O(1) regardless of LP count.
///      Phase 1 tracks whole-position liquidity; tick-range weighting is a later refinement.
contract RebateVault is IRebateVault {
    /// @dev High precision keeps per-deposit rounding dust negligible against v4's uint128
    ///      liquidity values. Products stay bounded because an LP's share can never exceed the
    ///      pool total, so `liquidity * acc` is capped by `totalDeposited * PRECISION`.
    uint256 private constant PRECISION = 1e27;

    error Unauthorized();
    error InvalidAddress();
    error NothingToClaim();
    error TransferFailed();
    error LiquidityUnderflow();

    address public governance;

    /// @notice Contracts permitted to deposit proceeds and report liquidity changes
    mapping(address => bool) public authorized;

    /// @notice Accumulated rebate per unit of liquidity, scaled by PRECISION
    mapping(PoolId => uint256) public accRebatePerLiquidity;

    /// @notice Proceeds received while a pool had no tracked liquidity, held for the next deposit
    mapping(PoolId => uint256) public unallocated;

    mapping(PoolId => uint256) public totalLiquidity;
    mapping(PoolId => mapping(address => uint256)) public liquidityOf;

    /// @dev Accumulator value already accounted for in an LP's `owed` balance
    mapping(PoolId => mapping(address => uint256)) private _debt;
    mapping(PoolId => mapping(address => uint256)) private _owed;

    event AuthorizationChanged(address indexed account, bool allowed);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorized[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address _governance) {
        if (_governance == address(0)) revert InvalidAddress();
        governance = _governance;
    }

    function setAuthorized(address account, bool allowed) external onlyGovernance {
        if (account == address(0)) revert InvalidAddress();
        authorized[account] = allowed;
        emit AuthorizationChanged(account, allowed);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    /// @inheritdoc IRebateVault
    function depositRebate(PoolId poolId) external payable onlyAuthorized {
        uint256 amount = msg.value + unallocated[poolId];
        uint256 liquidity = totalLiquidity[poolId];

        if (liquidity == 0) {
            unallocated[poolId] = amount;
        } else {
            unallocated[poolId] = 0;
            accRebatePerLiquidity[poolId] += (amount * PRECISION) / liquidity;
        }

        emit RebateDeposited(poolId, msg.value);
    }

    /// @inheritdoc IRebateVault
    function trackLiquidity(PoolId poolId, address lp, int256 liquidityDelta) external onlyAuthorized {
        if (lp == address(0)) revert InvalidAddress();
        if (liquidityDelta == 0) return;

        _settle(poolId, lp);

        uint256 current = liquidityOf[poolId][lp];
        uint256 updated;

        if (liquidityDelta > 0) {
            updated = current + uint256(liquidityDelta);
            totalLiquidity[poolId] += uint256(liquidityDelta);
        } else {
            uint256 decrease = uint256(-liquidityDelta);
            if (decrease > current) revert LiquidityUnderflow();
            updated = current - decrease;
            totalLiquidity[poolId] -= decrease;
        }

        liquidityOf[poolId][lp] = updated;
        _debt[poolId][lp] = accRebatePerLiquidity[poolId];

        emit LiquidityTracked(poolId, lp, updated);
    }

    /// @inheritdoc IRebateVault
    function pendingRebate(PoolId poolId, address lp) public view returns (uint256) {
        uint256 accrued = (liquidityOf[poolId][lp] * (accRebatePerLiquidity[poolId] - _debt[poolId][lp])) / PRECISION;
        return _owed[poolId][lp] + accrued;
    }

    /// @inheritdoc IRebateVault
    function claimRebate(PoolId poolId) external returns (uint256 amount) {
        _settle(poolId, msg.sender);

        amount = _owed[poolId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        _owed[poolId][msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit RebateClaimed(poolId, msg.sender, amount);
    }

    function _settle(PoolId poolId, address lp) private {
        _owed[poolId][lp] = pendingRebate(poolId, lp);
        _debt[poolId][lp] = accRebatePerLiquidity[poolId];
    }
}

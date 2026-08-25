// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {WeirAuction} from "./WeirAuction.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title WeirHook
/// @notice Uniswap v4 hook that reserves the opening swap of each epoch for the auction winner
///         and routes LP liquidity accounting into the rebate vault.
contract WeirHook is IHooks {
    using PoolIdLibrary for PoolKey;

    error NotPoolManager();
    error Unauthorized();
    error InvalidAddress();
    error PriorityReserved();

    event PrioritySlotConsumed(PoolId indexed poolId, uint256 indexed epoch, address indexed winner);
    event PriorityWindowUpdated(uint256 blocks);
    event TrustedRouterUpdated(address indexed router, bool trusted);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    IPoolManager public immutable poolManager;
    WeirAuction public immutable auction;
    IRebateVault public immutable rebateVault;

    address public governance;

    /// @notice Blocks from an epoch's start during which only the winner may swap.
    /// @dev Bounds the damage if a winner never shows up: after this window the pool is open
    ///      to everyone, so a no-show costs the winner their bid rather than freezing the pool.
    uint256 public priorityWindowBlocks;

    /// @notice Tracks whether an epoch's reserved opening swap has already been taken
    mapping(PoolId => mapping(uint256 => bool)) public prioritySlotConsumed;

    /// @notice Routers whose `hookData` may name the liquidity provider a rebate belongs to
    /// @dev A router earns this only by isolating each caller's liquidity under its own position,
    ///      the way `WeirPositionRouter` does. Without that, one caller could name a beneficiary
    ///      on the way in and a different one on the way out.
    mapping(address => bool) public trustedRouter;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        WeirAuction _auction,
        IRebateVault _rebateVault,
        address _governance,
        uint256 _priorityWindowBlocks
    ) {
        if (
            address(_poolManager) == address(0) || address(_auction) == address(0)
                || address(_rebateVault) == address(0) || _governance == address(0)
        ) revert InvalidAddress();

        poolManager = _poolManager;
        auction = _auction;
        rebateVault = _rebateVault;
        governance = _governance;
        priorityWindowBlocks = _priorityWindowBlocks;
    }

    // ============ Governance ============

    function setPriorityWindow(uint256 blocks_) external onlyGovernance {
        priorityWindowBlocks = blocks_;
        emit PriorityWindowUpdated(blocks_);
    }

    function setTrustedRouter(address router, bool trusted) external onlyGovernance {
        if (router == address(0)) revert InvalidAddress();
        trustedRouter[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    // ============ Swap path ============

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint256 epoch = auction.currentEpoch(poolId);
        address winner = auction.winnerOf(poolId, epoch);

        if (winner != address(0) && !prioritySlotConsumed[poolId][epoch]) {
            if (block.number < auction.epochStartBlock(poolId, epoch) + priorityWindowBlocks) {
                // `sender` is the router rather than the trader, so the winner is matched
                // against either identity to keep routed swaps usable.
                if (sender != winner && tx.origin != winner) revert PriorityReserved();

                prioritySlotConsumed[poolId][epoch] = true;
                emit PrioritySlotConsumed(poolId, epoch, winner);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    // ============ Liquidity path ============

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        rebateVault.trackLiquidity(key.toId(), _beneficiary(sender, hookData), params.liquidityDelta);
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        rebateVault.trackLiquidity(key.toId(), _beneficiary(sender, hookData), params.liquidityDelta);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Who a liquidity change should earn rebates for
    /// @dev v4 reports the caller of `modifyLiquidity` as `sender`, which is a router rather than
    ///      the person who owns the position. A trusted router names that person in `hookData`;
    ///      anyone else is credited as themselves, so an untrusted caller can never redirect a
    ///      rebate or, worse, decrement a stranger's tracked liquidity.
    function _beneficiary(address sender, bytes calldata hookData) private view returns (address) {
        if (trustedRouter[sender] && hookData.length == 32) {
            address declared = abi.decode(hookData, (address));
            if (declared != address(0)) return declared;
        }
        return sender;
    }

    // ============ Unused callbacks ============

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}

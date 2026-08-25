// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {WeirHook} from "../src/WeirHook.sol";
import {WeirAuction} from "../src/WeirAuction.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice Exercises WeirHook against a real PoolManager, through the same routers a
///         production integrator would use.
contract WeirHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    WeirHook internal hook;
    WeirAuction internal auction;
    RebateVault internal vault;

    PoolId internal poolId;

    address internal winner = makeAddr("winner");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant EPOCH_BLOCKS = 10;
    uint256 internal constant PRIORITY_WINDOW = 3;
    uint256 internal constant RESERVE_PRICE = 0.01 ether;
    uint256 internal constant WINNING_BID = 0.1 ether;

    /// @dev These tests drive the pool through the generic v4 test router, which the hook does
    ///      not trust, so liquidity is credited to the router itself. Provider-level attribution
    ///      is covered in WeirPositionRouter.t.sol.
    address internal trackedLp;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new RebateVault(address(this));
        auction = new WeirAuction(address(this), IRebateVault(address(vault)));

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

        bytes memory args = abi.encode(manager, auction, IRebateVault(address(vault)), address(this), PRIORITY_WINDOW);
        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, type(WeirHook).creationCode, args);

        hook = new WeirHook{salt: salt}(manager, auction, IRebateVault(address(vault)), address(this), PRIORITY_WINDOW);
        require(address(hook) == hookAddress, "hook address mismatch");

        vault.setAuthorized(address(hook), true);
        vault.setAuthorized(address(auction), true);

        trackedLp = address(modifyLiquidityRouter);

        vm.roll(100);
        (key, poolId) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        auction.configurePool(poolId, EPOCH_BLOCKS, RESERVE_PRICE);

        vm.deal(winner, 10 ether);
        vm.deal(outsider, 10 ether);
    }

    // ============ Helpers ============

    /// @dev Places the winning bid and advances to the first block of the epoch it bought.
    function _winNextEpoch() internal returns (uint256 epoch) {
        epoch = auction.currentEpoch(poolId) + 1;

        vm.prank(winner);
        auction.bid{value: WINNING_BID}(poolId);

        vm.roll(auction.epochStartBlock(poolId, epoch));
    }

    /// @dev Swaps with `origin` as tx.origin while the test contract keeps paying, which is how
    ///      the hook distinguishes a routed swap's true initiator.
    function _swapAsOrigin(address origin) internal {
        vm.prank(address(this), origin);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _expectPriorityReserved() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(WeirHook.PriorityReserved.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    // ============ Permissions ============

    function test_hookAddressEncodesItsPermissions() public view {
        uint160 flags = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(
            flags, uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
        );
    }

    function test_onlyPoolManagerMayInvokeTheSwapHook() public {
        vm.expectRevert(WeirHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );
    }

    function test_onlyPoolManagerMayInvokeTheLiquidityHook() public {
        vm.expectRevert(WeirHook.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(this), key, LIQUIDITY_PARAMS, toBalanceDelta(0, 0), toBalanceDelta(0, 0), ZERO_BYTES
        );
    }

    // ============ Priority window ============

    function test_swapsAreOpenWhenNobodyBid() public {
        assertEq(auction.winnerOf(poolId, auction.currentEpoch(poolId)), address(0));
        _swapAsOrigin(outsider);
    }

    function test_outsiderIsBlockedInsidePriorityWindow() public {
        _winNextEpoch();

        _expectPriorityReserved();
        _swapAsOrigin(outsider);
    }

    function test_winnerMaySwapInsidePriorityWindow() public {
        uint256 epoch = _winNextEpoch();

        _swapAsOrigin(winner);

        assertTrue(hook.prioritySlotConsumed(poolId, epoch));
    }

    function test_poolReopensOnceWinnerHasTakenTheSlot() public {
        _winNextEpoch();

        _swapAsOrigin(winner);
        // Still inside the window, but the reserved slot is spent.
        _swapAsOrigin(outsider);
    }

    function test_poolReopensAfterPriorityWindowLapses() public {
        uint256 epoch = _winNextEpoch();

        vm.roll(auction.epochStartBlock(poolId, epoch) + PRIORITY_WINDOW);
        _swapAsOrigin(outsider);

        // A lapsed window is not a consumed slot; the winner simply never showed up.
        assertFalse(hook.prioritySlotConsumed(poolId, epoch));
    }

    function test_lastBlockOfPriorityWindowIsStillReserved() public {
        uint256 epoch = _winNextEpoch();

        vm.roll(auction.epochStartBlock(poolId, epoch) + PRIORITY_WINDOW - 1);

        _expectPriorityReserved();
        _swapAsOrigin(outsider);
    }

    function test_reservationDoesNotCarryIntoTheNextEpoch() public {
        uint256 epoch = _winNextEpoch();

        vm.roll(auction.epochStartBlock(poolId, epoch + 1));
        assertEq(auction.currentEpoch(poolId), epoch + 1);
        assertEq(auction.winnerOf(poolId, epoch + 1), address(0));

        _swapAsOrigin(outsider);
    }

    function test_winnerOfOneEpochHasNoClaimOnTheNext() public {
        uint256 epoch = _winNextEpoch();

        // The same bidder wins the following epoch too, so the reservation reappears.
        vm.prank(winner);
        auction.bid{value: WINNING_BID}(poolId);
        vm.roll(auction.epochStartBlock(poolId, epoch + 1));

        _expectPriorityReserved();
        _swapAsOrigin(outsider);
    }

    // ============ Liquidity accounting ============

    function test_liquidityIsTrackedOnAdd() public view {
        assertEq(vault.totalLiquidity(poolId), uint256(uint128(uint256(int256(LIQUIDITY_PARAMS.liquidityDelta)))));
        assertEq(vault.liquidityOf(poolId, trackedLp), vault.totalLiquidity(poolId));
    }

    function test_liquidityIsUntrackedOnRemove() public {
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(vault.totalLiquidity(poolId), 0);
        assertEq(vault.liquidityOf(poolId, trackedLp), 0);
    }

    // ============ End to end ============

    function test_auctionProceedsReachLiquidityProviders() public {
        uint256 epoch = _winNextEpoch();

        auction.settleEpoch(poolId, epoch);

        assertEq(address(vault).balance, WINNING_BID);
        assertEq(vault.pendingRebate(poolId, trackedLp), WINNING_BID);
    }

    /// @dev The fallback path: liquidity added through an untrusted router is credited to that
    ///      router, since v4 gives the hook no other identity to work with. `WeirPositionRouter`
    ///      is the supported way to be credited as yourself.
    function test_untrustedRouterIsCreditedAsItself() public {
        uint256 epoch = _winNextEpoch();
        auction.settleEpoch(poolId, epoch);

        assertEq(vault.pendingRebate(poolId, trackedLp), WINNING_BID);
        assertEq(vault.pendingRebate(poolId, address(this)), 0);
    }

    function test_losingBidderIsRefundedAfterSettlement() public {
        uint256 epoch = auction.currentEpoch(poolId) + 1;

        vm.prank(winner);
        auction.bid{value: WINNING_BID}(poolId);
        vm.prank(outsider);
        auction.bid{value: RESERVE_PRICE}(poolId);

        vm.roll(auction.epochStartBlock(poolId, epoch));
        auction.settleEpoch(poolId, epoch);

        uint256 before = outsider.balance;
        vm.prank(outsider);
        auction.claimRefund(poolId, epoch);

        assertEq(outsider.balance, before + RESERVE_PRICE);
        // Only the winning bid funds the rebate.
        assertEq(vault.pendingRebate(poolId, trackedLp), WINNING_BID);
    }
}

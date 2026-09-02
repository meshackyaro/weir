// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {CoFheTest} from "cofhe-mocks/CoFheTest.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {WeirHook} from "../src/WeirHook.sol";
import {WeirSealedAuction} from "../src/WeirSealedAuction.sol";
import {WeirPositionRouter} from "../src/WeirPositionRouter.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IWeirAuction} from "../src/interfaces/IWeirAuction.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice The whole of Weir end to end on sealed bids: a searcher wins a priority slot without
///         anyone learning what they paid until it is over, and the money lands with the LPs.
contract WeirSealedHookTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;

    WeirHook internal hook;
    WeirSealedAuction internal auction;
    WeirPositionRouter internal router;
    RebateVault internal vault;

    PoolId internal poolId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal searcher = makeAddr("searcher");
    address internal rival = makeAddr("rival");
    address internal outsider = makeAddr("outsider");

    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;
    int256 internal constant LIQUIDITY = 1e18;

    uint256 internal constant EPOCH_BLOCKS = 10;
    uint256 internal constant PRIORITY_WINDOW = 3;
    uint256 internal constant RESERVE_PRICE = 0.01 ether;
    uint256 internal constant CAP = 1 ether;

    uint128 internal constant WINNING_BID = 0.8 ether;
    uint128 internal constant LOSING_BID = 0.3 ether;

    uint256 internal constant GENESIS_BLOCK = 100;
    uint256 internal constant GENESIS_TIME = 1_700_000_000;
    uint256 internal constant SECONDS_PER_BLOCK = 12;

    /// @dev The epoch the searcher buys. Bids placed in epoch 0 compete for it.
    uint256 internal constant AUCTIONED_EPOCH = 2;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new RebateVault(address(this));
        auction = new WeirSealedAuction(address(this), IRebateVault(address(vault)));
        router = new WeirPositionRouter(manager);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        bytes memory args = abi.encode(
            manager, IWeirAuction(address(auction)), IRebateVault(address(vault)), address(this), PRIORITY_WINDOW
        );
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(WeirHook).creationCode, args);

        hook = new WeirHook{salt: salt}(
            manager, IWeirAuction(address(auction)), IRebateVault(address(vault)), address(this), PRIORITY_WINDOW
        );
        require(address(hook) == expected, "hook address mismatch");

        vault.setAuthorized(address(hook), true);
        vault.setAuthorized(address(auction), true);
        hook.setTrustedRouter(address(router), true);

        _rollTo(GENESIS_BLOCK);
        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        auction.configurePool(poolId, EPOCH_BLOCKS, RESERVE_PRICE);

        _fundProvider(alice);
        _fundProvider(bob);
        _fundSearcher(searcher);
        _fundSearcher(rival);
    }

    // ============ Helpers ============

    function _rollTo(uint256 blockNumber) internal {
        vm.roll(blockNumber);
        vm.warp(GENESIS_TIME + ((blockNumber - GENESIS_BLOCK) * SECONDS_PER_BLOCK));
    }

    function _fundProvider(address who) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, 1e24);
        MockERC20(Currency.unwrap(currency1)).transfer(who, 1e24);

        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _fundSearcher(address who) internal {
        vm.deal(who, 10 ether);
        vm.prank(who);
        auction.deposit{value: 5 ether}();
    }

    function _addLiquidity(address who, int256 amount) internal {
        vm.prank(who);
        router.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, amount, bytes32(0));
    }

    function _bid(address who, uint128 value) internal {
        InEuint128 memory sealedBid = createInEuint128(value, who);
        vm.prank(who);
        auction.bidSealed(poolId, CAP, sealedBid);
    }

    /// @dev What a keeper does between epochs: close the book, then read the answer back once the
    ///      coprocessor has produced it. Both happen a whole epoch before the slot is used.
    function _resolveAuction() internal {
        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH - 1));
        auction.closeBidding(poolId, AUCTIONED_EPOCH);
        _rollTo(block.number + 1);
        auction.settleEpoch(poolId, AUCTIONED_EPOCH);
    }

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

    // ============ End to end ============

    function test_sealedWinnerGetsThePrioritySlotAndLpsGetPaid() public {
        _addLiquidity(alice, LIQUIDITY);
        _addLiquidity(bob, LIQUIDITY * 3);

        _bid(searcher, WINNING_BID);
        _bid(rival, LOSING_BID);

        _resolveAuction();
        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH));

        _expectPriorityReserved();
        _swapAsOrigin(outsider);

        _swapAsOrigin(searcher);
        assertTrue(hook.prioritySlotConsumed(poolId, AUCTIONED_EPOCH));

        assertEq(address(vault).balance, WINNING_BID);
        assertEq(vault.pendingRebate(poolId, alice), WINNING_BID / 4);
        assertEq(vault.pendingRebate(poolId, bob), WINNING_BID * 3 / 4);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimRebate(poolId);
        assertEq(alice.balance, before + WINNING_BID / 4);
    }

    /// @dev The losing searcher pays nothing and, just as importantly, their bid never becomes
    ///      public — the only number the chain ever learns is the one that won.
    function test_theLosingBidIsNeverRevealedAndCostsNothing() public {
        _addLiquidity(alice, LIQUIDITY);

        _bid(searcher, WINNING_BID);
        _bid(rival, LOSING_BID);

        _resolveAuction();

        assertEq(auction.epochState(poolId, AUCTIONED_EPOCH).winningBid, WINNING_BID);

        vm.prank(rival);
        auction.releaseCollateral(poolId, AUCTIONED_EPOCH);
        assertEq(auction.collateral(rival), 5 ether);
        assertEq(auction.freeCollateral(rival), 5 ether);
    }

    /// @dev Nothing about the auction is decided while it is open, so the pool trades normally
    ///      for the two epochs a sealed bid has to wait out.
    function test_poolTradesOpenlyWhileTheAuctionIsStillSealed() public {
        _addLiquidity(alice, LIQUIDITY);
        _bid(searcher, WINNING_BID);

        assertEq(auction.winnerOf(poolId, auction.currentEpoch(poolId)), address(0));
        _swapAsOrigin(outsider);
    }

    /// @dev The failure mode that matters most: if the coprocessor is slow and settlement misses
    ///      the epoch, the slot is simply never reserved. A stalled auction must not stall a pool.
    function test_anUnsettledEpochLeavesThePoolOpen() public {
        _addLiquidity(alice, LIQUIDITY);
        _bid(searcher, WINNING_BID);

        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH - 1));
        auction.closeBidding(poolId, AUCTIONED_EPOCH);

        // Settlement never happens. The epoch arrives with no winner on record.
        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH));

        assertEq(auction.winnerOf(poolId, AUCTIONED_EPOCH), address(0));
        _swapAsOrigin(outsider);
    }

    /// @dev A late settlement still pays the LPs even though the priority slot went unused. The
    ///      searcher loses the slot, not their money's destination.
    function test_lateSettlementStillFundsTheRebate() public {
        _addLiquidity(alice, LIQUIDITY);
        _bid(searcher, WINNING_BID);

        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH - 1));
        auction.closeBidding(poolId, AUCTIONED_EPOCH);

        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH + 1));
        auction.settleEpoch(poolId, AUCTIONED_EPOCH);

        assertEq(vault.pendingRebate(poolId, alice), WINNING_BID);
    }

    function test_reservationExpiresWithTheEpoch() public {
        _addLiquidity(alice, LIQUIDITY);
        _bid(searcher, WINNING_BID);
        _resolveAuction();

        _rollTo(auction.epochStartBlock(poolId, AUCTIONED_EPOCH + 1));

        assertEq(auction.winnerOf(poolId, AUCTIONED_EPOCH + 1), address(0));
        _swapAsOrigin(outsider);
    }
}

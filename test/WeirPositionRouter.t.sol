// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {WeirHook} from "../src/WeirHook.sol";
import {WeirAuction} from "../src/WeirAuction.sol";
import {WeirPositionRouter} from "../src/WeirPositionRouter.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IWeirAuction} from "../src/interfaces/IWeirAuction.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice Proves that a rebate reaches the person who actually provided the liquidity, which is
///         only possible because the router names them and isolates their position.
contract WeirPositionRouterTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    WeirHook internal hook;
    WeirAuction internal auction;
    WeirPositionRouter internal router;
    RebateVault internal vault;

    PoolId internal poolId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal searcher = makeAddr("searcher");

    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;
    int256 internal constant LIQUIDITY = 1e18;

    uint256 internal constant EPOCH_BLOCKS = 10;
    uint256 internal constant PRIORITY_WINDOW = 3;
    uint256 internal constant WINNING_BID = 0.1 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new RebateVault(address(this));
        auction = new WeirAuction(address(this), IRebateVault(address(vault)));
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

        vm.roll(100);
        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        auction.configurePool(poolId, EPOCH_BLOCKS, 0.01 ether);

        _fund(alice);
        _fund(bob);
        vm.deal(searcher, 10 ether);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, 1e24);
        MockERC20(Currency.unwrap(currency1)).transfer(who, 1e24);

        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(address who, int256 amount) internal {
        vm.prank(who);
        router.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, amount, bytes32(0));
    }

    // ============ Attribution ============

    function test_liquidityIsCreditedToTheProviderNotTheRouter() public {
        _addLiquidity(alice, LIQUIDITY);

        assertEq(vault.liquidityOf(poolId, alice), uint256(LIQUIDITY));
        assertEq(vault.liquidityOf(poolId, address(router)), 0);
        assertEq(vault.totalLiquidity(poolId), uint256(LIQUIDITY));
    }

    function test_removingLiquidityDebitsTheSameProvider() public {
        _addLiquidity(alice, LIQUIDITY);
        _addLiquidity(alice, -LIQUIDITY);

        assertEq(vault.liquidityOf(poolId, alice), 0);
        assertEq(vault.totalLiquidity(poolId), 0);
    }

    function test_providersAreTrackedSeparately() public {
        _addLiquidity(alice, LIQUIDITY);
        _addLiquidity(bob, LIQUIDITY * 3);

        assertEq(vault.liquidityOf(poolId, alice), uint256(LIQUIDITY));
        assertEq(vault.liquidityOf(poolId, bob), uint256(LIQUIDITY * 3));
        assertEq(vault.totalLiquidity(poolId), uint256(LIQUIDITY * 4));
    }

    /// @dev The router owns every v4 position, so isolation has to come from the salt. Without it
    ///      one provider could withdraw another's liquidity.
    function test_oneProviderCannotWithdrawAnothers() public {
        _addLiquidity(alice, LIQUIDITY);

        // Bob's own position is empty, so the withdrawal underflows before it can touch Alice's.
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        _addLiquidity(bob, -LIQUIDITY);
    }

    function test_positionSaltIsDerivedFromTheCaller() public view {
        assertTrue(router.positionSalt(alice, bytes32(0)) != router.positionSalt(bob, bytes32(0)));
        assertTrue(router.positionSalt(alice, bytes32(0)) != router.positionSalt(alice, bytes32(uint256(1))));
    }

    function test_oneProviderCanHoldSeveralPositions() public {
        vm.startPrank(alice);
        router.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, LIQUIDITY, bytes32(0));
        router.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, LIQUIDITY, bytes32(uint256(1)));
        vm.stopPrank();

        assertEq(vault.liquidityOf(poolId, alice), uint256(LIQUIDITY * 2));
    }

    // ============ Trust boundary ============

    function test_untrustedCallerCannotNameABeneficiary() public {
        // The generic v4 router is not allowlisted, so its hookData is ignored and the credit
        // lands on the caller itself rather than on Alice.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQUIDITY,
                salt: 0
            }),
            abi.encode(alice)
        );

        assertEq(vault.liquidityOf(poolId, alice), 0);
        assertEq(vault.liquidityOf(poolId, address(modifyLiquidityRouter)), uint256(LIQUIDITY));
    }

    function test_revokingTrustFallsBackToCreditingTheRouter() public {
        hook.setTrustedRouter(address(router), false);

        _addLiquidity(alice, LIQUIDITY);

        assertEq(vault.liquidityOf(poolId, alice), 0);
        assertEq(vault.liquidityOf(poolId, address(router)), uint256(LIQUIDITY));
    }

    function test_onlyGovernanceSetsTrustedRouters() public {
        vm.prank(bob);
        vm.expectRevert(WeirHook.Unauthorized.selector);
        hook.setTrustedRouter(address(router), true);
    }

    function test_onlyPoolManagerMayInvokeTheUnlockCallback() public {
        vm.expectRevert(WeirPositionRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    // ============ End to end ============

    function test_searcherBidPaysOutToTheProvidersWhoEarnedIt() public {
        _addLiquidity(alice, LIQUIDITY);
        _addLiquidity(bob, LIQUIDITY * 3);

        uint256 epoch = auction.currentEpoch(poolId) + 1;
        vm.prank(searcher);
        auction.bid{value: WINNING_BID}(poolId);

        vm.roll(auction.epochStartBlock(poolId, epoch));
        auction.settleEpoch(poolId, epoch);

        assertEq(vault.pendingRebate(poolId, alice), WINNING_BID / 4);
        assertEq(vault.pendingRebate(poolId, bob), WINNING_BID * 3 / 4);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimRebate(poolId);

        assertEq(alice.balance, before + WINNING_BID / 4);
        assertEq(vault.pendingRebate(poolId, alice), 0);
    }

    function test_providerKeepsRebatesEarnedBeforeWithdrawing() public {
        _addLiquidity(alice, LIQUIDITY);

        uint256 epoch = auction.currentEpoch(poolId) + 1;
        vm.prank(searcher);
        auction.bid{value: WINNING_BID}(poolId);
        vm.roll(auction.epochStartBlock(poolId, epoch));
        auction.settleEpoch(poolId, epoch);

        _addLiquidity(alice, -LIQUIDITY);

        assertEq(vault.liquidityOf(poolId, alice), 0);
        assertEq(vault.pendingRebate(poolId, alice), WINNING_BID);
    }
}

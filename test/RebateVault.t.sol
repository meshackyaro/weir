// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {RebateVault} from "../src/RebateVault.sol";

contract RebateVaultTest is Test {
    RebateVault internal vault;

    address internal governance = address(0xA11CE);
    address internal auction = address(0xBEEF);
    address internal alice = address(0x1);
    address internal bob = address(0x2);

    PoolId internal poolId = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        vault = new RebateVault(governance);
        vm.prank(governance);
        vault.setAuthorized(auction, true);
        vm.deal(auction, 100 ether);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(auction);
        vault.depositRebate{value: amount}(poolId);
    }

    function _track(address lp, int256 delta) internal {
        vm.prank(auction);
        vault.trackLiquidity(poolId, lp, delta);
    }

    function test_splitsDepositProRata() public {
        _track(alice, 75);
        _track(bob, 25);

        _deposit(4 ether);

        assertEq(vault.pendingRebate(poolId, alice), 3 ether);
        assertEq(vault.pendingRebate(poolId, bob), 1 ether);
    }

    function test_claimTransfersAndZeroesBalance() public {
        _track(alice, 100);
        _deposit(1 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 claimed = vault.claimRebate(poolId);

        assertEq(claimed, 1 ether);
        assertEq(alice.balance - before, 1 ether);
        assertEq(vault.pendingRebate(poolId, alice), 0);
    }

    function test_lateLpDoesNotShareEarlierDeposit() public {
        _track(alice, 100);
        _deposit(1 ether);

        _track(bob, 100);
        _deposit(1 ether);

        assertEq(vault.pendingRebate(poolId, alice), 1.5 ether);
        assertEq(vault.pendingRebate(poolId, bob), 0.5 ether);
    }

    function test_depositWithNoLiquidityIsHeldForNextDeposit() public {
        _deposit(1 ether);
        assertEq(vault.unallocated(poolId), 1 ether);

        _track(alice, 100);
        _deposit(1 ether);

        assertEq(vault.unallocated(poolId), 0);
        assertEq(vault.pendingRebate(poolId, alice), 2 ether);
    }

    function test_withdrawingLiquidityKeepsAlreadyEarnedRebate() public {
        _track(alice, 100);
        _deposit(1 ether);

        _track(alice, -100);

        assertEq(vault.pendingRebate(poolId, alice), 1 ether);
        assertEq(vault.totalLiquidity(poolId), 0);
    }

    function test_onlyAuthorizedCanDeposit() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(RebateVault.Unauthorized.selector);
        vault.depositRebate{value: 1 ether}(poolId);
    }

    function test_onlyAuthorizedCanTrackLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(RebateVault.Unauthorized.selector);
        vault.trackLiquidity(poolId, alice, 100);
    }

    function test_claimWithNothingAccruedReverts() public {
        vm.prank(alice);
        vm.expectRevert(RebateVault.NothingToClaim.selector);
        vault.claimRebate(poolId);
    }

    function test_removingMoreLiquidityThanTrackedReverts() public {
        _track(alice, 50);
        vm.prank(auction);
        vm.expectRevert(RebateVault.LiquidityUnderflow.selector);
        vault.trackLiquidity(poolId, alice, -51);
    }

    /// @dev The solvency-critical property: rounding may strand dust, but the vault must never
    ///      promise more than it received, at any liquidity ratio.
    function testFuzz_neverDistributesMoreThanDeposited(uint128 aliceLiq, uint128 bobLiq, uint96 amount) public {
        aliceLiq = uint128(bound(aliceLiq, 1, type(uint128).max));
        bobLiq = uint128(bound(bobLiq, 1, type(uint128).max));
        amount = uint96(bound(amount, 1, 10 ether));

        _track(alice, int256(uint256(aliceLiq)));
        _track(bob, int256(uint256(bobLiq)));
        _deposit(amount);

        uint256 distributed = vault.pendingRebate(poolId, alice) + vault.pendingRebate(poolId, bob);
        assertLe(distributed, amount);
    }

    /// @dev At comparable LP sizes the rounding loss should be immaterial rather than merely bounded.
    function testFuzz_distributesNearlyAllAtComparableLpSizes(uint128 aliceLiq, uint128 bobLiq, uint96 amount) public {
        aliceLiq = uint128(bound(aliceLiq, 1e12, 1e24));
        bobLiq = uint128(bound(bobLiq, 1e12, 1e24));
        amount = uint96(bound(amount, 1e9, 10 ether));

        _track(alice, int256(uint256(aliceLiq)));
        _track(bob, int256(uint256(bobLiq)));
        _deposit(amount);

        uint256 distributed = vault.pendingRebate(poolId, alice) + vault.pendingRebate(poolId, bob);
        assertLe(distributed, amount);
        assertGe(distributed, amount - (amount / 1e6) - 2);
    }

    function test_lpTooSmallToEarnAWeiReceivesNothing() public {
        _track(alice, 1e30);
        _track(bob, 1);

        _deposit(1 ether);

        assertEq(vault.pendingRebate(poolId, bob), 0);
        assertLe(vault.pendingRebate(poolId, alice), 1 ether);
    }
}

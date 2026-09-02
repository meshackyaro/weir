// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {WeirAuction} from "../src/WeirAuction.sol";
import {WeirAuctionBase} from "../src/WeirAuctionBase.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

contract WeirAuctionTest is Test {
    RebateVault internal vault;
    WeirAuction internal auction;

    address internal governance = address(0xA11CE);
    address internal searcherA = address(0x1);
    address internal searcherB = address(0x2);
    address internal lp = address(0x3);

    PoolId internal poolId = PoolId.wrap(bytes32(uint256(1)));

    uint256 internal constant EPOCH_BLOCKS = 5;
    uint256 internal constant RESERVE = 0.01 ether;

    function setUp() public {
        vault = new RebateVault(governance);
        auction = new WeirAuction(governance, IRebateVault(address(vault)));

        vm.startPrank(governance);
        vault.setAuthorized(address(auction), true);
        vault.setAuthorized(governance, true);
        auction.configurePool(poolId, EPOCH_BLOCKS, RESERVE);
        vm.stopPrank();

        // Give the pool tracked liquidity so proceeds have somewhere to land.
        vm.prank(governance);
        vault.trackLiquidity(poolId, lp, 100);

        vm.deal(searcherA, 100 ether);
        vm.deal(searcherB, 100 ether);
    }

    function _advanceEpochs(uint256 n) internal {
        vm.roll(block.number + (n * EPOCH_BLOCKS));
    }

    function test_bidTargetsTheNextEpoch() public {
        uint256 epochNow = auction.currentEpoch(poolId);

        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);

        assertEq(auction.winnerOf(poolId, epochNow), address(0));
        assertEq(auction.winnerOf(poolId, epochNow + 1), searcherA);
    }

    function test_highestBidderLeads() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);
        vm.prank(searcherB);
        auction.bid{value: 2 ether}(poolId);

        assertEq(auction.winnerOf(poolId, auction.currentEpoch(poolId) + 1), searcherB);
    }

    function test_bidsAreCumulativePerBidder() public {
        vm.startPrank(searcherA);
        auction.bid{value: 1 ether}(poolId);
        auction.bid{value: 1 ether}(poolId);
        vm.stopPrank();

        vm.prank(searcherB);
        auction.bid{value: 1.5 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        assertEq(auction.bidOf(poolId, target, searcherA), 2 ether);
        assertEq(auction.winnerOf(poolId, target), searcherA);
    }

    function test_bidBelowReserveReverts() public {
        vm.prank(searcherA);
        vm.expectRevert(WeirAuction.BidBelowReserve.selector);
        auction.bid{value: RESERVE - 1}(poolId);
    }

    function test_settlementMovesWinningBidToVault() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);
        vm.prank(searcherB);
        auction.bid{value: 3 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        _advanceEpochs(1);

        auction.settleEpoch(poolId, target);

        assertEq(address(vault).balance, 3 ether);
        assertEq(vault.pendingRebate(poolId, lp), 3 ether);
    }

    function test_loserRefundsAfterSettlement() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);
        vm.prank(searcherB);
        auction.bid{value: 3 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        _advanceEpochs(1);
        auction.settleEpoch(poolId, target);

        uint256 before = searcherA.balance;
        vm.prank(searcherA);
        uint256 refunded = auction.claimRefund(poolId, target);

        assertEq(refunded, 1 ether);
        assertEq(searcherA.balance - before, 1 ether);
    }

    function test_winnerCannotRefund() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        _advanceEpochs(1);
        auction.settleEpoch(poolId, target);

        vm.prank(searcherA);
        vm.expectRevert(WeirAuction.WinnerCannotRefund.selector);
        auction.claimRefund(poolId, target);
    }

    function test_refundBeforeSettlementReverts() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        vm.prank(searcherA);
        vm.expectRevert(WeirAuction.EpochNotSettled.selector);
        auction.claimRefund(poolId, target);
    }

    function test_settlingUnstartedEpochReverts() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        vm.expectRevert(WeirAuctionBase.EpochNotStarted.selector);
        auction.settleEpoch(poolId, target);
    }

    function test_doubleSettlementReverts() public {
        vm.prank(searcherA);
        auction.bid{value: 1 ether}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        _advanceEpochs(1);
        auction.settleEpoch(poolId, target);

        vm.expectRevert(WeirAuction.EpochAlreadySettled.selector);
        auction.settleEpoch(poolId, target);
    }

    function test_epochWithNoBidsSettlesToNobody() public {
        uint256 target = auction.currentEpoch(poolId) + 1;
        _advanceEpochs(1);

        auction.settleEpoch(poolId, target);

        assertEq(auction.winnerOf(poolId, target), address(0));
        assertEq(address(vault).balance, 0);
    }

    function test_epochAdvancesWithBlocks() public {
        uint256 start = auction.currentEpoch(poolId);
        vm.roll(block.number + EPOCH_BLOCKS - 1);
        assertEq(auction.currentEpoch(poolId), start);

        vm.roll(block.number + 1);
        assertEq(auction.currentEpoch(poolId), start + 1);
    }

    function test_onlyGovernanceConfigures() public {
        vm.prank(searcherA);
        vm.expectRevert(WeirAuctionBase.Unauthorized.selector);
        auction.configurePool(poolId, 10, RESERVE);
    }

    function test_epochLengthCannotBeChangedAfterConfiguration() public {
        vm.prank(governance);
        vm.expectRevert(WeirAuctionBase.PoolAlreadyConfigured.selector);
        auction.configurePool(poolId, 10, RESERVE);
    }

    function test_reservePriceRemainsAdjustable() public {
        vm.prank(governance);
        auction.setReservePrice(poolId, 5 ether);

        vm.prank(searcherA);
        vm.expectRevert(WeirAuction.BidBelowReserve.selector);
        auction.bid{value: 1 ether}(poolId);
    }

    /// @dev Every settled epoch must leave exactly the winning bid in the vault and the rest refundable.
    function testFuzz_settlementIsSolvent(uint96 bidA, uint96 bidB) public {
        bidA = uint96(bound(bidA, RESERVE, 50 ether));
        bidB = uint96(bound(bidB, RESERVE, 50 ether));

        vm.prank(searcherA);
        auction.bid{value: bidA}(poolId);
        vm.prank(searcherB);
        auction.bid{value: bidB}(poolId);

        uint256 target = auction.currentEpoch(poolId) + 1;
        _advanceEpochs(1);
        auction.settleEpoch(poolId, target);

        uint256 winning = bidA >= bidB ? bidA : bidB;
        assertEq(address(vault).balance, winning);
        assertEq(address(auction).balance, uint256(bidA) + uint256(bidB) - winning);
    }
}

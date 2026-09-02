// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {WeirAuction} from "../src/WeirAuction.sol";
import {WeirAuctionBase} from "../src/WeirAuctionBase.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {FairPriceOracle} from "../src/FairPriceOracle.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IFairPriceOracle} from "../src/interfaces/IFairPriceOracle.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice Covers the Chainlink-backed reserve floor shared by both auctions.
/// @dev A reserve fixed in wei silently changes meaning every time ETH moves. These tests pin the
///      behaviour that stops it: a dollar figure that converts at the current price, a wei figure
///      underneath it that the oracle can raise but never lower, and a fallback that keeps bidding
///      open when the feed goes quiet.
contract WeirReserveTest is Test {
    WeirAuction internal auction;
    RebateVault internal vault;
    FairPriceOracle internal oracle;
    MockAggregatorV3 internal feed;

    PoolId internal poolId = PoolId.wrap(keccak256("weir/reserve-pool"));

    address internal searcher = makeAddr("searcher");

    uint256 internal constant EPOCH_BLOCKS = 10;
    uint256 internal constant WEI_FLOOR = 0.001 ether;
    uint256 internal constant STALE_AFTER = 1 hours;

    /// @dev Five dollars, to the 18 decimals the oracle normalises every feed to.
    uint256 internal constant FIVE_DOLLARS = 5e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(100);

        vault = new RebateVault(address(this));
        auction = new WeirAuction(address(this), IRebateVault(address(vault)));
        oracle = new FairPriceOracle(address(this));

        // Chainlink's ETH/USD feeds report eight decimals; $2,000 is 2000e8.
        feed = new MockAggregatorV3(8, 2000e8);
        oracle.registerFeed(poolId, IAggregatorV3(address(feed)), STALE_AFTER);

        vault.setAuthorized(address(auction), true);
        auction.configurePool(poolId, EPOCH_BLOCKS, WEI_FLOOR);

        vm.deal(searcher, 100 ether);
    }

    // ============ Without an oracle ============

    function test_theWeiFloorAppliesWhenNothingElseIsConfigured() public view {
        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    function test_aQuoteReserveDoesNothingUntilAnOracleIsSet() public {
        auction.setReserveQuote(poolId, FIVE_DOLLARS);
        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    function test_anOracleDoesNothingUntilAQuoteReserveIsSet() public {
        auction.setOracle(IFairPriceOracle(address(oracle)));
        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    // ============ With an oracle ============

    function test_theReserveIsConvertedAtTheCurrentPrice() public {
        _useOracle(FIVE_DOLLARS);

        // Five dollars of a two-thousand-dollar ETH.
        assertEq(auction.reservePrice(poolId), 0.0025 ether);
    }

    /// @dev The whole reason the oracle is here. The same dollar reserve costs twice the ETH when
    ///      ETH halves, instead of quietly becoming a ten-dollar reserve.
    function test_theReserveHoldsItsValueAsEthMoves() public {
        _useOracle(FIVE_DOLLARS);

        feed.setAnswer(1000e8);
        assertEq(auction.reservePrice(poolId), 0.005 ether);

        feed.setAnswer(4000e8);
        assertEq(auction.reservePrice(poolId), 0.00125 ether);
    }

    /// @dev The wei figure is a floor, not an alternative: the oracle can raise the bar and never
    ///      lower it, so a feed reporting an absurdly high ETH price cannot make bids nearly free.
    function test_theWeiFloorIsAHardMinimum() public {
        _useOracle(FIVE_DOLLARS);

        feed.setAnswer(1_000_000e8);

        // Five dollars is now worth far less than the floor, so the floor stands.
        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    // ============ Degraded feeds ============

    /// @dev Failing closed would stop bidding altogether, which costs LPs the very rebate the
    ///      reserve exists to protect. A quiet feed falls back rather than reverting.
    function test_aStaleFeedFallsBackToTheWeiFloor() public {
        _useOracle(FIVE_DOLLARS);
        assertEq(auction.reservePrice(poolId), 0.0025 ether);

        vm.warp(block.timestamp + STALE_AFTER + 1);

        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    function test_aNegativeAnswerFallsBackToTheWeiFloor() public {
        _useOracle(FIVE_DOLLARS);

        feed.setAnswer(-1);

        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    function test_aPoolWithNoFeedFallsBackToTheWeiFloor() public {
        PoolId unfed = PoolId.wrap(keccak256("weir/unfed-pool"));
        auction.configurePool(unfed, EPOCH_BLOCKS, WEI_FLOOR);

        auction.setOracle(IFairPriceOracle(address(oracle)));
        auction.setReserveQuote(unfed, FIVE_DOLLARS);

        assertEq(auction.reservePrice(unfed), WEI_FLOOR);
    }

    function test_biddingKeepsWorkingThroughAFeedOutage() public {
        _useOracle(FIVE_DOLLARS);
        vm.warp(block.timestamp + STALE_AFTER + 1);

        vm.prank(searcher);
        auction.bid{value: WEI_FLOOR}(poolId);

        assertEq(auction.winnerOf(poolId, auction.currentEpoch(poolId) + 1), searcher);
    }

    // ============ Effect on bidding ============

    function test_aBidUnderTheConvertedReserveIsRejected() public {
        _useOracle(FIVE_DOLLARS);

        vm.prank(searcher);
        vm.expectRevert(WeirAuction.BidBelowReserve.selector);
        auction.bid{value: 0.0024 ether}(poolId);
    }

    function test_aBidAtTheConvertedReserveIsAccepted() public {
        _useOracle(FIVE_DOLLARS);

        vm.prank(searcher);
        auction.bid{value: 0.0025 ether}(poolId);

        assertEq(auction.winnerOf(poolId, auction.currentEpoch(poolId) + 1), searcher);
    }

    /// @dev A bid that cleared the reserve when it was placed stays in the running. Re-judging it
    ///      against a later price would let a feed move retroactively unseat a leader.
    function test_aPriceMoveDoesNotUnseatABidAlreadyPlaced() public {
        _useOracle(FIVE_DOLLARS);

        vm.prank(searcher);
        auction.bid{value: 0.0025 ether}(poolId);

        feed.setAnswer(100e8); // five dollars is now 0.05 ETH, far above what was bid

        assertEq(auction.winnerOf(poolId, auction.currentEpoch(poolId) + 1), searcher);
    }

    // ============ Governance ============

    function test_onlyGovernanceSetsTheOracle() public {
        vm.prank(searcher);
        vm.expectRevert(WeirAuctionBase.Unauthorized.selector);
        auction.setOracle(IFairPriceOracle(address(oracle)));
    }

    function test_onlyGovernanceSetsTheQuoteReserve() public {
        vm.prank(searcher);
        vm.expectRevert(WeirAuctionBase.Unauthorized.selector);
        auction.setReserveQuote(poolId, FIVE_DOLLARS);
    }

    function test_theOracleCanBeUnset() public {
        _useOracle(FIVE_DOLLARS);
        assertEq(auction.reservePrice(poolId), 0.0025 ether);

        auction.setOracle(IFairPriceOracle(address(0)));

        assertEq(auction.reservePrice(poolId), WEI_FLOOR);
    }

    // ============ Helpers ============

    function _useOracle(uint256 quote) internal {
        auction.setOracle(IFairPriceOracle(address(oracle)));
        auction.setReserveQuote(poolId, quote);
    }
}

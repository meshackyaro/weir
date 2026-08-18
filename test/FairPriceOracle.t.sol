// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {FairPriceOracle} from "../src/FairPriceOracle.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";

contract FairPriceOracleTest is Test {
    FairPriceOracle internal oracle;
    MockAggregatorV3 internal feed;

    address internal governance = address(0xA11CE);
    address internal stranger = address(0x1);

    PoolId internal poolId = PoolId.wrap(bytes32(uint256(1)));

    uint256 internal constant STALE_AFTER = 1 hours;

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new FairPriceOracle(governance);
        feed = new MockAggregatorV3(8, 2000e8);

        vm.prank(governance);
        oracle.registerFeed(poolId, IAggregatorV3(address(feed)), STALE_AFTER);
    }

    function test_normalisesFeedDecimalsTo18() public view {
        assertEq(oracle.fairPrice(poolId), 2000e18);
    }

    function test_eighteenDecimalFeedPassesThrough() public {
        MockAggregatorV3 wideFeed = new MockAggregatorV3(18, 1234e18);
        PoolId other = PoolId.wrap(bytes32(uint256(2)));

        vm.prank(governance);
        oracle.registerFeed(other, IAggregatorV3(address(wideFeed)), STALE_AFTER);

        assertEq(oracle.fairPrice(other), 1234e18);
    }

    function test_unregisteredPoolReverts() public {
        PoolId other = PoolId.wrap(bytes32(uint256(99)));
        assertFalse(oracle.hasFeed(other));

        vm.expectRevert(FairPriceOracle.NoFeed.selector);
        oracle.fairPrice(other);
    }

    function test_stalePriceReverts() public {
        vm.warp(block.timestamp + STALE_AFTER + 1);

        vm.expectRevert(FairPriceOracle.StalePrice.selector);
        oracle.fairPrice(poolId);
    }

    function test_priceAtStalenessBoundaryIsAccepted() public {
        vm.warp(block.timestamp + STALE_AFTER);
        assertEq(oracle.fairPrice(poolId), 2000e18);
    }

    function test_nonPositiveAnswerReverts() public {
        feed.setAnswer(0);
        vm.expectRevert(FairPriceOracle.InvalidPrice.selector);
        oracle.fairPrice(poolId);

        feed.setAnswer(-1);
        vm.expectRevert(FairPriceOracle.InvalidPrice.selector);
        oracle.fairPrice(poolId);
    }

    function test_feedWithMoreThan18DecimalsIsRejected() public {
        MockAggregatorV3 oddFeed = new MockAggregatorV3(19, 1e19);
        PoolId other = PoolId.wrap(bytes32(uint256(3)));

        vm.prank(governance);
        vm.expectRevert(FairPriceOracle.UnsupportedDecimals.selector);
        oracle.registerFeed(other, IAggregatorV3(address(oddFeed)), STALE_AFTER);
    }

    function test_onlyGovernanceRegistersFeeds() public {
        vm.prank(stranger);
        vm.expectRevert(FairPriceOracle.Unauthorized.selector);
        oracle.registerFeed(poolId, IAggregatorV3(address(feed)), STALE_AFTER);
    }

    function test_toleranceAcceptsExecutionInsideBand() public view {
        // 1% band around 2000 accepts 1990 and 2010.
        assertTrue(oracle.isWithinTolerance(poolId, 1990e18, 100));
        assertTrue(oracle.isWithinTolerance(poolId, 2010e18, 100));
    }

    function test_toleranceRejectsExecutionOutsideBand() public view {
        assertFalse(oracle.isWithinTolerance(poolId, 1979e18, 100));
        assertFalse(oracle.isWithinTolerance(poolId, 2021e18, 100));
    }

    function testFuzz_toleranceIsSymmetric(uint96 deviation) public view {
        uint256 fair = 2000e18;
        deviation = uint96(bound(deviation, 0, 500e18));

        bool above = oracle.isWithinTolerance(poolId, fair + deviation, 100);
        bool below = oracle.isWithinTolerance(poolId, fair - deviation, 100);
        assertEq(above, below);
    }
}

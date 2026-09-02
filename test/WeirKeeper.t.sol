// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoFheTest} from "cofhe-mocks/CoFheTest.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {WeirKeeper} from "../src/WeirKeeper.sol";
import {WeirSealedAuction} from "../src/WeirSealedAuction.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice Exercises the Chainlink Automation upkeep that runs the sealed auction's clock.
/// @dev The property that matters is punctuality, not correctness of the auction itself: a winner
///      has to be decrypted and on record before the epoch they bought begins.
contract WeirKeeperTest is Test, CoFheTest {
    WeirKeeper internal keeper;
    WeirSealedAuction internal auction;
    RebateVault internal vault;

    PoolId internal poolId = PoolId.wrap(keccak256("weir/keeper-pool"));
    PoolId internal otherPool = PoolId.wrap(keccak256("weir/other-pool"));
    PoolId internal strangerPool = PoolId.wrap(keccak256("weir/unwatched-pool"));

    address internal searcher = makeAddr("searcher");
    address internal rival = makeAddr("rival");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant EPOCH_BLOCKS = 10;
    uint256 internal constant RESERVE_PRICE = 0.01 ether;
    uint256 internal constant CAP = 1 ether;
    uint128 internal constant BID = 0.5 ether;

    uint256 internal constant GENESIS_BLOCK = 100;
    uint256 internal constant GENESIS_TIME = 1_700_000_000;
    uint256 internal constant SECONDS_PER_BLOCK = 12;

    function setUp() public {
        _rollTo(GENESIS_BLOCK);

        vault = new RebateVault(address(this));
        auction = new WeirSealedAuction(address(this), IRebateVault(address(vault)));
        keeper = new WeirKeeper(auction, address(this));

        vault.setAuthorized(address(auction), true);

        auction.configurePool(poolId, EPOCH_BLOCKS, RESERVE_PRICE);
        auction.configurePool(otherPool, EPOCH_BLOCKS, RESERVE_PRICE);
        auction.configurePool(strangerPool, EPOCH_BLOCKS, RESERVE_PRICE);

        keeper.registerPool(poolId);

        _fund(searcher);
        _fund(rival);
    }

    // ============ Helpers ============

    function _rollTo(uint256 blockNumber) internal {
        vm.roll(blockNumber);
        vm.warp(GENESIS_TIME + ((blockNumber - GENESIS_BLOCK) * SECONDS_PER_BLOCK));
    }

    function _rollToEpoch(uint256 epoch) internal {
        _rollTo(auction.epochStartBlock(poolId, epoch));
    }

    function _fund(address who) internal {
        vm.deal(who, 10 ether);
        vm.prank(who);
        auction.deposit{value: 5 ether}();
    }

    function _bid(address who, PoolId pool, uint128 value) internal {
        InEuint128 memory sealedBid = createInEuint128(value, who);
        vm.prank(who);
        auction.bidSealed(pool, CAP, sealedBid);
    }

    /// @dev One tick of the Automation network: simulate, and send if there is anything to send.
    function _tick() internal returns (bool acted) {
        (bool needed, bytes memory performData) = keeper.checkUpkeep("");
        if (!needed) return false;
        keeper.performUpkeep(performData);
        return true;
    }

    // ============ The point of the contract ============

    /// @dev The deadline the keeper exists to meet. Left alone, a bidder would settle their own
    ///      epoch eventually — but eventually is after the slot they paid for has passed.
    function test_theWinnerIsOnRecordBeforeTheirEpochBegins() public {
        _bid(searcher, poolId, BID);
        _bid(rival, poolId, 0.2 ether);

        uint256 slotOpens = auction.epochStartBlock(poolId, 2);
        for (uint256 b = block.number; b < slotOpens; ++b) {
            _rollTo(b);
            _tick();
        }

        _rollTo(slotOpens);
        assertEq(auction.winnerOf(poolId, 2), searcher, "the slot opens with its winner known");
        assertEq(address(vault).balance, BID, "and the LPs already have the money");
    }

    // ============ Scheduling ============

    function test_thereIsNothingToDoOnAQuietPool() public view {
        (bool needed,) = keeper.checkUpkeep("");
        assertFalse(needed);

        (WeirKeeper.Action action,) = keeper.pendingWork(poolId);
        assertTrue(action == WeirKeeper.Action.None);
    }

    /// @dev A pool nobody bids on should never cost the upkeep a transaction, however long it runs.
    function test_anEpochNobodyBidOnIsLeftAlone() public {
        _rollToEpoch(1);
        assertFalse(_tick());

        _rollToEpoch(2);
        assertFalse(_tick());
    }

    function test_biddingIsClosedAtTheStartOfThePrecedingEpoch() public {
        _bid(searcher, poolId, BID);

        // Still epoch 0: closing epoch 2 is not legal yet.
        (WeirKeeper.Action tooEarly,) = keeper.pendingWork(poolId);
        assertTrue(tooEarly == WeirKeeper.Action.None);

        _rollToEpoch(1);

        (WeirKeeper.Action action, uint256 epoch) = keeper.pendingWork(poolId);
        assertTrue(action == WeirKeeper.Action.Close);
        assertEq(epoch, 2);

        assertTrue(_tick());
        assertTrue(auction.epochState(poolId, 2).closed);
    }

    function test_settlementFollowsOnceTheCoprocessorAnswers() public {
        _bid(searcher, poolId, BID);
        _rollToEpoch(1);
        _tick();

        // Same block as the decryption request: nothing is ready, so there is nothing to send.
        assertFalse(_tick());

        _rollTo(block.number + 1);

        (WeirKeeper.Action action, uint256 epoch) = keeper.pendingWork(poolId);
        assertTrue(action == WeirKeeper.Action.Settle);
        assertEq(epoch, 2);

        assertTrue(_tick());
        assertEq(auction.winnerOf(poolId, 2), searcher);
    }

    /// @dev A closed epoch is one whose winner is already owed a slot, and that deadline is the
    ///      one that expires. Bidding closes a whole epoch early and can afford to wait a block.
    function test_settlingOutranksClosing() public {
        _bid(searcher, poolId, BID);

        _rollToEpoch(1);
        _tick(); // closes epoch 2
        _bid(rival, poolId, 0.9 ether); // competes for epoch 3

        _rollToEpoch(2);

        // Epoch 3 is now closable and epoch 2 is settleable. Settling wins.
        assertTrue(auction.biddingClosable(poolId, 3));
        (WeirKeeper.Action action, uint256 epoch) = keeper.pendingWork(poolId);
        assertTrue(action == WeirKeeper.Action.Settle);
        assertEq(epoch, 2);
    }

    function test_aBacklogDrainsOneTransactionAtATime() public {
        _bid(searcher, poolId, BID);

        // The keeper is offline for two epochs, then catches up.
        _rollToEpoch(3);

        assertTrue(_tick(), "closes the epoch it missed");
        assertTrue(auction.epochState(poolId, 2).closed);

        _rollTo(block.number + 1);
        assertTrue(_tick(), "then settles it");
        assertEq(auction.winnerOf(poolId, 2), searcher);
        assertEq(address(vault).balance, BID, "the rebate is late but not lost");

        assertFalse(_tick());
    }

    /// @dev The lookback is deliberately bounded, so an outage long enough will strand an epoch.
    ///      That is survivable because the auction's own calls are permissionless — the bidder
    ///      whose collateral is locked has every reason to make them.
    function test_workOlderThanTheLookbackIsLeftToThePermissionlessPath() public {
        _bid(searcher, poolId, BID);

        _rollToEpoch(20);
        assertFalse(_tick(), "epoch 2 has fallen out of the keeper's window");

        auction.closeBidding(poolId, 2);
        _rollTo(block.number + 1);
        auction.settleEpoch(poolId, 2);

        assertEq(auction.winnerOf(poolId, 2), searcher);

        vm.prank(searcher);
        vm.expectRevert(WeirSealedAuction.NothingLocked.selector);
        auction.releaseCollateral(poolId, 2);
    }

    // ============ Registry ============

    function test_onlyGovernanceRegistersPools() public {
        vm.prank(stranger);
        vm.expectRevert(WeirKeeper.Unauthorized.selector);
        keeper.registerPool(otherPool);
    }

    function test_aPoolCannotBeRegisteredTwice() public {
        vm.expectRevert(WeirKeeper.PoolAlreadyRegistered.selector);
        keeper.registerPool(poolId);
    }

    function test_deregisteringLeavesTheOtherPoolsWatched() public {
        keeper.registerPool(otherPool);
        keeper.registerPool(strangerPool);

        keeper.deregisterPool(otherPool);

        PoolId[] memory watched = keeper.pools();
        assertEq(watched.length, 2);
        assertTrue(keeper.isRegistered(poolId));
        assertTrue(keeper.isRegistered(strangerPool));
        assertFalse(keeper.isRegistered(otherPool));
    }

    function test_aDeregisteredPoolIsNoLongerDriven() public {
        keeper.registerPool(otherPool);
        _bid(searcher, otherPool, BID);
        keeper.deregisterPool(otherPool);

        _rollToEpoch(1);

        assertFalse(_tick());
        assertFalse(auction.epochState(otherPool, 2).closed);
    }

    function test_theUpkeepWillNotWorkOnAPoolItDoesNotWatch() public {
        _bid(searcher, strangerPool, BID);
        _rollToEpoch(1);

        vm.expectRevert(WeirKeeper.PoolNotRegistered.selector);
        keeper.performUpkeep(abi.encode(WeirKeeper.Action.Close, strangerPool, uint256(2)));
    }

    function test_anEmptyInstructionIsRejected() public {
        vm.expectRevert(WeirKeeper.NothingToDo.selector);
        keeper.performUpkeep(abi.encode(WeirKeeper.Action.None, poolId, uint256(2)));
    }

    /// @dev Work that is not actually due is refused by the auction, not by the keeper. That is
    ///      the whole reason `performData` needs no trust.
    function test_instructionsThatAreNotDueAreRefusedByTheAuction() public {
        vm.expectRevert(WeirSealedAuction.BiddingStillOpen.selector);
        keeper.performUpkeep(abi.encode(WeirKeeper.Action.Close, poolId, uint256(2)));
    }

    // ============ Forwarder ============

    function test_anyoneMayDriveTheUpkeepUntilAForwarderIsSet() public {
        _bid(searcher, poolId, BID);
        _rollToEpoch(1);

        (, bytes memory performData) = keeper.checkUpkeep("");
        vm.prank(stranger);
        keeper.performUpkeep(performData);

        assertTrue(auction.epochState(poolId, 2).closed);
    }

    function test_theForwarderIsTheOnlyCallerOnceSet() public {
        address chainlinkForwarder = makeAddr("forwarder");
        keeper.setForwarder(chainlinkForwarder);

        _bid(searcher, poolId, BID);
        _rollToEpoch(1);
        (, bytes memory performData) = keeper.checkUpkeep("");

        vm.prank(stranger);
        vm.expectRevert(WeirKeeper.Unauthorized.selector);
        keeper.performUpkeep(performData);

        vm.prank(chainlinkForwarder);
        keeper.performUpkeep(performData);
        assertTrue(auction.epochState(poolId, 2).closed);
    }

    // ============ Several pools ============

    function test_pendingWorkIsFoundAcrossEveryWatchedPool() public {
        keeper.registerPool(otherPool);

        _bid(searcher, otherPool, BID);
        _rollToEpoch(1);

        (bool needed, bytes memory performData) = keeper.checkUpkeep("");
        assertTrue(needed);

        (, PoolId found,) = abi.decode(performData, (WeirKeeper.Action, PoolId, uint256));
        assertEq(PoolId.unwrap(found), PoolId.unwrap(otherPool));
    }
}

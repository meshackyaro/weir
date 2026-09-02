// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoFheTest} from "cofhe-mocks/CoFheTest.sol";
import {InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {WeirSealedAuction} from "../src/WeirSealedAuction.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice Exercises the CoFHE sealed-bid auction against Fhenix's mock coprocessor.
/// @dev The mock reproduces the property that makes this hard: a decryption request is answered
///      some seconds later, never in the requesting transaction. Every test here moves the clock
///      the way a real chain would rather than pretending the answer is immediate.
contract WeirSealedAuctionTest is Test, CoFheTest {
    WeirSealedAuction internal auction;
    RebateVault internal vault;

    PoolId internal poolId = PoolId.wrap(keccak256("weir/sealed-pool"));

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant EPOCH_BLOCKS = 10;
    uint256 internal constant RESERVE_PRICE = 0.01 ether;
    uint256 internal constant CAP = 1 ether;

    uint256 internal constant GENESIS_BLOCK = 100;
    uint256 internal constant GENESIS_TIME = 1_700_000_000;
    uint256 internal constant SECONDS_PER_BLOCK = 12;

    function setUp() public {
        _rollTo(GENESIS_BLOCK);

        vault = new RebateVault(address(this));
        auction = new WeirSealedAuction(address(this), IRebateVault(address(vault)));
        vault.setAuthorized(address(auction), true);

        auction.configurePool(poolId, EPOCH_BLOCKS, RESERVE_PRICE);

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    // ============ Helpers ============

    /// @dev Keeps block number and timestamp consistent, because CoFHE answers a decryption
    ///      request on a wall clock while the auction runs on a block clock.
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

    function _bid(address who, uint128 value, uint256 cap) internal {
        InEuint128 memory sealedBid = createInEuint128(value, who);
        vm.prank(who);
        auction.bidSealed(poolId, cap, sealedBid);
    }

    /// @dev Closes bidding for `epoch` at the start of the epoch before it, then settles once the
    ///      coprocessor has answered — the sequence a keeper would run every epoch.
    function _resolve(uint256 epoch) internal {
        _rollToEpoch(epoch - 1);
        auction.closeBidding(poolId, epoch);
        _rollTo(block.number + 1);
        auction.settleEpoch(poolId, epoch);
    }

    // ============ Epoch clock ============

    function test_biddingRunsTwoEpochsAhead() public view {
        assertEq(auction.currentEpoch(poolId), 0);
        assertEq(auction.biddingEpoch(poolId), 2);
    }

    function test_biddingCannotBeClosedWhileItIsStillOpen() public {
        // Epoch 2 is still taking bids for the whole of epoch 0.
        vm.expectRevert(WeirSealedAuction.BiddingStillOpen.selector);
        auction.closeBidding(poolId, 2);
    }

    function test_biddingClosesOneEpochBeforeTheAuctionedOne() public {
        _bid(alice, 0.5 ether, CAP);
        _rollToEpoch(1);

        auction.closeBidding(poolId, 2);

        assertTrue(auction.epochState(poolId, 2).closed);
    }

    function test_noFurtherBidsOnceBiddingHasClosed() public {
        _bid(alice, 0.5 ether, CAP);
        _rollToEpoch(1);
        auction.closeBidding(poolId, 2);

        // The lead time already means no honest bid can target a closed epoch, so the guard in
        // `bidSealed` is belt and braces. Reaching it takes rewinding the clock to when epoch 2
        // was still the bidding target.
        InEuint128 memory sealedBid = createInEuint128(0.9 ether, bob);
        _rollTo(auction.epochStartBlock(poolId, 0));
        vm.prank(bob);
        vm.expectRevert(WeirSealedAuction.BiddingClosed.selector);
        auction.bidSealed(poolId, CAP, sealedBid);
    }

    // ============ Sealing ============

    /// @dev The whole claim of the project in one assertion: what is on chain during bidding is a
    ///      ciphertext handle, and nothing derived from it names a winner or an amount.
    function test_nothingAboutABidIsReadableWhileTheAuctionIsOpen() public {
        _bid(alice, 0.5 ether, CAP);
        _bid(bob, 0.9 ether, CAP);

        WeirSealedAuction.EpochState memory state = auction.epochState(poolId, 2);

        assertTrue(euint128.unwrap(state.leadingBid) != 0, "a bid was recorded");
        assertEq(state.winner, address(0), "no winner is named before settlement");
        assertEq(state.winningBid, 0, "no amount is named before settlement");
        assertEq(auction.winnerOf(poolId, 2), address(0));
    }

    /// @dev Two searchers who commit the same collateral are indistinguishable on chain even
    ///      though they bid very different amounts. That is the anonymity set the cap buys.
    function test_equalCapsLookIdenticalRegardlessOfBid() public {
        _bid(alice, 0.02 ether, CAP);
        _bid(bob, 0.99 ether, CAP);

        assertEq(auction.lockOf(poolId, 2, alice), auction.lockOf(poolId, 2, bob));
    }

    function test_winnerIsUnknownUntilTheCoprocessorAnswers() public {
        _bid(alice, 0.5 ether, CAP);
        _rollToEpoch(1);
        auction.closeBidding(poolId, 2);

        // Same block as the request: CoFHE has not answered, so the pool has no winner yet.
        vm.expectRevert(WeirSealedAuction.DecryptionPending.selector);
        auction.settleEpoch(poolId, 2);
        assertEq(auction.winnerOf(poolId, 2), address(0));

        _rollTo(block.number + 1);
        auction.settleEpoch(poolId, 2);

        assertEq(auction.winnerOf(poolId, 2), alice);
    }

    // ============ Resolution ============

    function test_highestSealedBidWins() public {
        _bid(alice, 0.5 ether, CAP);
        _bid(bob, 0.9 ether, CAP);
        _bid(carol, 0.7 ether, CAP);

        _resolve(2);

        assertEq(auction.winnerOf(poolId, 2), bob);
        assertEq(auction.epochState(poolId, 2).winningBid, 0.9 ether);
    }

    function test_bidOrderDoesNotChangeTheWinner() public {
        _bid(bob, 0.9 ether, CAP);
        _bid(carol, 0.7 ether, CAP);
        _bid(alice, 0.5 ether, CAP);

        _resolve(2);

        assertEq(auction.winnerOf(poolId, 2), bob);
    }

    function test_bidsBelowTheReserveAreIgnored() public {
        _bid(alice, 0.001 ether, CAP);

        _resolve(2);

        assertEq(auction.winnerOf(poolId, 2), address(0));
        assertEq(auction.epochState(poolId, 2).winningBid, 0);
    }

    function test_aBidIsClampedToTheCollateralCommittedBehindIt() public {
        // Alice offers far more than she locked; the auction caps her at what she can pay.
        _bid(alice, 5 ether, 0.2 ether);
        _bid(bob, 0.3 ether, CAP);

        _resolve(2);

        assertEq(auction.winnerOf(poolId, 2), bob, "an unfunded bid cannot outbid a funded one");
        assertEq(auction.epochState(poolId, 2).winningBid, 0.3 ether);
    }

    function test_clampedBidStillWinsWhenItIsGenuinelyHighest() public {
        _bid(alice, 5 ether, 0.4 ether);
        _bid(bob, 0.3 ether, CAP);

        _resolve(2);

        assertEq(auction.winnerOf(poolId, 2), alice);
        assertEq(auction.epochState(poolId, 2).winningBid, 0.4 ether);
    }

    function test_anEpochNobodyBidOnSettlesWithNoWinner() public {
        _rollToEpoch(1);
        auction.closeBidding(poolId, 2);

        WeirSealedAuction.EpochState memory state = auction.epochState(poolId, 2);
        assertTrue(state.settled, "an empty epoch needs no decryption");
        assertEq(state.winner, address(0));
        assertEq(address(vault).balance, 0);
    }

    function test_settlementCannotHappenTwice() public {
        _bid(alice, 0.5 ether, CAP);
        _resolve(2);

        vm.expectRevert(WeirSealedAuction.EpochAlreadySettled.selector);
        auction.settleEpoch(poolId, 2);
    }

    function test_settlementNeedsBiddingToBeClosedFirst() public {
        _bid(alice, 0.5 ether, CAP);

        vm.expectRevert(WeirSealedAuction.EpochNotClosed.selector);
        auction.settleEpoch(poolId, 2);
    }

    // ============ Collateral ============

    function test_committedCollateralCannotBeWithdrawn() public {
        _bid(alice, 0.5 ether, CAP);

        assertEq(auction.freeCollateral(alice), 4 ether);

        vm.prank(alice);
        vm.expectRevert(WeirSealedAuction.InsufficientCollateral.selector);
        auction.withdraw(4 ether + 1);
    }

    function test_uncommittedCollateralIsWithdrawable() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        auction.withdraw(2 ether);

        assertEq(alice.balance, before + 2 ether);
        assertEq(auction.collateral(alice), 3 ether);
    }

    function test_aSearcherCannotBidMoreCollateralThanTheyHold() public {
        InEuint128 memory sealedBid = createInEuint128(0.5 ether, alice);
        vm.prank(alice);
        vm.expectRevert(WeirSealedAuction.InsufficientCollateral.selector);
        auction.bidSealed(poolId, 6 ether, sealedBid);
    }

    function test_oneSealedBidPerSearcherPerEpoch() public {
        _bid(alice, 0.5 ether, CAP);

        InEuint128 memory sealedBid = createInEuint128(0.9 ether, alice);
        vm.prank(alice);
        vm.expectRevert(WeirSealedAuction.AlreadyBid.selector);
        auction.bidSealed(poolId, CAP, sealedBid);
    }

    function test_theWinnerPaysTheirBidAndKeepsTheRestOfTheirCap() public {
        _bid(alice, 0.6 ether, CAP);

        _resolve(2);

        // A full ether was committed, 0.6 was owed; the balance is free again immediately.
        assertEq(auction.collateral(alice), 5 ether - 0.6 ether);
        assertEq(auction.lockedCollateral(alice), 0);
        assertEq(auction.freeCollateral(alice), 4.4 ether);
    }

    function test_losersGetTheirCollateralBackUntouched() public {
        _bid(alice, 0.6 ether, CAP);
        _bid(bob, 0.2 ether, CAP);

        _resolve(2);

        vm.prank(bob);
        uint256 released = auction.releaseCollateral(poolId, 2);

        assertEq(released, CAP);
        assertEq(auction.collateral(bob), 5 ether, "a losing bid costs nothing");
        assertEq(auction.freeCollateral(bob), 5 ether);
    }

    function test_collateralIsLockedUntilTheEpochSettles() public {
        _bid(alice, 0.6 ether, CAP);

        vm.prank(alice);
        vm.expectRevert(WeirSealedAuction.EpochNotSettled.selector);
        auction.releaseCollateral(poolId, 2);
    }

    function test_theWinnerHasNothingLeftToRelease() public {
        _bid(alice, 0.6 ether, CAP);
        _resolve(2);

        vm.prank(alice);
        vm.expectRevert(WeirSealedAuction.NothingLocked.selector);
        auction.releaseCollateral(poolId, 2);
    }

    // ============ Payout ============

    function test_theWinningBidFundsTheRebateVault() public {
        _bid(alice, 0.6 ether, CAP);
        _bid(bob, 0.2 ether, CAP);

        _resolve(2);

        assertEq(address(vault).balance, 0.6 ether, "only the winning bid is paid out");
    }

    function test_consecutiveEpochsResolveIndependently() public {
        _bid(alice, 0.6 ether, CAP);

        _rollToEpoch(1);
        // From epoch 1 a new bid competes for epoch 3.
        _bid(bob, 0.8 ether, CAP);

        auction.closeBidding(poolId, 2);
        _rollTo(block.number + 1);
        auction.settleEpoch(poolId, 2);

        _resolve(3);

        assertEq(auction.winnerOf(poolId, 2), alice);
        assertEq(auction.winnerOf(poolId, 3), bob);
        assertEq(address(vault).balance, 1.4 ether);
    }

    // ============ Governance ============

    function test_onlyGovernanceConfiguresAPool() public {
        vm.prank(alice);
        vm.expectRevert(WeirSealedAuction.Unauthorized.selector);
        auction.configurePool(PoolId.wrap(keccak256("other")), EPOCH_BLOCKS, RESERVE_PRICE);
    }

    function test_epochLengthIsFixedAtConfiguration() public {
        vm.expectRevert(WeirSealedAuction.PoolAlreadyConfigured.selector);
        auction.configurePool(poolId, 20, RESERVE_PRICE);
    }
}

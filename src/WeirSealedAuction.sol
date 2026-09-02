// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FHE, euint128, eaddress, ebool, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IWeirAuction} from "./interfaces/IWeirAuction.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title WeirSealedAuction
/// @notice Auctions per-epoch priority execution rights against bids nobody else can read.
///
/// @dev Bid values are Fhenix CoFHE ciphertexts. The running highest bid and the address holding
///      it are both kept encrypted, so a searcher watching the chain learns nothing about what
///      their rivals offered. Only the epoch's winning pair is ever decrypted; every losing bid
///      stays sealed forever.
///
///      Two consequences shape the whole contract:
///
///      1. **Money cannot ride along with the bid.** A `msg.value` that matches the bid would
///         publish it. So a searcher posts collateral up front, in whatever round number they
///         like, and later bids against it. What leaks is the cap they locked, not the bid.
///
///      2. **Decryption is asynchronous.** CoFHE settles a decryption request in a later block,
///         so a winner cannot be revealed in the same transaction that closes the bidding.
///         Bidding therefore runs two epochs ahead: bids for epoch `N + 2` are taken during
///         epoch `N`, which leaves the whole of epoch `N + 1` for the decryption to land.
contract WeirSealedAuction is IWeirAuction {
    error Unauthorized();
    error InvalidAddress();
    error InvalidEpochLength();
    error PoolAlreadyConfigured();
    error EpochNotStarted();
    error BiddingStillOpen();
    error BiddingClosed();
    error AlreadyBid();
    error EpochAlreadySettled();
    error EpochNotClosed();
    error EpochNotSettled();
    error DecryptionPending();
    error InsufficientCollateral();
    error NothingLocked();
    error ZeroAmount();
    error TransferFailed();

    /// @notice How far ahead of the executing epoch bids are taken.
    /// @dev Two, not one, because the winner has to be decrypted before their epoch begins.
    ///      Bidding for epoch `N + 2` closes when epoch `N + 1` starts, leaving that epoch's
    ///      worth of blocks for CoFHE to return the result.
    uint256 public constant BID_LEAD_EPOCHS = 2;

    struct EpochState {
        /// @dev Encrypted running maximum. A zero handle means nobody has bid yet.
        euint128 leadingBid;
        /// @dev Encrypted address currently holding that maximum.
        eaddress leader;
        /// @dev Set once decryption has been requested; no further bids are accepted.
        bool closed;
        /// @dev Set once the decrypted result has been read back and paid out.
        bool settled;
        /// @dev Plaintext result, only meaningful after `settled`.
        address winner;
        uint256 winningBid;
    }

    address public governance;
    IRebateVault public immutable rebateVault;

    /// @notice Block at which epoch 0 began for a pool
    mapping(PoolId => uint256) public startBlock;

    /// @notice Length of an auction epoch, in blocks
    mapping(PoolId => uint256) public epochBlocks;

    /// @notice Minimum bid accepted for a pool. Compared homomorphically, never revealed against.
    mapping(PoolId => uint256) public reservePrice;

    mapping(PoolId => mapping(uint256 => EpochState)) internal _epochs;

    /// @notice Total ETH a searcher has posted as bidding collateral
    mapping(address => uint256) public collateral;

    /// @notice Portion of that collateral currently committed to unsettled epochs
    mapping(address => uint256) public lockedCollateral;

    /// @notice Collateral a searcher committed to one epoch, and the ceiling on their bid there
    mapping(PoolId => mapping(uint256 => mapping(address => uint256))) public lockOf;

    event PoolConfigured(PoolId indexed poolId, uint256 epochBlocks, uint256 reservePrice);
    event ReservePriceUpdated(PoolId indexed poolId, uint256 reservePrice);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event CollateralDeposited(address indexed bidder, uint256 amount, uint256 total);
    event CollateralWithdrawn(address indexed bidder, uint256 amount, uint256 remaining);
    event CollateralReleased(PoolId indexed poolId, uint256 indexed epoch, address indexed bidder, uint256 amount);
    /// @dev Deliberately carries no value. That a bid happened is public; what it was is not.
    event SealedBidPlaced(PoolId indexed poolId, uint256 indexed epoch, address indexed bidder, uint256 collateralCap);
    event BiddingClosedForEpoch(PoolId indexed poolId, uint256 indexed epoch);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor(address _governance, IRebateVault _rebateVault) {
        if (_governance == address(0) || address(_rebateVault) == address(0)) revert InvalidAddress();
        governance = _governance;
        rebateVault = _rebateVault;
    }

    // ============ Governance ============

    /// @notice Opens auctions for a pool and anchors its epoch clock to the current block
    /// @dev Epoch length is fixed at configuration time; changing it later would renumber every
    ///      past epoch and orphan its settlement state.
    function configurePool(PoolId poolId, uint256 _epochBlocks, uint256 _reservePrice) external onlyGovernance {
        if (_epochBlocks == 0) revert InvalidEpochLength();
        if (startBlock[poolId] != 0) revert PoolAlreadyConfigured();

        startBlock[poolId] = block.number;
        epochBlocks[poolId] = _epochBlocks;
        reservePrice[poolId] = _reservePrice;

        emit PoolConfigured(poolId, _epochBlocks, _reservePrice);
    }

    function setReservePrice(PoolId poolId, uint256 _reservePrice) external onlyGovernance {
        reservePrice[poolId] = _reservePrice;
        emit ReservePriceUpdated(poolId, _reservePrice);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    // ============ Epoch clock ============

    /// @inheritdoc IWeirAuction
    function currentEpoch(PoolId poolId) public view returns (uint256) {
        uint256 start = startBlock[poolId];
        if (start == 0) return 0;
        return (block.number - start) / epochBlocks[poolId];
    }

    /// @inheritdoc IWeirAuction
    function epochStartBlock(PoolId poolId, uint256 epoch) public view returns (uint256) {
        return startBlock[poolId] + (epoch * epochBlocks[poolId]);
    }

    /// @notice The epoch a bid placed right now would compete for
    function biddingEpoch(PoolId poolId) public view returns (uint256) {
        return currentEpoch(poolId) + BID_LEAD_EPOCHS;
    }

    /// @inheritdoc IWeirAuction
    /// @dev Zero until the epoch is settled, so a decryption that arrives late leaves the pool
    ///      open to everyone rather than freezing it behind a winner nobody can name.
    function winnerOf(PoolId poolId, uint256 epoch) external view returns (address) {
        return _epochs[poolId][epoch].winner;
    }

    function epochState(PoolId poolId, uint256 epoch) external view returns (EpochState memory) {
        return _epochs[poolId][epoch];
    }

    /// @notice Whether anyone has bid on an epoch yet
    /// @dev A keeper uses this to leave quiet pools alone: closing an epoch nobody bid on costs
    ///      gas and changes nothing that matters.
    function hasBids(PoolId poolId, uint256 epoch) external view returns (bool) {
        return euint128.unwrap(_epochs[poolId][epoch].leadingBid) != 0;
    }

    /// @notice Whether `closeBidding` would be accepted for an epoch right now
    function biddingClosable(PoolId poolId, uint256 epoch) external view returns (bool) {
        if (startBlock[poolId] == 0 || epoch < BID_LEAD_EPOCHS) return false;
        if (currentEpoch(poolId) < epoch - BID_LEAD_EPOCHS + 1) return false;
        return !_epochs[poolId][epoch].closed;
    }

    /// @notice Whether the coprocessor has answered, so `settleEpoch` would succeed rather than
    ///         revert with `DecryptionPending`
    /// @dev Exists so a keeper can tell "not yet" from "something is wrong" without simulating a
    ///      transaction that is expected to revert most of the time.
    function settlementReady(PoolId poolId, uint256 epoch) external view returns (bool) {
        EpochState storage state = _epochs[poolId][epoch];
        if (!state.closed || state.settled) return false;

        (, bool bidReady) = FHE.getDecryptResultSafe(state.leadingBid);
        (, bool leaderReady) = FHE.getDecryptResultSafe(state.leader);
        return bidReady && leaderReady;
    }

    // ============ Collateral ============

    /// @notice Posts ETH a sealed bid can later be drawn against
    /// @dev Deposit round numbers. This balance is public, and it is the only quantity an
    ///      observer learns about your bidding power.
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        collateral[msg.sender] += msg.value;
        emit CollateralDeposited(msg.sender, msg.value, collateral[msg.sender]);
    }

    /// @notice Withdraws collateral that is not committed to an unsettled epoch
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > freeCollateral(msg.sender)) revert InsufficientCollateral();

        collateral[msg.sender] -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit CollateralWithdrawn(msg.sender, amount, collateral[msg.sender]);
    }

    function freeCollateral(address bidder) public view returns (uint256) {
        return collateral[bidder] - lockedCollateral[bidder];
    }

    /// @notice Frees collateral a losing bid had committed, once its epoch is settled
    /// @dev The winner's lock is released as part of settlement, so this is the losers' path.
    function releaseCollateral(PoolId poolId, uint256 epoch) external returns (uint256 amount) {
        if (!_epochs[poolId][epoch].settled) revert EpochNotSettled();

        amount = lockOf[poolId][epoch][msg.sender];
        if (amount == 0) revert NothingLocked();

        lockOf[poolId][epoch][msg.sender] = 0;
        lockedCollateral[msg.sender] -= amount;

        emit CollateralReleased(poolId, epoch, msg.sender, amount);
    }

    // ============ Bidding ============

    /// @notice Places a sealed bid for the epoch `BID_LEAD_EPOCHS` ahead of the one executing now
    /// @param collateralCap How much collateral to commit, and the ceiling the bid is clamped to
    /// @param sealedBid The bid value, encrypted client-side; never revealed unless it wins
    /// @dev One bid per searcher per epoch. Sealed-bid auctions are one-shot by construction, and
    ///      allowing top-ups would leak information through the pattern of follow-up transactions.
    function bidSealed(PoolId poolId, uint256 collateralCap, InEuint128 calldata sealedBid) external {
        if (startBlock[poolId] == 0) revert EpochNotStarted();
        if (collateralCap == 0) revert ZeroAmount();
        if (collateralCap > freeCollateral(msg.sender)) revert InsufficientCollateral();

        uint256 epoch = biddingEpoch(poolId);
        EpochState storage state = _epochs[poolId][epoch];
        if (state.closed) revert BiddingClosed();
        if (lockOf[poolId][epoch][msg.sender] != 0) revert AlreadyBid();

        lockOf[poolId][epoch][msg.sender] = collateralCap;
        lockedCollateral[msg.sender] += collateralCap;

        euint128 amount = FHE.asEuint128(sealedBid);

        // Clamping rather than rejecting keeps "bid everything I have" a single-transaction
        // strategy, and guarantees a winner can always cover what they owe.
        amount = FHE.min(amount, FHE.asEuint128(collateralCap));

        // A first bid needs something to be compared against, and a zero handle is not a
        // ciphertext. Seed the epoch with an encrypted zero bid held by the zero address, which
        // is also what an epoch where every bid missed the reserve decrypts to.
        if (euint128.unwrap(state.leadingBid) == 0) {
            state.leadingBid = FHE.asEuint128(uint256(0));
            state.leader = FHE.asEaddress(address(0));
        }

        ebool wins = FHE.and(FHE.gte(amount, FHE.asEuint128(reservePrice[poolId])), FHE.gt(amount, state.leadingBid));

        state.leadingBid = FHE.select(wins, amount, state.leadingBid);
        state.leader = FHE.select(wins, FHE.asEaddress(msg.sender), state.leader);

        // The contract has to keep operating on these handles in later transactions, and has to
        // be allowed to decrypt them once bidding closes.
        FHE.allowThis(state.leadingBid);
        FHE.allowThis(state.leader);

        // A searcher keeps the right to read back what they bid; nobody else gains it.
        FHE.allow(amount, msg.sender);

        emit SealedBidPlaced(poolId, epoch, msg.sender, collateralCap);
    }

    /// @notice Ends bidding for an epoch and asks CoFHE to decrypt the winning pair
    /// @dev Callable as soon as the epoch before the auctioned one begins. The result is not
    ///      available here — `settleEpoch` reads it back once the coprocessor has answered.
    function closeBidding(PoolId poolId, uint256 epoch) external {
        if (startBlock[poolId] == 0) revert EpochNotStarted();
        if (epoch < BID_LEAD_EPOCHS || currentEpoch(poolId) < epoch - BID_LEAD_EPOCHS + 1) revert BiddingStillOpen();

        EpochState storage state = _epochs[poolId][epoch];
        if (state.closed) revert BiddingClosed();
        state.closed = true;

        // Nothing was ever bid, so there is nothing to decrypt and nothing to pay out.
        if (euint128.unwrap(state.leadingBid) == 0) {
            state.settled = true;
            emit BiddingClosedForEpoch(poolId, epoch);
            emit EpochSettled(poolId, epoch, address(0), 0);
            return;
        }

        FHE.decrypt(state.leadingBid);
        FHE.decrypt(state.leader);

        emit BiddingClosedForEpoch(poolId, epoch);
    }

    /// @notice Reads the decrypted winner back and moves their bid into the rebate vault
    /// @dev Permissionless, and reverts with `DecryptionPending` until CoFHE has answered — so it
    ///      is safe to retry every block. Until it succeeds the epoch has no winner, which means
    ///      the pool trades openly rather than stalling.
    function settleEpoch(PoolId poolId, uint256 epoch) external {
        EpochState storage state = _epochs[poolId][epoch];
        if (!state.closed) revert EpochNotClosed();
        if (state.settled) revert EpochAlreadySettled();

        (uint128 amount, bool bidReady) = FHE.getDecryptResultSafe(state.leadingBid);
        (address leader, bool leaderReady) = FHE.getDecryptResultSafe(state.leader);
        if (!bidReady || !leaderReady) revert DecryptionPending();

        state.settled = true;

        if (amount > 0 && leader != address(0)) {
            state.winner = leader;
            state.winningBid = amount;

            // The winner's lock is spent here rather than through `releaseCollateral`: the bid is
            // deducted and whatever they over-collateralised goes straight back to their balance.
            uint256 lock = lockOf[poolId][epoch][leader];
            lockOf[poolId][epoch][leader] = 0;
            lockedCollateral[leader] -= lock;
            collateral[leader] -= amount;

            rebateVault.depositRebate{value: amount}(poolId);
        }

        emit EpochSettled(poolId, epoch, state.winner, state.winningBid);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IWeirAuction} from "./interfaces/IWeirAuction.sol";
import {IFairPriceOracle} from "./interfaces/IFairPriceOracle.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title WeirAuctionBase
/// @notice Everything the plaintext and sealed auctions agree on: who governs them, how an epoch
///         clock is anchored to a pool, and what the minimum acceptable bid is.
/// @dev Only the bidding itself differs between them — plaintext `msg.value` against CoFHE
///      ciphertexts — so the parts a pool operator configures live here and stay identical.
abstract contract WeirAuctionBase is IWeirAuction {
    error Unauthorized();
    error InvalidAddress();
    error InvalidEpochLength();
    error PoolAlreadyConfigured();
    error EpochNotStarted();
    error TransferFailed();

    /// @dev Fixed-point scale for oracle prices, which `FairPriceOracle` normalises to 18 decimals.
    uint256 internal constant PRICE_SCALE = 1e18;

    address public governance;
    IRebateVault public immutable rebateVault;

    /// @notice Reference price used to keep a reserve worth the same amount as ETH moves.
    /// @dev Optional. Unset, or without a feed for the pool, the reserve is whatever governance
    ///      last wrote in wei.
    IFairPriceOracle public oracle;

    /// @notice Block at which epoch 0 began for a pool
    mapping(PoolId => uint256) public startBlock;

    /// @notice Length of an auction epoch, in blocks
    mapping(PoolId => uint256) public epochBlocks;

    /// @notice Minimum bid in wei, regardless of what any feed says
    mapping(PoolId => uint256) public reserveFloorWei;

    /// @notice Minimum bid expressed in the pool feed's quote unit, to 18 decimals
    /// @dev Zero disables the oracle path. Weir prices bids in ETH, so the feed registered for a
    ///      pool must price ETH in that unit — for an ETH-paired pool, the same ETH/USD feed that
    ///      judges execution quality also keeps a dollar-denominated reserve honest.
    mapping(PoolId => uint256) public reserveQuote;

    event PoolConfigured(PoolId indexed poolId, uint256 epochBlocks, uint256 reservePrice);
    event ReservePriceUpdated(PoolId indexed poolId, uint256 reservePrice);
    event ReserveQuoteUpdated(PoolId indexed poolId, uint256 reserveQuote);
    event OracleUpdated(address indexed oracle);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

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
    /// @dev Epoch length is fixed at configuration time. Changing it later would renumber every
    ///      past epoch, orphaning their settlement state and refunds.
    function configurePool(PoolId poolId, uint256 _epochBlocks, uint256 _reservePrice) external onlyGovernance {
        if (_epochBlocks == 0) revert InvalidEpochLength();
        if (startBlock[poolId] != 0) revert PoolAlreadyConfigured();

        startBlock[poolId] = block.number;
        epochBlocks[poolId] = _epochBlocks;
        reserveFloorWei[poolId] = _reservePrice;

        emit PoolConfigured(poolId, _epochBlocks, _reservePrice);
    }

    function setReservePrice(PoolId poolId, uint256 _reservePrice) external onlyGovernance {
        reserveFloorWei[poolId] = _reservePrice;
        emit ReservePriceUpdated(poolId, _reservePrice);
    }

    /// @notice Sets a reserve that holds its value as ETH moves
    /// @param quote The floor in the feed's quote unit, to 18 decimals — 5e18 for five dollars
    function setReserveQuote(PoolId poolId, uint256 quote) external onlyGovernance {
        reserveQuote[poolId] = quote;
        emit ReserveQuoteUpdated(poolId, quote);
    }

    function setOracle(IFairPriceOracle _oracle) external onlyGovernance {
        oracle = _oracle;
        emit OracleUpdated(address(_oracle));
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    // ============ Epoch clock ============

    /// @inheritdoc IWeirAuction
    function currentEpoch(PoolId poolId) public view override returns (uint256) {
        uint256 start = startBlock[poolId];
        if (start == 0) return 0;
        return (block.number - start) / epochBlocks[poolId];
    }

    /// @inheritdoc IWeirAuction
    function epochStartBlock(PoolId poolId, uint256 epoch) public view override returns (uint256) {
        return startBlock[poolId] + (epoch * epochBlocks[poolId]);
    }

    // ============ Reserve ============

    /// @notice The minimum bid a pool will accept right now, in wei
    ///
    /// @dev A reserve fixed in wei drifts: set it at $5 when ETH is $2,000 and it is $10 when ETH
    ///      halves, quietly pricing searchers out and starving LPs of rebates. Where governance
    ///      has set a quote-denominated reserve and a feed exists, this converts it at the current
    ///      price and takes whichever floor is higher — so the wei figure stays a hard minimum and
    ///      the oracle can only raise the bar, never lower it.
    ///
    ///      A missing, zeroed or stale feed falls back to the wei floor rather than reverting.
    ///      Failing closed here would stop bidding altogether, which costs LPs the very rebate the
    ///      reserve exists to protect.
    function reservePrice(PoolId poolId) public view returns (uint256) {
        uint256 floorWei = reserveFloorWei[poolId];

        uint256 quote = reserveQuote[poolId];
        if (quote == 0 || address(oracle) == address(0)) return floorWei;

        try oracle.fairPrice(poolId) returns (uint256 ethPrice) {
            if (ethPrice == 0) return floorWei;
            uint256 converted = (quote * PRICE_SCALE) / ethPrice;
            return converted > floorWei ? converted : floorWei;
        } catch {
            return floorWei;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Ownable } from "solady/auth/Ownable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { TrackedAllowances, Allowance } from "./utils/TrackedAllowances.sol";
import { IAfCvx } from "./interfaces/afCvx/IAfCvx.sol";
import { ICleverCvxStrategy } from "./interfaces/afCvx/ICleverCvxStrategy.sol";
import { CVX } from "./interfaces/convex/Constants.sol";
import { CVX_REWARDS_POOL } from "./interfaces/convex/ICvxRewardsPool.sol";
import { Zap } from "./utils/Zap.sol";

// @audit - weekly withdraw limit be emptied by attacker --> implement a withdrawal fee / per account limit
contract AfCvx is IAfCvx, TrackedAllowances, Ownable, ERC4626Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    using SafeTransferLib for address;

    uint256 internal constant BASIS_POINT_SCALE = 10000;

    ICleverCvxStrategy public immutable cleverCvxStrategy;

    // @audit - replace uint16s with uint256s location so it packs better (16 * 4 + 160) - save 1 storage slot
    uint16 public protocolFeeBps;
    uint16 public withdrawalFeeBps;
    uint16 public cleverStrategyShareBps;
    uint16 public weeklyWithdrawShareBps;
    uint256 public weeklyWithdrawLimit;
    uint256 public withdrawLimitNextUpdate;
    address public protocolFeeCollector;
    address public operator;

    // @audit -- or, set vars as follow to save 2 storage slots
    // uint256 public weeklyWithdrawLimit;
    // uint16 public protocolFeeBps;
    // uint16 public withdrawalFeeBps;
    // uint16 public cleverStrategyShareBps;
    // uint16 public weeklyWithdrawShareBps;
    // address public protocolFeeCollector;
    // uint96 public withdrawLimitNextUpdate;
    // address public operator;

    // @audit - save gas with `if (msg.sender != owner() && msg.sender != operator) revert Unauthorized();`
    modifier onlyOperator() {
        if (msg.sender != owner()) {
            if (msg.sender != operator) revert Unauthorized();
        }
        _;
    }

    constructor(address strategy) {
        _disableInitializers();
        cleverCvxStrategy = ICleverCvxStrategy(strategy);
    }

    function initialize(address _owner, address _operator, address _feeCollector) external payable initializer {
        string memory name_ = "Asymmetry Finance afCVX";
        __ERC20_init(name_, "afCVX");
        __ERC4626_init(CVX);
        __ERC20Permit_init(name_);
        __UUPSUpgradeable_init();
        _initializeOwner(_owner);
        operator = _operator;
        protocolFeeCollector = _feeCollector;
        // 80% is deposited to Clever and 20% is staked on Convex
        cleverStrategyShareBps = 8000;

        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CVX_REWARDS_POOL), token: address(CVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(cleverCvxStrategy), token: address(CVX) }));
    }

    // @audit - limit only CRV_ETH_POOL Curve pool to be able to send ETH
    receive() external payable { }

    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return 18;
    }

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 unlocked, uint256 lockedInClever, uint256 staked) = getAvailableAssets();
        return unlocked + lockedInClever + staked;
    }

    function getAvailableAssets() public view returns (uint256 unlocked, uint256 lockedInClever, uint256 staked) {
        unlocked = CVX.balanceOf(address(this));
        lockedInClever = _cleverCvxStrategyAssets();
        staked = _stakedCvxStrategyAssets();
    }

    /// @notice distributes the deposited CVX between CLever Strategy and Convex Rewards Pool
    function distribute(bool swap, uint256 minAmountOut) external onlyOperator {
        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = previewDistribute();

        if (cleverDepositAmount == 0 && convexStakeAmount == 0) return;

        if (cleverDepositAmount > 0) {
            cleverCvxStrategy.deposit(cleverDepositAmount, swap, minAmountOut);
        }

        if (convexStakeAmount > 0) {
            CVX_REWARDS_POOL.stake(convexStakeAmount);
        }

        emit Distributed(cleverDepositAmount, convexStakeAmount); // @audit - should be called before external calls
    }

    function previewDistribute() public view returns (uint256 cleverDepositAmount, uint256 convexStakeAmount) {
        (uint256 unlocked, uint256 lockedInClever, uint256 staked) = getAvailableAssets();
        if (unlocked == 0) return (0, 0);

        uint256 totalLocked = lockedInClever + staked;
        uint256 targetLockedInClever = _mulBps(unlocked + totalLocked, cleverStrategyShareBps);
        if (targetLockedInClever >= lockedInClever) {
            uint256 delta;
            unchecked {
                delta = targetLockedInClever - lockedInClever;
            }
            cleverDepositAmount = delta > unlocked ? unlocked : delta;
        }

        if (unlocked > cleverDepositAmount) {
            unchecked {
                convexStakeAmount = unlocked - cleverDepositAmount;
            }
        }
    }

    // @audit - doesnt follow ERC4626 spec -- on actual withdraw call, less assets may be withdrawn than what is expected
    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (weeklyWithdrawLimit < assets) {
            assets = weeklyWithdrawLimit;
        }
        return super.previewWithdraw(assets);
    }

    // @audit - doesnt follow ERC4626 spec -- on actual redeem call, less shares may burn than what is expected
    function previewRedeem(uint256 shares)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        uint256 assets = super.previewRedeem(shares);
        if (weeklyWithdrawLimit < assets) {
            assets = weeklyWithdrawLimit;
        }
        return assets;
    }

    // @audit - may return unexpected results (less assets/shares withdrawn than expected)
    function previewRequestUnlock(uint256 assets) public view returns (uint256) {
        uint256 totalLocked = cleverCvxStrategy.totalLocked();
        return super.previewWithdraw(FixedPointMathLib.min(totalLocked, assets));
    }

    function requestUnlock(uint256 assets, address receiver, address owner) external returns (uint256 unlockEpoch) {
        uint256 shares = previewRequestUnlock(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        unlockEpoch = cleverCvxStrategy.requestUnlock(assets, receiver);
        emit UnlockRequested(receiver, assets, unlockEpoch);
    }

    function withdrawUnlocked(address receiver) external {
        uint256 cvxUnlocked = cleverCvxStrategy.withdrawUnlocked(receiver);
        if (cvxUnlocked != 0) {
            address(CVX).safeTransfer(receiver, cvxUnlocked);
            emit UnlockedWithdrawn(receiver, cvxUnlocked);
        }
    }

    /// @notice Harvest pending rewards from Convex and Furnace,
    ///         calculates maximum withdraw amount for the current epoch.
    /// @dev Should be called at the beginning of each epoch.
    ///      Keeps harvested rewards in the contract. Call `distribute` to redeposit rewards.
    function harvest(uint256 minAmountOut) external onlyOperator returns (uint256 rewards) {
        uint256 convexStakedRewards = CVX_REWARDS_POOL.earned(address(this));
        if (convexStakedRewards != 0) {
            CVX_REWARDS_POOL.getReward(false);
            convexStakedRewards = Zap.swapCvxCrvToCvx(convexStakedRewards, minAmountOut);
        }

        uint256 cleverRewards = cleverCvxStrategy.claim();
        rewards = convexStakedRewards + cleverRewards;

        if (rewards != 0) {
            uint256 fee = _mulBps(rewards, protocolFeeBps);
            rewards -= fee;
            address(CVX).safeTransfer(protocolFeeCollector, fee); // @audit this may fail because the `cleverRewards` are in Clever strategy contract
            emit Harvested(cleverRewards, convexStakedRewards);
        }

        updateWeeklyWithdrawLimit();
    }

    function updateWeeklyWithdrawLimit() public {
        if (block.timestamp < withdrawLimitNextUpdate) return;

        uint256 tvl = totalAssets();
        uint256 withdrawLimit = _mulBps(tvl, weeklyWithdrawShareBps);
        uint256 nextUpdate = block.timestamp + 7 days;
        weeklyWithdrawLimit = withdrawLimit;
        withdrawLimitNextUpdate = nextUpdate;

        emit WeeklyWithdrawLimitUpdated(withdrawLimit, nextUpdate);
    }

    /// @notice Sets the share of value that CLever CVX strategy should hold.
    /// @notice Target ratio is maintained by directing deposits and rewards into either CLever CVX strategy or staked CVX
    /// @param newShareBps New share of CLever CVX strategy (staked CVX share is automatically 100% - clevStrategyShareBps)
    function setCleverCvxStrategyShare(uint16 newShareBps) external onlyOwner {
        if (newShareBps > BASIS_POINT_SCALE) revert InvalidShare();
        cleverStrategyShareBps = newShareBps;
        emit CleverCvxStrategyShareSet(newShareBps);
    }

    /// @notice Sets the protocol fee which takes a percentage of the rewards
    /// @param newFeeBps New protocol fee
    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > BASIS_POINT_SCALE) revert InvalidFee();
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeSet(newFeeBps);
    }

    // @audit - is this used at all?
    /// @notice Sets the withdrawal fee.
    /// @param newFeeBps New withdrawal fee.
    function setWithdrawalFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > BASIS_POINT_SCALE) revert InvalidFee();
        withdrawalFeeBps = newFeeBps;
        emit WithdrawalFeeSet(newFeeBps);
    }

    /// @notice Sets the share of the protocol TVL that can be withdrawn in a week
    /// @param newShareBps New weekly withdraw share.
    function setWeeklyWithdrawShare(uint16 newShareBps) external onlyOwner {
        if (newShareBps > BASIS_POINT_SCALE) revert InvalidShare();
        weeklyWithdrawShareBps = newShareBps;
        emit WeeklyWithdrawShareSet(newShareBps);
    }

    /// @notice Sets the recipient of the protocol fee.
    /// @param newProtocolFeeCollector New protocol fee collector.
    function setProtocolFeeCollector(address newProtocolFeeCollector) external onlyOwner {
        if (newProtocolFeeCollector != address(0)) revert InvalidAddress();
        protocolFeeCollector = newProtocolFeeCollector;
        emit ProtocolFeeCollectorSet(newProtocolFeeCollector);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator != address(0)) revert InvalidAddress();
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    /// @dev Allows the owner of the contract to upgrade to *any* new address.
    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner { }

    function _stakedCvxStrategyAssets() private view returns (uint256) {
        uint256 staked = CVX_REWARDS_POOL.balanceOf(address(this));
        uint256 rewards = CVX_REWARDS_POOL.earned(address(this));
        if (rewards != 0) {
            // Staked CVX rewards are paid in cvxCRV, convert cvxCRV to CVX for calculations
            rewards = Zap.convertCvxCrvToCvx(rewards); // @audit - can be manipulated
            rewards -= _mulBps(rewards, protocolFeeBps);
        }
        return staked + rewards;
    }

    function _cleverCvxStrategyAssets() private view returns (uint256) {
        (uint256 deposited, uint256 rewards) = cleverCvxStrategy.totalValue();
        return deposited + (rewards == 0 ? 0 : (rewards - _mulBps(rewards, protocolFeeBps)));
    }

    // @audit - should probably have nonReentrant modifier
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (assets > weeklyWithdrawLimit) { // @audit - should be removed -- all accounting should be done in preview funcs
            assets = weeklyWithdrawLimit;
        }
        shares = previewWithdraw(assets); // @audit - should be removed -- all accounting should be done in preview funcs
        unchecked {
            weeklyWithdrawLimit = weeklyWithdrawLimit - assets;
        }

        CVX_REWARDS_POOL.withdraw(assets, false);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _mulBps(uint256 value, uint256 bps) private pure returns (uint256) {
        return value * bps / BASIS_POINT_SCALE;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Ownable } from "solady/auth/Ownable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { ICleverCvxStrategy } from "../interfaces/afCvx/ICleverCvxStrategy.sol";
import { TrackedAllowances, Allowance } from "../utils/TrackedAllowances.sol";
import { Zap } from "../utils/Zap.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "../interfaces/clever/ICLeverCvxLocker.sol";
import { FURNACE } from "../interfaces/clever/IFurnace.sol";
import { CVX } from "../interfaces/convex/Constants.sol";
import { CLEVCVX } from "../interfaces/clever/Constants.sol";

contract CleverCvxStrategy is ICleverCvxStrategy, TrackedAllowances, Ownable, UUPSUpgradeable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    /// @dev The denominator used for CLever fee calculation.
    uint256 private constant CLEVER_FEE_PRECISION = 1e9;
    uint256 private constant REWARDS_DURATION = 1 weeks;

    address public immutable manager;
    address public operator;

    /// @notice The total amount of CVX unlock obligations.
    uint256 internal unlockObligations;

    mapping(address => UnlockInfo) public requestedUnlocks;

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != owner()) {
            if (msg.sender != operator) revert Unauthorized();
        }
        _;
    }

    /// @dev As recommended by https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
    constructor(address afCvx) {
        _disableInitializers();
        manager = afCvx;
    }

    function initialize(address _owner, address _operator) external initializer {
        _initializeOwner(_owner);
        __UUPSUpgradeable_init();
        operator = _operator;

        // Approve once to save gas later by avoiding having to re-approve every time.
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(FURNACE), token: address(CLEVCVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CLEVER_CVX_LOCKER), token: address(CVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CLEVER_CVX_LOCKER), token: address(CLEVCVX) }));
    }

    function totalValue() external view returns (uint256 deposited, uint256 rewards) {
        (uint256 depositedClever,,, uint256 borrowedClever,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        (uint256 unrealisedFurnace, uint256 realisedFurnace) = FURNACE.getUserInfo(address(this));

        deposited = depositedClever - borrowedClever + unrealisedFurnace - unlockObligations;
        rewards = realisedFurnace;
    }

    function totalLocked() external view returns (uint256) {
        (uint256 deposited,,,,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return deposited;
    }

    function getRequestedUnlocks(address account) external view returns (UnlockRequest[] memory unlocks) {
        UnlockRequest[] storage accountUnlocks = requestedUnlocks[account].unlocks;
        uint256 nextUnlockIndex = requestedUnlocks[account].nextUnlockIndex;
        uint256 unlocksLength = accountUnlocks.length;
        unlocks = new UnlockRequest[](unlocksLength - nextUnlockIndex);
        for (uint256 i; nextUnlockIndex < unlocksLength; nextUnlockIndex++) {
            unlocks[i].unlockEpoch = accountUnlocks[nextUnlockIndex].unlockEpoch;
            unlocks[i].unlockAmount = accountUnlocks[nextUnlockIndex].unlockAmount;
            i++;
        }
    }

    /// @notice deposits CVX to the strategy
    /// @param cvxAmount amount of CVX tokens to deposit
    /// @param swap a flag indicating whether CVX should be swapped on Curve for clevCVX or deposited on Clever.
    /// @param minAmountOut minimum amount of clevCVX to receive after the swap. Only used if `swap` is true
    function deposit(uint256 cvxAmount, bool swap, uint256 minAmountOut) external onlyManager {
        address(CVX).safeTransferFrom(msg.sender, address(this), cvxAmount);
        if (swap) {
            uint256 clevCvxAmount = Zap.swapCvxToClevCvx(cvxAmount, minAmountOut);
            FURNACE.deposit(clevCvxAmount);
        } else {
            CLEVER_CVX_LOCKER.deposit(cvxAmount);
        }
    }

    /// @notice borrows maximum amount of clevCVX and deposits it to Furnace
    /// @dev must be called after `deposit` as Clever doesn't allow depositing and borrowing in the same block.
    function borrow() external onlyOperator {
        CLEVER_CVX_LOCKER.borrow(_calculateMaxBorrowAmount(), true);
    }

    /// @notice claims all realised CVX from Furnace
    /// @return rewards amount of realised CVX
    function claim() external onlyManager returns (uint256 rewards) {
        (, rewards) = FURNACE.getUserInfo(address(this));
        if (rewards > 0) {
            FURNACE.claim(manager);
        }
    }

    /// @notice requests to unlock CVX
    function requestUnlock(uint256 amount, address account) external onlyManager returns (uint256 unlockEpoch) {
        unlockObligations += amount;
        UnlockRequest[] storage unlocks = requestedUnlocks[account].unlocks;
        (EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));
        uint256 locksLength = locks.length;
        for (uint256 i; i < locksLength; i++) {
            uint256 locked = locks[i].pendingUnlock;
            uint64 epoch = locks[i].unlockEpoch;
            if (amount > locked) {
                unlocks.push(UnlockRequest({ unlockAmount: uint192(locked), unlockEpoch: epoch }));
                amount -= locked;
            } else {
                unlocks.push(UnlockRequest({ unlockAmount: uint192(amount), unlockEpoch: epoch }));
                unlockEpoch = epoch;
                break;
            }
        }
    }

    /// @notice withdraws unlocked CVX
    function withdrawUnlocked(address account) external onlyManager returns (uint256 cvxUnlocked) {
        uint256 currentEpoch = block.timestamp / REWARDS_DURATION;
        UnlockRequest[] storage unlocks = requestedUnlocks[account].unlocks;
        uint256 nextUnlockIndex = requestedUnlocks[account].nextUnlockIndex;
        uint256 unlocksLength = unlocks.length;

        for (; nextUnlockIndex < unlocksLength; nextUnlockIndex++) {
            uint256 unlockEpoch = unlocks[nextUnlockIndex].unlockEpoch;
            uint256 unlockAmount = unlocks[nextUnlockIndex].unlockAmount;
            if (unlockEpoch <= currentEpoch) {
                delete unlocks[nextUnlockIndex];
                cvxUnlocked += unlockAmount;
            } else {
                break;
            }
        }
        requestedUnlocks[account].nextUnlockIndex = nextUnlockIndex;

        if (cvxUnlocked == 0) return cvxUnlocked;

        uint256 cvxAvailable = CVX.balanceOf(address(this));

        if (cvxAvailable < cvxUnlocked) {
            (,, uint256 totalUnlocked,,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
            if (totalUnlocked > 0) {
                CLEVER_CVX_LOCKER.withdrawUnlocked();
            }
        }

        address(CVX).safeTransfer(manager, cvxUnlocked);
    }

    /// @notice withdraws clevCVX from Furnace and repays the dept to allow unlocking
    /// @dev must be called before `unlock` as Clever doesn't allow repaying and unlocking in the same block.
    function repay() external onlyOperator {
        uint256 amount = unlockObligations;
        if (amount != 0) {
            (uint256 repayAmount, uint256 repayFee) = _calculateRepayAmount(amount);
            (uint256 clevCvxAvailable,) = FURNACE.getUserInfo(address(this));
            uint256 clevCvxRequired = repayAmount + repayFee;

            if (clevCvxRequired > clevCvxAvailable) revert InsufficientFurnaceBalance();

            FURNACE.withdraw(address(this), repayAmount + repayFee);
            CLEVER_CVX_LOCKER.repay(0, repayAmount);
        }
    }

    /// @notice unlocks CVX to fulfill the withdrawal requests
    /// @dev must be called after `repay` as Clever doesn't allow repaying and unlocking in the same block.
    function unlock() external onlyOperator {
        uint256 amount = unlockObligations;
        if (amount != 0) {
            unlockObligations = 0;
            CLEVER_CVX_LOCKER.unlock(amount);
        }
    }

    /// @notice Pauses deposits and withdrawals.
    /// @dev Called in emergencies to stop all calls and transfers until further notice.
    function emergencyShutdown() external onlyManager {
        _emergencyRevokeAllAllowances();
        emit EmergencyShutdown();
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator != address(0)) revert InvalidAddress();
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    /// @dev Allows the owner of the contract to upgrade to *any* new address.
    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner { }

    function _calculateMaxBorrowAmount() private view returns (uint256) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        (uint256 totalDeposited,,, uint256 totalBorrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return totalDeposited.mulDiv(reserveRate, CLEVER_FEE_PRECISION) - totalBorrowed;
    }

    function _calculateRepayAmount(uint256 _lockedCVX) private view returns (uint256 repayAmount, uint256 repayFee) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        uint256 repayRate = CLEVER_CVX_LOCKER.repayFeePercentage();
        repayAmount = _lockedCVX.mulDivUp(reserveRate, CLEVER_FEE_PRECISION);
        repayFee = repayAmount.mulDivUp(repayRate, CLEVER_FEE_PRECISION);
    }
}

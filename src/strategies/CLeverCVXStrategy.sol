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
    bool public unlockInProgress;
    bool public paused;

    /// @notice The total amount of CVX unlock obligations.
    uint256 public unlockObligations;

    /// @notice The end date of the maintenance window when unlock requests are not allowed.
    ///         Maintenance window is a period between the last `unlock()` call and
    ///         the beginning of the next epoch.
    uint256 public maintenanceWindowEnd;

    mapping(address => UnlockInfo) public requestedUnlocks;

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    modifier onlyOperatorOrOwner() {
        if (msg.sender != operator) {
            if (msg.sender != owner()) revert Unauthorized();
        } else if (paused) {
            revert Paused();
        }
        _;
    }

    modifier unlockNotInProgress() {
        if (unlockInProgress) {
            revert UnlockInProgress();
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

        if (borrowedClever > 0) {
            // Take into account Clever repay fee
            uint256 repayRate = CLEVER_CVX_LOCKER.repayFeePercentage();
            borrowedClever += borrowedClever.mulDiv(repayRate, CLEVER_FEE_PRECISION);
        }
        deposited = depositedClever - borrowedClever + unrealisedFurnace;

        if (unlockObligations > deposited) {
            // This should not happen if repay()/unlock() is called at the end of every epoch
            uint256 delta;
            unchecked {
                delta = unlockObligations - deposited;
            }
            if (delta > realisedFurnace) {
                // Should not happen at all
                rewards = 0;
            } else {
                // Decrease the reported rewards value to keep the overall total value accurate
                unchecked {
                    rewards = realisedFurnace - delta;
                }
            }
            deposited = 0;
        } else {
            unchecked {
                deposited = deposited - unlockObligations;
            }
            rewards = realisedFurnace;
        }
    }

    function getRequestedUnlocks(address account) external view returns (UnlockRequest[] memory unlocks) {
        UnlockRequest[] memory accountUnlocks = requestedUnlocks[account].unlocks;
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
    function deposit(uint256 cvxAmount, bool swap, uint256 minAmountOut) external onlyManager unlockNotInProgress {
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
    function borrow() external onlyOperatorOrOwner {
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

    /// @notice Requests to unlock CVX
    /// @param amount The amount of CVX tokens to unlock
    /// @param account The address to receive CVX after the unlock period is over
    /// @return unlockEpoch The epoch number when all the requested CVX can be withdrawn
    function requestUnlock(uint256 amount, address account)
        external
        onlyManager
        unlockNotInProgress
        returns (uint256 unlockEpoch)
    {
        if (block.timestamp < maintenanceWindowEnd) revert MaintenanceWindow();
        // total unlock amount already requested
        uint256 existingUnlockObligations = unlockObligations;

        unlockObligations += amount;
        UnlockRequest[] storage unlocks = requestedUnlocks[account].unlocks;

        // retrieve an array of locked CVX and the epoch it can be unlocked starting from the next epoch
        // See https://github.com/AladdinDAO/aladdin-v3-contracts/blob/main/contracts/clever/CLeverCVXLocker.sol#L259
        // for implementation details
        (EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));

        uint256 locksLength = locks.length;
        for (uint256 i; i < locksLength; i++) {
            // amount that can be unlocked at the unlock epoch
            uint256 locked = locks[i].pendingUnlock;
            uint64 epoch = locks[i].unlockEpoch;

            if (existingUnlockObligations != 0) {
                // subtract previous unlock requests from the available amount
                if (existingUnlockObligations < locked) {
                    unchecked {
                        locked = locked - existingUnlockObligations;
                    }
                    existingUnlockObligations = 0;
                } else {
                    unchecked {
                        existingUnlockObligations = existingUnlockObligations - locked;
                    }
                    // move to the next epoch as all available amount was already requested
                    continue;
                }
            }

            if (amount > locked) {
                unlocks.push(UnlockRequest({ unlockAmount: uint192(locked), unlockEpoch: epoch }));
                unchecked {
                    amount = amount - locked;
                }
            } else {
                unlocks.push(UnlockRequest({ unlockAmount: uint192(amount), unlockEpoch: epoch }));
                return epoch;
            }
        }
        revert InvalidState();
    }

    /// @notice Withdraws CVX that became unlocked by the current epoch.
    ///         The unlock must be requested prior by calling `requestUnlock` function
    /// @param account The address to receive unlocked CVX
    /// @return cvxUnlocked The amount of unlocked CVX sent to `account`
    function withdrawUnlocked(address account) external onlyManager unlockNotInProgress returns (uint256 cvxUnlocked) {
        uint256 currentEpoch = block.timestamp / REWARDS_DURATION;
        UnlockRequest[] storage unlocks = requestedUnlocks[account].unlocks;
        uint256 nextUnlockIndex = requestedUnlocks[account].nextUnlockIndex;
        uint256 unlocksLength = unlocks.length;

        for (; nextUnlockIndex < unlocksLength; nextUnlockIndex++) {
            uint256 unlockEpoch = unlocks[nextUnlockIndex].unlockEpoch;
            if (unlockEpoch <= currentEpoch) {
                uint256 unlockAmount = unlocks[nextUnlockIndex].unlockAmount;
                delete unlocks[nextUnlockIndex];
                cvxUnlocked += unlockAmount;
            } else {
                break;
            }
        }

        // update the index of the next unlock since we don't resize the array to save gas
        requestedUnlocks[account].nextUnlockIndex = nextUnlockIndex;

        if (cvxUnlocked == 0) return cvxUnlocked;

        uint256 cvxAvailable = CVX.balanceOf(address(this));

        if (cvxAvailable < cvxUnlocked) {
            (,, uint256 totalUnlocked,,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
            if (totalUnlocked > 0) {
                // Unlocks all the requested CVX for the current epoch.
                // The remaining tokens (if any) are left in the contract
                // to be withdrawn by other users who requested unlock in the same epoch.
                CLEVER_CVX_LOCKER.withdrawUnlocked();
            }
        }

        address(CVX).safeTransfer(account, cvxUnlocked);
    }

    /// @notice withdraws clevCVX from Furnace and repays the dept to allow unlocking
    /// @dev must be called before `unlock` as Clever doesn't allow repaying and unlocking in the same block.
    function repay() external onlyOperatorOrOwner {
        unlockInProgress = true;
        uint256 amount = unlockObligations;
        if (amount != 0) {
            (uint256 repayAmount, uint256 repayFee) = _calculateRepayAmount(amount);
            if (repayAmount == 0) return;

            (uint256 clevCvxAvailable,) = FURNACE.getUserInfo(address(this));
            uint256 clevCvxRequired = repayAmount + repayFee;

            if (clevCvxRequired > clevCvxAvailable) revert InsufficientFurnaceBalance();

            FURNACE.withdraw(address(this), clevCvxRequired);
            CLEVER_CVX_LOCKER.repay(0, repayAmount);
        }
    }

    function maxTotalUnlock() external view returns (uint256 maxUnlock) {
        // get available clevCVX from Furnace
        (uint256 clevCvxAvailable,) = FURNACE.getUserInfo(address(this));

        // subtract repay fee
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        uint256 repayRate = CLEVER_CVX_LOCKER.repayFeePercentage();
        uint256 repayAmount = clevCvxAvailable.mulDiv(CLEVER_FEE_PRECISION, CLEVER_FEE_PRECISION + repayRate);

        (uint256 totalDeposited,,, uint256 totalBorrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));

        if (totalBorrowed > repayAmount) {
            // Decrease borrowed amount
            unchecked {
                totalBorrowed = totalBorrowed - repayAmount;
            }
            maxUnlock = totalDeposited - totalBorrowed.mulDiv(CLEVER_FEE_PRECISION, reserveRate);
        } else {
            // Amount of clevCVX in Furnace can be greater than the borrowed amount only if
            // CVX is swapped for clevCVX and deposited to Furnace, rather than locked in CleverLocker.
            maxUnlock = totalDeposited;
        }

        if (maxUnlock > unlockObligations) {
            unchecked {
                maxUnlock = maxUnlock - unlockObligations;
            }
        } else {
            maxUnlock = 0;
        }
    }

    /// @notice Unlocks CVX to fulfill the withdrawal requests. Must be called before the end of the epoch.
    /// @dev Must be called after `repay` as Clever doesn't allow repaying and unlocking in the same block.
    function unlock() external onlyOperatorOrOwner {
        uint256 amount = unlockObligations;
        if (amount != 0) {
            unlockObligations = 0;
            CLEVER_CVX_LOCKER.unlock(amount);
            // The start of the next epoch. Until then unlock requests are blocked.
            maintenanceWindowEnd = block.timestamp / REWARDS_DURATION * REWARDS_DURATION + REWARDS_DURATION;
        }
        unlockInProgress = false;
    }

    /// @notice Pauses deposits and withdrawals.
    /// @dev Called in emergencies to stop all calls and transfers until further notice.
    function emergencyShutdown() external onlyManager {
        paused = true;
        _emergencyRevokeAllAllowances();
        emit EmergencyShutdown();
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
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

    /// @notice Returns the minimum amount required to repay to fulfill requested `unlockAmount`.
    /// @dev Ensures that Clever health condition `totalDeposited * reserveRate >= totalBorrowed` is satisfied.
    function _calculateRepayAmount(uint256 unlockAmount) private view returns (uint256 repayAmount, uint256 repayFee) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        uint256 repayRate = CLEVER_CVX_LOCKER.repayFeePercentage();
        (uint256 totalDeposited,,, uint256 totalBorrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));

        if (totalDeposited < unlockAmount) return (0, 0);

        // reduce total deposit by requested unlock amount
        unchecked {
            totalDeposited = totalDeposited - unlockAmount;
        }

        uint256 maxBorrowAfterUnlock = totalDeposited.mulDiv(reserveRate, CLEVER_FEE_PRECISION);

        if (totalBorrowed > maxBorrowAfterUnlock) {
            unchecked {
                repayAmount = totalBorrowed - maxBorrowAfterUnlock;
            }
            repayFee = repayAmount.mulDiv(repayRate, CLEVER_FEE_PRECISION);
        }
    }
}

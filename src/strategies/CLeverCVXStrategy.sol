// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICLeverLocker} from "../interfaces/clever/ICLeverLocker.sol";
import {IFurnace} from "../interfaces/clever/IFurnace.sol";

import {TrackedAllowances} from "../utils/TrackedAllowances.sol";
import {Zap} from "../utils/Zap.sol";

contract CleverCvxStrategy is TrackedAllowances, Ownable, UUPSUpgradeable {

    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    struct UnlockRequest {
        uint192 unlockAmount;
        uint64 unlockEpoch;
    }

    struct UnlockInfo {
        UnlockRequest[] unlocks;
        uint256 nextUnlockIndex;
    }

    /// @dev The denominator used for CLever fee calculation.
    uint256 private constant CLEVER_FEE_PRECISION = 1e9;
    uint256 private constant REWARDS_DURATION = 1 weeks;

    address public immutable manager;
    address public operator;
    bool public unlockInProgress;

    /// @notice The total amount of CVX unlock obligations.
    uint256 public unlockObligations;

    mapping(address => UnlockInfo) public requestedUnlocks;
    bool public paused;

    /// @notice The end date of the maintenance window when unlock requests are not allowed.
    ///         Maintenance window is a period between the last `unlock()` call and
    ///         the beginning of the next epoch.
    uint256 public maintenanceWindowEnd;

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CVXCRV = IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    IFurnace private constant FURNACE = IFurnace(0xCe4dCc5028588377E279255c0335Effe2d7aB72a);
    ICLeverLocker private constant CLEVER_CVX_LOCKER = ICLeverLocker(0x96C68D861aDa016Ed98c30C810879F9df7c64154);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @dev As recommended by https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
    constructor(address afCvx) {
        _disableInitializers();
        manager = afCvx;
    }

    // ============================================================================================
    // Modifiers
    // ============================================================================================

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

    // ============================================================================================
    // View functions
    // ============================================================================================

    function netAssets() external view returns (uint256) {
        uint256 _unlockObligations = unlockObligations;
        (uint256 _deposited, , , uint256 _borrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        (uint256 _depositedInFurnace, ) = FURNACE.getUserInfo(address(this));
        if (_unlockObligations > _deposited + _depositedInFurnace - _borrowed) revert InvalidState(); // dev: sanity check

        return _deposited + _depositedInFurnace - _borrowed - unlockObligations;
    }

    function totalValue() external view returns (uint256 deposited, uint256 rewards, uint256 obligations) {
        (uint256 depositedClever,,, uint256 borrowedClever,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        uint256 unrealisedFurnace;
        (unrealisedFurnace, rewards) = FURNACE.getUserInfo(address(this));

        if (borrowedClever > 0) {
            // Take into account Clever repay fee
            uint256 repayRate = CLEVER_CVX_LOCKER.repayFeePercentage();
            borrowedClever += borrowedClever.mulDiv(repayRate, CLEVER_FEE_PRECISION);
        }

        deposited = depositedClever - borrowedClever + unrealisedFurnace;
        obligations = unlockObligations;
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

        uint256 _unlockObligations = unlockObligations;
        if (maxUnlock > _unlockObligations) {
            unchecked {
                maxUnlock = maxUnlock - _unlockObligations;
            }
        } else {
            maxUnlock = 0;
        }
    }

    // ============================================================================================
    // Manager functions
    // ============================================================================================

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
    function requestUnlock(uint256 amount, address account) external onlyManager unlockNotInProgress returns (uint256 unlockEpoch) {
        if (block.timestamp < maintenanceWindowEnd) revert MaintenanceWindow();
        // total unlock amount already requested
        uint256 existingUnlockObligations = unlockObligations;

        unlockObligations = existingUnlockObligations + amount;
        UnlockRequest[] storage unlocks = requestedUnlocks[account].unlocks;

        // retrieve an array of locked CVX and the epoch it can be unlocked starting from the next epoch
        // See https://github.com/AladdinDAO/aladdin-v3-contracts/blob/main/contracts/clever/CLeverCVXLocker.sol#L259
        // for implementation details
        (ICLeverLocker.EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));

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

    /// @notice Pauses deposits and withdrawals.
    /// @dev Called in emergencies to stop all calls and transfers until further notice.
    function emergencyShutdown() external onlyManager {
        paused = true;
        _emergencyRevokeAllAllowances();
        emit EmergencyShutdown();
    }

    // ============================================================================================
    // Operator functions
    // ============================================================================================

    /// @notice borrows maximum amount of clevCVX and deposits it to Furnace
    /// @dev must be called after `deposit` as Clever doesn't allow depositing and borrowing in the same block.
    function borrow() external onlyOperatorOrOwner {
        CLEVER_CVX_LOCKER.borrow(_calculateMaxBorrowAmount(), true);
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

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    function _calculateMaxBorrowAmount() private view returns (uint256) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        (uint256 totalDeposited,,, uint256 totalBorrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return totalDeposited.mulDiv(reserveRate, CLEVER_FEE_PRECISION) - totalBorrowed;
    }

    /// @dev Allows the owner of the contract to upgrade to *any* new address.
    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

    // ============================================================================================
    // Private view functions
    // ============================================================================================

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

    // ============================================================================================
    // Events
    // ============================================================================================

    event OperatorSet(address indexed newOperator);
    event EmergencyShutdown();

    // ============================================================================================
    // Errors
    // ============================================================================================

    error InvalidAddress();
    error InsufficientFurnaceBalance();
    error UnlockInProgress();
    error InvalidState();
    error MaintenanceWindow();
    error Paused();
}

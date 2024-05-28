// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLeverLocker} from "../interfaces/clever/ICLeverLocker.sol";
import {IFurnace} from "../interfaces/clever/IFurnace.sol";

import {TrackedAllowances} from "../utils/TrackedAllowances.sol";
import {Zap} from "../utils/Zap.sol";

contract CleverCvxStrategy is TrackedAllowances, Ownable, UUPSUpgradeable {

    using SafeERC20 for IERC20;

    struct UnlockRequest {
        uint192 unlockAmount;
        uint64 unlockEpoch;
    }

    struct UnlockInfo {
        UnlockRequest[] unlocks;
        uint256 nextUnlockIndex;
    }

    address public operator;
    bool public unlockInProgress;

    uint256 public unlockObligations;

    mapping(address => UnlockInfo) public requestedUnlocks;
    bool public paused;

    address public immutable manager;

    /// @notice The end date of the maintenance window when unlock requests are not allowed
    ///         Maintenance window is a period between the last `unlock()` call and the beginning of the next epoch
    uint256 public maintenanceWindowEnd;

    uint256 private constant CLEVER_PRECISION = 1e9;
    uint256 private constant REWARDS_DURATION = 1 weeks;

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CVXCRV = IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    IFurnace private constant FURNACE = IFurnace(0xCe4dCc5028588377E279255c0335Effe2d7aB72a);
    ICLeverLocker private constant CLEVER_CVX_LOCKER = ICLeverLocker(0x96C68D861aDa016Ed98c30C810879F9df7c64154);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(address _manager) {
        _disableInitializers();
        manager = _manager;
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

    function netAssets() public view returns (uint256) {
        uint256 _unlockObligations = unlockObligations;
        (uint256 _deposited, , , uint256 _borrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        (uint256 _depositedInFurnace, ) = FURNACE.getUserInfo(address(this));
        if (_unlockObligations > _deposited + _depositedInFurnace - _borrowed) revert InvalidState(); // dev: sanity check

        return _deposited + _depositedInFurnace - _borrowed - unlockObligations;
    }

    function repaymentFee(uint256 _assets) public view returns (uint256) {
        return _assets * CLEVER_CVX_LOCKER.repayFeePercentage() / CLEVER_PRECISION;
    }

    /// @notice Returns the net assets in the strategy minus a fee on the debt
    function maxTotalUnlock() external view returns (uint256) {
        (, , , uint256 _borrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return netAssets() - repaymentFee(_borrowed);
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

    // ============================================================================================
    // Manager functions
    // ============================================================================================

    /// @notice deposits CVX to the strategy
    /// @param cvxAmount amount of CVX tokens to deposit
    /// @param swap a flag indicating whether CVX should be swapped on Curve for clevCVX or deposited on Clever.
    /// @param minAmountOut minimum amount of clevCVX to receive after the swap. Only used if `swap` is true
    function deposit(uint256 cvxAmount, bool swap, uint256 minAmountOut) external onlyManager unlockNotInProgress {
        CVX.safeTransferFrom(msg.sender, address(this), cvxAmount);
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

    /// @notice Requests to unlock assets
    /// @param _assets The amount of assets to unlock
    /// @param _receiver The address to receive CVX after the unlock period is over
    /// @return The epoch number when all the requested CVX can be withdrawn
    function requestUnlock(uint256 _assets, address _receiver) external onlyManager unlockNotInProgress returns (uint256) {
        if (block.timestamp < maintenanceWindowEnd) revert MaintenanceWindow();

        uint256 _currentUnlockObligations = unlockObligations;

        unlockObligations += _assets;
        UnlockRequest[] storage unlocks = requestedUnlocks[_receiver].unlocks;

        (ICLeverLocker.EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));

        uint256 _locksLength = locks.length;
        for (uint256 i; i < _locksLength; i++) { // @todo - gas optimization ++i
            uint256 _availableToUnlock = locks[i].pendingUnlock;
            uint64 _epoch = locks[i].unlockEpoch;

            if (_currentUnlockObligations != 0) {
                if (_currentUnlockObligations < _availableToUnlock) {
                    _availableToUnlock -= _currentUnlockObligations;
                    _currentUnlockObligations = 0;
                } else {
                    _currentUnlockObligations -= _availableToUnlock;
                    continue; // dev: move to the next epoch as all available amount was already requested
                }
            }

            if (_assets > _availableToUnlock) {
                unlocks.push(UnlockRequest({ unlockAmount: uint192(_availableToUnlock), unlockEpoch: _epoch }));
                _assets -= _availableToUnlock;
            } else {
                unlocks.push(UnlockRequest({ unlockAmount: uint192(_assets), unlockEpoch: _epoch }));
                return _epoch;
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

        CVX.safeTransfer(account, cvxUnlocked);
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

    /// @notice borrows maximum amount of clevCVX and deposits it to the Furnace
    /// @dev must be called after `deposit` as CLever doesn't allow depositing and borrowing in the same block
    function borrow() external onlyOperatorOrOwner {
        CLEVER_CVX_LOCKER.borrow(
            _calculateMaxBorrowAmount(), // amount
            true // depositToFurnace
        );
    }

    /// @notice withdraws clevCVX from the Furnace and repays the debt to allow unlocking
    /// @dev must be called before `unlock` as Clever doesn't allow repaying and unlocking in the same block
    function repay() external onlyOperatorOrOwner {
        unlockInProgress = true;
        uint256 _unlockObligations = unlockObligations;
        if (_unlockObligations != 0) {
            (uint256 _repayAmount, uint256 _repayFee) = _calculateRepayAmount(_unlockObligations);
            if (_repayAmount == 0) return;

            uint256 _clevCvxRequired = _repayAmount + _repayFee;
            FURNACE.withdraw(address(this), _clevCvxRequired);

            // The repayment will actually pull _clevCvxRequired amount
            CLEVER_CVX_LOCKER.repay(
                0, // cvxAmount
                _repayAmount // clevCvxAmount
            );
        }
    }

    /// @notice Unlocks CVX to fulfill the withdrawal requests. Must be called before the end of the epoch
    /// @dev Must be called after `repay` as Clever doesn't allow repaying and unlocking in the same block
    function unlock() external onlyOperatorOrOwner {
        uint256 _unlockObligations = unlockObligations;
        if (_unlockObligations != 0) {
            unlockObligations = 0;
            CLEVER_CVX_LOCKER.unlock(_unlockObligations);

            // The start of the next epoch. Until then unlock requests are blocked
            maintenanceWindowEnd = block.timestamp / REWARDS_DURATION * REWARDS_DURATION + REWARDS_DURATION;
        }
        unlockInProgress = false;
    }

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();

        operator = _operator;
        emit OperatorSet(_operator);
    }

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

    // ============================================================================================
    // Private view functions
    // ============================================================================================

    function _calculateRepayAmount(uint256 _unlockObligations) private view returns (uint256 _repayAmount, uint256 _repayFee) {
        (uint256 _totalDeposited, , , uint256 _totalBorrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));

        if (_totalBorrowed == 0) return (0, 0);

        _totalDeposited -= _unlockObligations;

        uint256 _maxBorrowAfterUnlock = _totalDeposited * CLEVER_CVX_LOCKER.reserveRate() / CLEVER_PRECISION;

        if (_totalBorrowed > _maxBorrowAfterUnlock) {
            _repayAmount = _totalBorrowed - _maxBorrowAfterUnlock;
            _repayFee = _unlockObligations * CLEVER_CVX_LOCKER.repayFeePercentage() / CLEVER_PRECISION;
        }
    }

    function _calculateMaxBorrowAmount() private view returns (uint256) {
        (uint256 _totalDeposited,,, uint256 _totalBorrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return _totalDeposited * CLEVER_CVX_LOCKER.reserveRate() / CLEVER_PRECISION - _totalBorrowed;
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

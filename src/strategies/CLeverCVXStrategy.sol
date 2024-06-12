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

    uint256 private constant PRECISION = 10_000;
    uint256 private constant CLEVER_PRECISION = 1e9;
    uint256 private constant REWARDS_DURATION = 1 weeks;

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);

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
    // Owner functions
    // ============================================================================================

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();

        operator = _operator;
        emit OperatorSet(_operator);
    }

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

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
        if (unlockInProgress) revert UnlockInProgress();
        _;
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the total assets under management minus debt and obligations
    /// @param _performanceFeeBps The performance fee in basis points
    /// @return The net assets
    function netAssets(uint256 _performanceFeeBps) public view returns (uint256) {
        (uint256 _deposited, , , uint256 _borrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        (uint256 _unrealizedFurnace, uint256 _realizedFurnace) = FURNACE.getUserInfo(address(this));
        return
            _deposited
            + _unrealizedFurnace
            + (_realizedFurnace == 0 ? 0 : (_realizedFurnace - _realizedFurnace * _performanceFeeBps / PRECISION))
            - (_borrowed == 0 ? 0 : _borrowed * (CLEVER_CVX_LOCKER.repayFeePercentage() + CLEVER_PRECISION) / CLEVER_PRECISION)
            - unlockObligations;
    }

    /// @notice Returns the maximum amount of assets that can be unlocked
    /// @return The amount of assets that can be unlocked
    function maxTotalUnlock() external view returns (uint256) {
        (uint256 _deposited, , , uint256 _borrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));

        uint256 _repayFeePercentage = CLEVER_CVX_LOCKER.repayFeePercentage();
        uint256 _repayFee =
                _borrowed * _repayFeePercentage
                / CLEVER_PRECISION + (_borrowed * _repayFeePercentage % CLEVER_PRECISION == 0 ? 0 : 1);

        uint256 _unlockObligations = unlockObligations;
        return _unlockObligations + _repayFee >= _deposited ? 0 : _deposited - _repayFee - _unlockObligations;
    }

    /// @notice Returns the unlock requests for the specified account
    /// @param _account The address to query
    /// @return _unlocks The unlock requests
    function getRequestedUnlocks(address _account) external view returns (UnlockRequest[] memory _unlocks) {
        UnlockRequest[] storage accountUnlocks = requestedUnlocks[_account].unlocks;
        uint256 nextUnlockIndex = requestedUnlocks[_account].nextUnlockIndex;
        uint256 unlocksLength = accountUnlocks.length;
        _unlocks = new UnlockRequest[](unlocksLength - nextUnlockIndex);
        for (uint256 i; nextUnlockIndex < unlocksLength; ++nextUnlockIndex) {
            _unlocks[i].unlockEpoch = accountUnlocks[nextUnlockIndex].unlockEpoch;
            _unlocks[i].unlockAmount = accountUnlocks[nextUnlockIndex].unlockAmount;
            ++i;
        }
    }

    // ============================================================================================
    // Manager functions
    // ============================================================================================

    /// @notice Deposits assets to the strategy
    /// @param _assets The amount of assets to deposit
    /// @param _swap A flag indicating whether CVX should be swapped for clevCVX or deposited to Clever
    /// @param _minAmountOut The minimum amount of clevCVX to receive after the swap. Only used if `swap` is true
    function deposit(uint256 _assets, bool _swap, uint256 _minAmountOut) external onlyManager unlockNotInProgress {
        CVX.safeTransferFrom(msg.sender, address(this), _assets);
        if (_swap) {
            uint256 clevCvxAmount = Zap.swapCvxToClevCvx(_assets, _minAmountOut);
            FURNACE.deposit(clevCvxAmount);
        } else {
            CLEVER_CVX_LOCKER.deposit(_assets);
        }
    }

    /// @notice Claims all realised CVX from Furnace
    /// @return _rewards The amount of rewards claimed
    function claim() external onlyManager returns (uint256 _rewards) {
        (, _rewards) = FURNACE.getUserInfo(address(this));
        if (_rewards > 0) {
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

        (ICLeverLocker.EpochUnlockInfo[] memory _locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));

        uint256 _locksLength = _locks.length;
        for (uint256 i; i < _locksLength; ++i) {
            uint256 _availableToUnlock = _locks[i].pendingUnlock;
            uint64 _epoch = _locks[i].unlockEpoch;

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

    /// @notice Withdraws assets that became unlocked by the current epoch
    /// @param _account The address to receive the unlocked assets
    /// @return _assets The amount of unlocked assets sent
    function withdrawUnlocked(address _account) external onlyManager unlockNotInProgress returns (uint256 _assets) {
        uint256 _currentEpoch = block.timestamp / REWARDS_DURATION;
        UnlockRequest[] storage unlocks = requestedUnlocks[_account].unlocks;
        uint256 _nextUnlockIndex = requestedUnlocks[_account].nextUnlockIndex;
        uint256 _unlocksLength = unlocks.length;

        for (; _nextUnlockIndex < _unlocksLength; _nextUnlockIndex++) {
            uint256 _unlockEpoch = unlocks[_nextUnlockIndex].unlockEpoch;
            if (_unlockEpoch <= _currentEpoch) {
                uint256 _unlocked = unlocks[_nextUnlockIndex].unlockAmount;
                delete unlocks[_nextUnlockIndex];
                _assets += _unlocked;
            } else {
                break;
            }
        }

        requestedUnlocks[_account].nextUnlockIndex = _nextUnlockIndex;

        if (_assets == 0) return 0;

        if (CVX.balanceOf(address(this)) < _assets) {
            (,, uint256 _totalUnlocked,,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
            if (_totalUnlocked > 0) {
                CLEVER_CVX_LOCKER.withdrawUnlocked();
            }
        }
        CVX.safeTransfer(_account, _assets);
    }

    /// @notice Pauses the strategy
    /// @param _paused A flag indicating whether the strategy should be paused
    function setPaused(bool _paused) external onlyManager {
        paused = _paused;
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

            CLEVER_CVX_LOCKER.repay( // this will actually pull _clevCvxRequired amount
                0, // cvxAmount
                _repayAmount // clevCvxAmount
            );
        }
    }

    /// @notice Unlocks assets to fulfill the withdrawal requests. Must be called before the end of the epoch
    /// @dev Must be called after `repay` as Clever doesn't allow repaying and unlocking in the same block
    function unlock() external onlyOperatorOrOwner {
        uint256 _unlockObligations = unlockObligations;
        if (_unlockObligations != 0) {
            unlockObligations = 0;
            CLEVER_CVX_LOCKER.unlock(_unlockObligations);
        }

        // The start of the next epoch. Until then unlock requests are blocked
        maintenanceWindowEnd = block.timestamp / REWARDS_DURATION * REWARDS_DURATION + REWARDS_DURATION;

        unlockInProgress = false;
    }

    // ============================================================================================
    // Private view functions
    // ============================================================================================

    function _calculateRepayAmount(uint256 _unlockObligations) private view returns (uint256 _repayAmount, uint256 _repayFee) {
        (uint256 _deposited, , , uint256 _borrowed, ) = CLEVER_CVX_LOCKER.getUserInfo(address(this));

        if (_borrowed == 0) return (0, 0);

        _deposited -= _unlockObligations;

        uint256 _maxBorrowAfterUnlock = _deposited * CLEVER_CVX_LOCKER.reserveRate() / CLEVER_PRECISION;

        if (_borrowed > _maxBorrowAfterUnlock) {
            _repayAmount = _borrowed - _maxBorrowAfterUnlock;
            uint256 _repayFeePercentage = CLEVER_CVX_LOCKER.repayFeePercentage();
            _repayFee =
                _repayAmount * _repayFeePercentage
                / CLEVER_PRECISION + (_repayAmount * _repayFeePercentage % CLEVER_PRECISION == 0 ? 0 : 1);
        }
    }

    function _calculateMaxBorrowAmount() private view returns (uint256) {
        (uint256 _deposited,,, uint256 _borrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return _deposited * CLEVER_CVX_LOCKER.reserveRate() / CLEVER_PRECISION - _borrowed;
    }

    // ============================================================================================
    // Events
    // ============================================================================================

    event OperatorSet(address indexed newOperator);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error InvalidAddress();
    error UnlockInProgress();
    error InvalidState();
    error MaintenanceWindow();
    error Paused();
}

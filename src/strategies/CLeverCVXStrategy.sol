// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Ownable } from "solady/auth/Ownable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IAfCvx } from "../interfaces/afCvx/IAfCvx.sol";
import { ICleverCvxStrategy } from "../interfaces/afCvx/ICleverCvxStrategy.sol";
import { TrackedAllowances, Allowance } from "../utils/TrackedAllowances.sol";
import { Zap } from "../utils/Zap.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "../interfaces/clever/ICLeverCvxLocker.sol";
import { FURNACE } from "../interfaces/clever/IFurnace.sol";
import { CVX } from "../interfaces/convex/Constants.sol";
import { CLEVCVX } from "../interfaces/clever/Constants.sol";

contract CleverCvxStrategy is ICleverCvxStrategy, TrackedAllowances, Ownable, UUPSUpgradeable {
    using SafeTransferLib for address;

    /// @dev The denominator used for CLever fee calculation.
    uint256 private constant CLEVER_FEE_PRECISION = 1e9;
    uint256 private constant REWARDS_DURATION = 1 weeks;

    address public immutable manager;
    /// @dev Tracks the total amount of CVX unlock obligations the contract has ever had.
    uint128 internal cumulativeUnlockObligations;
    /// @dev Tracks the total amount of CVX that has ever been unlocked.
    uint128 internal cumulativeUnlocked;

    mapping(address account => mapping(uint256 unlockEpoch => uint256 amount)) public pendingUnlocks;

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    /// @dev As recommended by https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
    constructor(address afCvx) {
        _disableInitializers();
        manager = afCvx;
    }

    function initialize(address initialOwner) external initializer {
        _initializeOwner(initialOwner);
        __UUPSUpgradeable_init();

        // Approve once to save gas later by avoiding having to re-approve every time.
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(FURNACE), token: address(CLEVCVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CLEVER_CVX_LOCKER), token: address(CVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CLEVER_CVX_LOCKER), token: address(CLEVCVX) }));
    }

    function totalValue() public view returns (uint256 deposited, uint256 rewards) {
        (uint256 depositedClever,,, uint256 borrowedClever,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        (uint256 unrealisedFurnance, uint256 realisedFurnance) = FURNACE.getUserInfo(address(this));

        deposited = CVX.balanceOf(address(this)) + depositedClever - borrowedClever + unrealisedFurnance;
        rewards = realisedFurnance;
    }

    function previewUnlocks(uint256 amount) external view returns (EpochUnlockInfo[] memory unlocks) {
        (EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));
        uint256 locksLength = locks.length;
        uint256 unlocksLength;
        uint256 requestedAmount = amount;
        for (uint256 i; i < locksLength; i++) {
            uint256 locked = locks[i].pendingUnlock;
            unlocksLength++;
            if (requestedAmount > locked) {
                requestedAmount -= locked;
            } else {
                break;
            }
        }

        unlocks = new EpochUnlockInfo[](unlocksLength);
        requestedAmount = amount;
        for (uint256 i; i < unlocksLength; i++) {
            uint192 locked = locks[i].pendingUnlock;
            if (requestedAmount > locked) {
                unlocks[i].pendingUnlock = locked;
                requestedAmount -= locked;
            } else {
                unlocks[i].pendingUnlock = uint192(requestedAmount);
            }

            unlocks[i].unlockEpoch = locks[i].unlockEpoch;
        }
    }

    function getPendingUnlocks(address account) public view returns (EpochUnlockInfo[] memory unlocks) {
        uint256 pendingUnlocksLength = 0;
        (, EpochUnlockInfo[] memory globalPendingUnlocks) = CLEVER_CVX_LOCKER.getUserLocks(address(this));
        uint256 globalPendingUnlocksLength = globalPendingUnlocks.length;

        for (uint256 i; i < globalPendingUnlocksLength; i++) {
            uint256 unlockEpoch = globalPendingUnlocks[i].unlockEpoch;
            if (pendingUnlocks[account][unlockEpoch] != 0) {
                pendingUnlocksLength++;
            }
        }

        unlocks = new EpochUnlockInfo[](pendingUnlocksLength);
        uint256 j = 0;
        for (uint256 i; i < globalPendingUnlocksLength; i++) {
            uint256 unlockEpoch = globalPendingUnlocks[i].unlockEpoch;
            uint256 unlockAmount = pendingUnlocks[account][unlockEpoch];
            if (unlockAmount != 0) {
                unlocks[j++] =
                    EpochUnlockInfo({ pendingUnlock: uint192(unlockAmount), unlockEpoch: uint64(unlockEpoch) });
            }
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

    /// @notice borrows maximum amount of clevCVX and deposits it to Furnance
    function borrow() external onlyManager {
        CLEVER_CVX_LOCKER.borrow(_calculateMaxBorrowAmount(), true);
    }

    /// @notice claims all realised CVX from Furnance
    /// @return rewards amount of realised CVX
    function claim() external onlyManager returns (uint256 rewards) {
        (, rewards) = FURNACE.getUserInfo(address(this));
        if (rewards > 0) {
            FURNACE.claim(manager);
        }
    }

    /// @notice requests to unlock CVX
    function requestUnlock(uint256 amount, address account) external onlyManager returns (uint256 unlockEpoch) {
        cumulativeUnlockObligations += uint128(amount);
        (EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(this));
        uint256 locksLength = locks.length;
        for (uint256 i; i < locksLength; i++) {
            uint256 locked = locks[i].pendingUnlock;
            uint256 epoch = locks[i].unlockEpoch;
            if (amount > locked) {
                pendingUnlocks[account][epoch] += locked;
                amount -= locked;
            } else {
                pendingUnlocks[account][epoch] += amount;
                unlockEpoch = epoch;
                break;
            }
        }
    }

    /// @notice withdraws unlocked CVX
    function withdrawUnlocked(address account) external onlyManager returns (uint256 cvxUnlocked) {
        uint256 currentEpoch = block.timestamp / REWARDS_DURATION;
        (, EpochUnlockInfo[] memory globalPendingUnlocks) = CLEVER_CVX_LOCKER.getUserLocks(address(this));
        uint256 globalPendingUnlocksLength = globalPendingUnlocks.length;

        for (uint256 i; i < globalPendingUnlocksLength; i++) {
            uint256 unlockEpoch = globalPendingUnlocks[i].unlockEpoch;
            uint256 unlockAmount = pendingUnlocks[account][unlockEpoch];
            if (unlockEpoch <= currentEpoch && unlockAmount != 0) {
                delete pendingUnlocks[account][unlockEpoch];
                cvxUnlocked += unlockAmount;
            }
        }
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

    function repay() external onlyManager {
        uint256 unlockAmount = _getUnlockAmount();
        if (unlockAmount != 0) {
            (uint256 repayAmount, uint256 repayFee) = _calculateRepayAmount(unlockAmount);
            FURNACE.withdraw(address(this), repayAmount + repayFee);
            CLEVER_CVX_LOCKER.repay(0, repayAmount);
        }
    }

    function unlock() external onlyManager {
        uint256 unlockAmount = _getUnlockAmount();
        if (unlockAmount != 0) {
            cumulativeUnlocked += uint128(unlockAmount);
            CLEVER_CVX_LOCKER.unlock(unlockAmount);
        }
    }

    /// @dev Allows the owner of the contract to upgrade to *any* new address.
    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner { }

    function _getUnlockAmount() private view returns (uint256) {
        return cumulativeUnlockObligations - cumulativeUnlocked;
    }

    function _calculateMaxBorrowAmount() private view returns (uint256) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        (uint256 totalDeposited,,, uint256 totalBorrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
        return totalDeposited * reserveRate / CLEVER_FEE_PRECISION - totalBorrowed;
    }

    function _calculateRepayAmount(uint256 _lockedCVX) private view returns (uint256 repayAmount, uint256 repayFee) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        uint256 repayRate = CLEVER_CVX_LOCKER.repayFeePercentage();
        repayAmount = _lockedCVX * reserveRate / CLEVER_FEE_PRECISION;
        repayFee = repayAmount * repayRate / CLEVER_FEE_PRECISION;
    }
}

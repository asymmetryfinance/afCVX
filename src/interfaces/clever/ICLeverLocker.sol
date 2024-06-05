// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICLeverLocker {

    struct EpochUnlockInfo {
        uint192 pendingUnlock;
        uint64 unlockEpoch;
    }

    function repayFeePercentage() external view returns (uint256);
    function reserveRate() external view returns (uint256);
    function getUserInfo(address account) external view returns (uint256 totalDeposited, uint256 totalPendingUnlocked, uint256 totalUnlocked, uint256 totalBorrowed, uint256 totalReward);
    function getUserLocks(address account) external view returns (EpochUnlockInfo[] memory locks, EpochUnlockInfo[] memory pendingUnlocks);
    function deposit(uint256 amount) external;
    function unlock(uint256 amount) external;
    function withdrawUnlocked() external;
    function repay(uint256 cvxAmount, uint256 clevCvxAmount) external;
    function borrow(uint256 amount, bool depositToFurnace) external;
    function harvest(address recipient, uint256 minimumOut) external returns (uint256);
    function processUnlockableCVX() external;
    function updateRepayFeePercentage(uint256 _feePercentage) external;
}

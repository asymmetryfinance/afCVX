// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

ICleverCvxLocker constant CLEVER_CVX_LOCKER = ICleverCvxLocker(address(0x96C68D861aDa016Ed98c30C810879F9df7c64154));

struct EpochUnlockInfo {
    // The number of CVX should unlocked at the start of epoch `unlockEpoch`.
    uint192 pendingUnlock;
    // The epoch number to unlock `pendingUnlock` CVX
    uint64 unlockEpoch;
}

interface ICleverCvxLocker {
    function repayFeePercentage() external view returns (uint256);
    function reserveRate() external view returns (uint256);

    function getUserInfo(address account)
        external
        view
        returns (
            uint256 totalDeposited,
            uint256 totalPendingUnlocked,
            uint256 totalUnlocked,
            uint256 totalBorrowed,
            uint256 totalReward
        );

    function getUserLocks(address account)
        external
        view
        returns (EpochUnlockInfo[] memory locks, EpochUnlockInfo[] memory pendingUnlocks);

    function deposit(uint256 amount) external;

    function unlock(uint256 amount) external;

    function withdrawUnlocked() external;

    function repay(uint256 cvxAmount, uint256 clevCvxAmount) external;

    function borrow(uint256 amount, bool depositToFurnace) external;

    function harvest(address recipient, uint256 minimumOut) external returns (uint256);
}

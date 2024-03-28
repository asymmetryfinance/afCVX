// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

ICLeverCVXLocker constant CLEVER_CVX_LOCKER = ICLeverCVXLocker(address(0x96C68D861aDa016Ed98c30C810879F9df7c64154));

interface ICLeverCVXLocker {
    struct EpochUnlockInfo {
        // The number of CVX should unlocked at the start of epoch `unlockEpoch`.
        uint192 pendingUnlock;
        // The epoch number to unlock `pendingUnlock` CVX
        uint64 unlockEpoch;
    }

    struct UserInfo {
        // The total number of clevCVX minted.
        uint128 totalDebt;
        // The amount of distributed reward.
        uint128 rewards;
        // The paid accumulated reward per share, multipled by 1e18.
        uint192 rewardPerSharePaid;
        // The block number of the last interacted block (deposit, unlock, withdraw, repay, borrow).
        uint64 lastInteractedBlock;
        // The total amount of CVX locked.
        uint112 totalLocked;
        // The total amount of CVX unlocked.
        uint112 totalUnlocked;
        // The next unlock index to speedup unlock process.
        uint32 nextUnlockIndex;
        // In Convex, if you lock at epoch `e` (block.timestamp in `[e * rewardsDuration, (e + 1) * rewardsDuration)`),
        // you lock will start at epoch `e + 1` and will unlock at the beginning of epoch `(e + 17)`. If we relock right
        // after the unlock, all unlocked CVX will start lock at epoch `e + 18`, and will locked again at epoch `e + 18 + 16`.
        // If we continue the process, all CVX locked in epoch `e` will be unlocked at epoch `e + 17 * k` (k >= 1).
        //
        // Here, we maintain an array for easy calculation when users lock or unlock.
        //
        // `epochLocked[r]` maintains all locked CVX whose unlocking epoch is `17 * k + r`. It means at the beginning of
        //  epoch `17 * k + r`, the CVX will unlock, if we continue to relock right after unlock.
        uint256[17] epochLocked;
        // The list of pending unlocked CVX.
        EpochUnlockInfo[] pendingUnlockList;
    }

    function reserveRate() external view returns (uint256);

    function userInfo(address _account) external view returns (UserInfo memory);

    function getUserInfo(address _account)
        external
        view
        returns (
            uint256 totalDeposited,
            uint256 totalPendingUnlocked,
            uint256 totalUnlocked,
            uint256 totalBorrowed,
            uint256 totalReward
        );

    function deposit(uint256 _amount) external;

    function unlock(uint256 _amount) external;

    function withdrawUnlocked() external;

    function repay(uint256 _cvxAmount, uint256 _clevCVXAmount) external;

    function borrow(uint256 _amount, bool _depositToFurnace) external;

    function harvest(address _recipient, uint256 _minimumOut) external returns (uint256);
}

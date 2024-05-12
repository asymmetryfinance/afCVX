// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

interface ICleverCvxStrategy {
    struct UnlockRequest {
        uint192 unlockAmount;
        uint64 unlockEpoch;
    }

    struct UnlockInfo {
        UnlockRequest[] unlocks;
        uint256 nextUnlockIndex;
    }

    error InvalidAddress();
    error InsufficientFurnaceBalance();
    error UnlockInProgress();
    error InvalidState();
    error MaintenanceWindow();

    event OperatorSet(address indexed newOperator);
    event EmergencyShutdown();

    function totalValue() external view returns (uint256 deposited, uint256 rewards);
    function maxTotalUnlock() external view returns (uint256 maxUnlock);
    function deposit(uint256 cvxAmount, bool swap, uint256 minAmountOut) external;
    function borrow() external;
    function claim() external returns (uint256);
    function requestUnlock(uint256 amount, address to) external returns (uint256 unlockEpoch);
    function withdrawUnlocked(address account) external returns (uint256 cvxUnlocked);
    function setOperator(address newOperator) external;
    function emergencyShutdown() external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICleverStrategy {
    function netAssets() external view returns (uint256);
    function totalValue() external view returns (uint256 deposited, uint256 rewards, uint256 obligations);
    function maxTotalUnlock() external view returns (uint256 maxUnlock);
    function deposit(uint256 cvxAmount, bool swap, uint256 minAmountOut) external;
    function borrow() external;
    function claim() external returns (uint256);
    function requestUnlock(uint256 amount, address to) external returns (uint256 unlockEpoch);
    function withdrawUnlocked(address account) external returns (uint256 cvxUnlocked);
    function setOperator(address newOperator) external;
    function emergencyShutdown() external;
}

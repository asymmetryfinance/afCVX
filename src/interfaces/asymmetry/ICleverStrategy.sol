// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICLeverStrategy {
    function netAssets(uint256 _performanceFeeBps) external view returns (uint256);
    function maxTotalUnlock() external view returns (uint256 maxUnlock);
    function deposit(uint256 _assets, uint256 _swapPercentage, uint256 _minAmountOut) external;
    function claim() external returns (uint256);
    function requestUnlock(uint256 amount, address to) external returns (uint256 unlockEpoch);
    function withdrawUnlocked(address account) external returns (uint256 cvxUnlocked);
    function setPaused(bool _paused) external;
}

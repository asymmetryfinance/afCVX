// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ILPStrategy {
    function totalAssets() external view returns (uint256);
    function addLiquidity(uint256 _cvxAmount, uint256 _clevCvxAmount, uint256 _minAmountOut) external returns (uint256);
    function removeLiquidityOneCoin(uint256 _burnAmount, uint256 _minAmountOut, bool _isCVX) external returns (uint256);
}

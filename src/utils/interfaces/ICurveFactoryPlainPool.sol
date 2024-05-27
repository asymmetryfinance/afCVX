// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICurveFactoryPlainPool {
    function price_oracle() external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}
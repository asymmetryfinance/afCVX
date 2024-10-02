// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IConvexRewardsPool {
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function withdraw(uint256 amount, bool claim) external;
    function withdrawAll(bool claim) external;
    function getReward(address account, bool claimExtras, bool stake) external;
    function getReward(address account, bool claimExtras) external;
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

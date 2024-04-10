// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

ICvxRewardsPool constant CVX_REWARDS_POOL = ICvxRewardsPool(address(0xCF50b810E57Ac33B91dCF525C6ddd9881B139332));

interface ICvxRewardsPool {
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);

    function stake(uint256 amount) external;
    function withdraw(uint256 amount, bool claim) external;
    function withdrawAll(bool claim) external;
    function getReward(bool _stake) external;
}

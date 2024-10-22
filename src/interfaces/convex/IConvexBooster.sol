// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IConvexBooster {
    function deposit(uint256 _pid, uint256 _amount, bool _stake) external returns (bool);
}
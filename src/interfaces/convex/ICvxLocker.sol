// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICvxLocker {

    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
    }

    // Information on a user's locked balances
    function lockedBalances(address _user) view external returns(uint256 total, uint256 unlockable, uint256 locked, LockedBalance[] memory lockData);
}
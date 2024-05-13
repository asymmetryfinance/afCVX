// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IPirexCVX {

    // Users can choose between the two futures tokens when staking or initiating a redemption
    enum Futures {
        Vote,
        Reward
    }

    enum Fees {
        Reward,
        RedemptionMax,
        RedemptionMin,
        Developers
    }

    /**
        @notice Initiate CVX redemptions
        @param  lockIndexes  uint256[]  Locked balance index
        @param  f            enum       Futures enum
        @param  assets       uint256[]  pxCVX amounts
        @param  receiver     address    Receives upxCVX
     */
    function initiateRedemptions(uint256[] calldata lockIndexes, Futures f, uint256[] calldata assets, address receiver) external;

    /**
        @notice Redeem CVX for specified unlock times
        @param  unlockTimes  uint256[]  CVX unlock timestamps
        @param  assets       uint256[]  upxCVX amounts
        @param  receiver     address    Receives CVX
     */
    function redeem(uint256[] calldata unlockTimes, uint256[] calldata assets, address receiver) external;

    /**
        @notice Redeem CVX for deprecated upxCVX holders if enabled
        @param  unlockTimes  uint256[]  CVX unlock timestamps
        @param  assets       uint256[]  upxCVX amounts
        @param  receiver     address    Receives CVX
     */
    function redeemLegacy(uint256[] calldata unlockTimes, uint256[] calldata assets, address receiver) external;

    function MAX_REDEMPTION_TIME() external view returns (uint256);

    function FEE_DENOMINATOR() external view returns (uint256);

    function fees(Fees) external view returns (uint256);
}
// SPDX-License-Identifier: MIT

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

pragma solidity 0.8.25;

interface IAfCvx is IERC4626 {
    error InvalidShare();
    error InvalidFee();
    error InvalidAddress();

    event CleverCvxStrategyShareSet(uint256 indexed newShare);
    event ProtocolFeeSet(uint256 indexed newProtocolFee);
    event WithdrawalFeeSet(uint256 indexed newWithdrawalFee);
    event ProtocolFeeCollectorSet(address indexed newProtocolFeeCollector);
    event WeeklyWithdrawShareSet(uint256 indexed newShare);
    event OperatorSet(address indexed newOperator);
    event EmergencyShutdown();
    event Distributed(uint256 indexed cleverDepositAmount, uint256 indexed convexStakeAmount);
    event Harvested(uint256 indexed cleverRewards, uint256 indexed convexStakedRewards);
    event UnlockRequested(address indexed receiver, uint256 indexed amount, uint256 indexed unlockEpoch);
    event UnlockedWithdrawn(address indexed receiver, uint256 indexed amount);
    event WeeklyWithdrawLimitUpdated(uint256 indexed withdrawLimit, uint256 nextUpdateDate);

    function getAvailableAssets() external view returns (uint256 unlocked, uint256 lockedInClever, uint256 staked);
    function previewDistribute() external view returns (uint256 cleverDepositAmount, uint256 convexStakeAmount);
    function previewRequestUnlock(uint256 assets) external view returns (uint256);
    function distribute(bool swap, uint256 minAmountOut) external;
    function requestUnlock(uint256 assets, address receiver, address owner) external returns (uint256 unlockEpoch);
    function withdrawUnlocked(address receiver) external;
    function harvest(uint256 minAmountOut) external returns (uint256 rewards);
    function setCleverCvxStrategyShare(uint16 newShareBps) external;
    function setProtocolFee(uint16 newFeeBps) external;
    function setWithdrawalFee(uint16 newFeeBps) external;
    function setWeeklyWithdrawShare(uint16 newShareBps) external;
    function setProtocolFeeCollector(address newProtocolFeeCollector) external;
    function setOperator(address newOperator) external;
}

# Operating Manual

This document outlines how the protocol should be interacted with and maintained. It is divided into three main sections based on the following roles:

- **_owner_** is the highest privileged role responsible for setting the protocol parameters and emergency shutdown;
- **_operator_** is a privileged role responsible for protocol management tasks, such as harvesting rewards and depositing into strategies;
- **_user_** defines any permissionless actions accessible by anyone.

## Owner

> [!CAUTION]
> In case of an on-going exploit or other emergency invoke the `AfCvx::emergencyShutdown()` method,
> this will pause all deposit/withdrawal functions as well as disable the `CLeverCvxStrategy`.
> When the contracts are paused only the owner can perform the protocol management tasks.

### Configuring Roles

**Changing the owner**

To change the owner of `AfCvx` or `CLeverCvxStrategy` follow these steps:

1. The new owner needs to call `requestOwnershipHandover` this will request a handover.
2. The current owner will then have 48h to call `completeOwnershipHandover(address newOwner)` to
   confirm the handover.

This process is recommended as it ensures you don't accidentally transfer ownership to a wallet you don't have control over.

**Changing the operator**

To change the operator role in `AfCvx` and `CLeverCvxStrategy` as the owner call `setOperator` in each contract passing the address of a new operator.

```solidity
function setOperator(address newOperator) external
```

### Configuring Fees

**Changing the protocol fee**

The protocol fee is taken during harvesting and sent to the protocol fee collector.
To set the fee call `AfCvx::setProtocolFee` with a value representing new protocol fee in basis points. For example, to set the protocol fee to `1%` pass `100` to the function.

```solidity
function setProtocolFee(uint16 newFeeBps) external
```

**Changing the withdrawal fee**

The withdrawal is taken when a user calls `AfCvx::withdraw` or `AfCvx::redeem` and left in the contract to be redeposited or used for subsequent withdrawals.
To set the fee call `AfCvx::setWithdrawalFee` with a value representing new withdrawal fee in basis points.

```solidity
function setWithdrawalFee(uint16 newFeeBps) external
```

### Configuring Protocol Fee Collector (AfCvx)

To set the address that receives the protocol fee call `AfCvx::setProtocolFeeCollector`.

```solidity
function setProtocolFeeCollector(address newProtocolFeeCollector) external
```

### Configuring the share of assets deposited to CLever CVX Strategy

The default ratio for assets distribution between CLever CVX Strategy and staked CVX in Convex is 80/20. To change the percentage of CLever CVX Strategy, as the owner call `AfCvx::setCLeverCvxStrategyShare` with the value representing new share in basis points. For example, to set the share to `75%` pass `7500` to the function. Note, that the share of staked CVX is calculated automatically.

```solidity
function setCLeverCvxStrategyShare(uint16 newShareBps) external
```

### Configuring Weekly Withdrawal Share

To set the percentage of total value locked that can be withdrawn in one week, as the owner call `AfCvx::setWeeklyWithdrawShare` passing the new share in basis points. For example, to set the share to `2%` pass `200` to the function.

```solidity
function setWeeklyWithdrawShare(uint16 newShareBps) external
```

## Operator

> [!IMPORTANT]
> The system management operations are time-sensitive and must be performed at a specific time each epoch to ensure the expected protocol behavior.

### Depositing CVX into Strategies

To distribute the deposited CVX between CLever CVX Strategy and Convex staking contract, as the operator (or owner) call `AfCvx::distribute` function with the following parameters:

- `swap` - a boolean flag indicating whether CVX should be swapped on Curve for clevCVX or deposited in CLever Locker.
- `minAmountOut` - a minimum amount of clevCVX to receive after the swap. Only used if `swap` parameter is `true`.

```solidity
function distribute(bool swap, uint256 minAmountOut) external
```

To preview the amounts of CVX that will be deposited to each strategy anyone can call `AfCvx::previewDistribute` view function.

```solidity
function previewDistribute() external view returns (uint256 cleverDepositAmount, uint256 convexStakeAmount)
```

The frequency of `AfCvx::distribute` calls depends on deposits volume.

### Borrowing clevCVX and depositing to Furnace

If `AfCvx::distribute` function was invoked with `swap` parameter set to `false` and CVX was deposited to CLever, the operator must call `CLeverCvxStrategy::borrow` after calling `AfCvx::distribute`.

```solidity
function borrow() external
```

> [!NOTE] 
> `CLeverCvxStrategy::borrow` is implemented as a stand-alone function because `CLeverCvxLocker` contract doesn't allow depositing and borrowing in the same block.

### Harvesting Rewards

> [!IMPORTANT]
> Convex rewards and Furnace realised CVX are distributed gradually and can be harvested at any time. CLever rewards are distributed every two weeks and used to reduce the debt. To ensure that CLever strategy is at the maximum leverage `harvest` function should be called after CLever rewards distribution.

To harvest rewards from the underling strategies as the operator call `AfCvx::harvest` function passing the minimum amount of CVX to receive when swapping cvxCRV to CVX:

```solidity
function harvest(uint256 minAmountOut) external returns (uint256 rewards)
```

To get the amount of cvxCRV earned by the protocol call `earned` function in Convex [CVXRewardsPool](https://etherscan.io/address/0xCF50b810E57Ac33B91dCF525C6ddd9881B139332#readContract) contract passing afCVX contract address

```solidity
function earned(address account) external view returns (uint256);
```

Then use Curve UI or API to determine the minimum amount of CVX that can be received when swapping clevCVX

> [!IMPORTANT]
> The harvested rewards are not automatically redeposited. To deposit CVX to the underlying strategies call `AfCvx::distribute` function after harvesting.

### Repaying Debt and Unlocking CVX

At the end of each epoch if `CLeverCvxStrategy::unlockObligations` > 0 the operator must call `CLeverCvxStrategy::repay` and `CLeverCvxStrategy::unlock`.

```solidity
function repay() external;
```

```solidity
function unlock() external;
```

> [!IMPORTANT]
> The functions must be called as close to the end of the epoch as possible because users won't be able to request unlocks between the last `CLeverCvxStrategy::unlock` call and the beginning of a new epoch.

> [!NOTE] 
> `CLeverCvxStrategy::repay` and `CLeverCvxStrategy::unlock` are implemented as two separate functions because `CLeverCvxLocker` contract doesn't allow repaying and unlocking in the same block.

## User

> [!NOTE] 
> `afCvx` is [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) compliant contract that accepts CVX deposit and issues afCvx shares.

### Depositing

To deposit CVX to `afCvx` first approve the vault to spend CVX by calling `CVX::approve` function, then call `afCvx::deposit` passing the amount of CVX and the address to receive the afCvx.

```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
```

### Withdrawing

> [!IMPORTANT] 
> Withdrawal is subjected to a withdrawal fee and weekly withdrawal limit.

To withdraw CVX from the vault first approve afCvx to be burnt by calling `afCvx::approve` function, then call `afCvx::withdraw` passing the amount of CVX to withdraw, the address to receive CVX and the owner of afCvx shares.

```solidity
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
```

Alternatively, `afCvx::redeem` function can be used to redeem afCvx shares for CVX.

```solidity
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
```

### Requesting Unlock

If a user wishes to withdraw more CVX than allowed by the weekly withdrawal limit they can request an unlock. Due to the nature of the underlying `CLeverCVXLocker` contract, assets requested to be unlocked won't be withdrawable immediately but is instead queued up for a later time.

To request unlock call `afCvx::requestUnlock` function passing the amount of CVX to unlock, the address to receive CVX and the owner of afCvx shares.

```solidity
function requestUnlock(uint256 assets, address receiver, address owner)
      external
      returns (uint256 unlockEpoch, uint256 shares)
```

The function returns the epoch number when the shares will be available. 

The requested unlocks information can always be checked by calling `CLeverCvxStrategy::getRequestedUnlocks`

```solidity
function getRequestedUnlocks(address account) external view returns (UnlockRequest[] memory unlocks)
```
> [!IMPORTANT] 
> Request unlock burns the underlying afCvx shares.

### Withdrawing Unlocked

Once the unlock time passed a user can withdraw CVX requested earlier by calling `afCvx::withdrawUnlocked` and passing the address of a receiver that was used to request the unlock.

```solidity
function withdrawUnlocked(address receiver) external
```
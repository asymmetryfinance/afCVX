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
> The harvest function must be called at the beginning of the epoch after Convex, CLever and Furnace rewards distribution.

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

### Depositing

### Withdrawing

### Requesting Unlock

### Withdrawing Unlocked
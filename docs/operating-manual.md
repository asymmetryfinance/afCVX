# Operating Manual

This document outlines how the protocol should be interacted with and maintained. It is divided into three main sections based on the following roles:

- **_admin_** is the highest privileged role responsible for setting the protocol parameters;
- **_operator_** is a privileged role responsible for protocol management tasks, such as harvesting rewards and depositing into strategies;
- **_user_** defines any permissionless actions accessible by anyone.

## Admin

> [!CAUTION]
> In case of an on-going exploit or other emergency invoke the `AfCvx::emergencyShutdown()` method,
> this will pause all deposit/withdrawal functions as well as disable the `CleverCvxStrategy`. Note that
> this method may consume quite a bit of gas.

### Configuring Roles

**Changing the owner (AfCvx and CleverCvxStrategy)**

1. The new owner needs to call `requestOwnershipHandover()` this will request a handover.
2. The current owner will then have 48h to call `completeOwnershipHandover(address newOwner)` to
   confirm the handover.

This process is recommended as it ensures you don't accidentally transfer ownership to a wallet you
don't have control over.

**Changing the operator (AfCvx & CleverCvxStrategy)**

As the owner call `setOperator(address)` with the address of the new operator.

### Configuring Fees

**Changing the protocol fee (AfCvx)**

As the owner call `setProtocolFee(uint16)` with the value representing new protocol fee in basis points. For example, to set the protocol fee to `1%` pass `100` to the function.

**Changing the withdrawal fee (AfCvx)**

As the owner call `setWithdrawalFee(uint16)` with the value representing new withdrawal fee in basis points.

### Configuring Protocol Fee Collector (AfCvx)

To set the address that receives the protocol fee, as the owner call `setProtocolFeeCollector(address)`.

### Configuring the share of assets deposited to Clever CVX Strategy (AfCvx)

The default ratio for assets distribution between Clever CVX Strategy and staked CVX in Convex is 80/20. To change the percentage of Clever CVX Strategy, as the owner call `setCleverCvxStrategyShare(uint16)` with the value representing new share in basis points. For example, to set the share to `75%` pass `7500` to the function. Note, that the share of staked CVX is calculated automatically.

### Configuring Weekly Withdrawal Share (AfCvx)

To set the percentage of total value locked in the protocol that can be withdrawn in one week, as the owner call `setWeeklyWithdrawShare(uint16)` passing the new share in basis points. For example, to set the share to `2%` pass `200` to the function.

## Operator

> [!IMPORTANT]
> The operator must perform system management operations on time to ensure the expected protocol behavior.

### Depositing CVX into Strategies (AfCvx)

To distribute the deposited CVX between Clever CVX Strategy and Convex staking contract, as the operator (or owner) call `distribute` function

```solidity
function distribute(bool swap, uint256 minAmountOut) external
```

with the following parameters:

- `swap` - a boolean flag indicating whether CVX should be swapped on Curve for clevCVX or deposited in Clever Locker.
- `minAmountOut` - a minimum amount of clevCVX to receive after the swap. Only used if `swap` parameter is `true`.

To preview the amounts of CVX that will be deposited to each strategy anyone can call `previewDistribute` view function.

```solidity
function previewDistribute() external view returns (uint256 cleverDepositAmount, uint256 convexStakeAmount)
```

### Harvesting Rewards (AfCvx)

To harvest rewards from the underling strategies as the operator call `harvest` function passing the minimum amount of CVX to receive when swapping cvxCRV to CVX:

```solidity
function harvest(uint256 minAmountOut) external returns (uint256 rewards)
```

> [!IMPORTANT]
> The harvest function must be called at the beginning of the epoch after Clever and Furnace distribution

To get the amount of cvxCRV earned by the protocol call `earned` function in Convex [CVXRewardsPool](https://etherscan.io/address/0xCF50b810E57Ac33B91dCF525C6ddd9881B139332#readContract) contract passing afCVX contract address

```solidity
function earned(address account) external view returns (uint256);
```

Then use Curve UI or API to determine the minimum amount of CVX that can be received when swapping clevCVX

> [!IMPORTANT]
> The harvested rewards are not automatically redeposited. To deposit CVX to the underlying CVX call `distribute` function after harvesting.

### Borrowing clevCVX and depositing to Furnace (CleverCvxStrategy)

If `distribute` function locks CVX in Clever Locker contract (`swap` parameter is set to `false`), the operator must call `borrow` in CleverCvxStrategy contract after calling `distribute`.

> [!NOTE]
> `borrow` is implemented as a stand-alone function because `CleverCvxLocker` contract doesn't allow depositing and borrowing in the same block.


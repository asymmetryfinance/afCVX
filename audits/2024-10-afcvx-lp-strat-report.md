<table>
    <tr>
        <th colspan="2">
            <img src="https://raw.githubusercontent.com/romeroadrian/audits/main/images/banner.png" width="800"/>
        </th>
    </tr>
    <tr>
        <td align="center"><img src="https://www.asymmetry.finance/images/afcvx/afcvx_btn1.svg" width="200" height="200" align="center"/></td>
        <td>
            <h1>Asymmetry Finance Report</h1>
            <h2>afCVX</h2>
            <p>Conducted by: adriro (<a href="https://twitter.com/adrianromero">@adrianromero</a>)</p>
            <p>Date: Oct 19 to 22, 2024</p>
        </td>
    </tr>
</table>

# afCVX Security Review

## Disclaimer

_The conducted security review represents an evaluation based on the information and code provided by the client. The author, employing a combination of automated tools and manual expertise, has endeavored to identify potential vulnerabilities. It is crucial to understand that this review does not ensure the absolute absence of vulnerabilities or errors within the smart contracts._

_Despite exercising due diligence, this assessment may not uncover all potential issues or undiscovered vulnerabilities present in the code. Findings and recommendations are based solely on the information available at the time of the review._

_This report is not to be considered as an endorsement or certification of the smart contract's absolute security. Authors cannot assume responsibility for any losses or damages that may arise from the utilization of the smart contracts._

_While this assessment aims to identify vulnerabilities, it cannot guarantee absolute security or eliminate all potential risks associated with smart contract usage._

## About afCVX

[afCVX](https://medium.com/@asymmetryfin/introducing-afcvx-fb744bd24d85) is a new protocol by Asymmetry Finance built to maximize yield on CVX tokens. The design works as a hybrid CVX wrapper, in which a share of the tokens remain liquid in the Convex staking rewards pool, while the rest is deposited at CLever CVX, a protocol that enables CVX locking with the option to leverage on future yield. Rewards coming from both of these underlying platforms are compounded back into the protocol.

## About adriro

adriro is an independent security researcher currently focused on security reviews of smart contracts. He is a top warden at [code4rena](https://code4rena.com/) and serves as a resident auditor at [yAudit](https://yaudit.dev/).

You can follow him on X at [@adrianromero](https://x.com/adrianromero) or browse his [portfolio](https://github.com/romeroadrian/audits).

## Scope

The scope for the current review targets the new LP strategy feature present in the [`lp-strat`](https://github.com/asymmetryfinance/afCVX/pull/12) branch  at revision [f039e4e158fda550c89e9945b4c8a410a7970b48](https://github.com/asymmetryfinance/afCVX/tree/f039e4e158fda550c89e9945b4c8a410a7970b48) and includes the following files:

```
src
├── AfCvx.sol
├── interfaces
│   ├── asymmetry
│   │   ├── ICleverStrategy.sol
│   │   └── ILPStrategy.sol
│   ├── convex
│   │   ├── IConvexBooster.sol
│   │   └── IConvexRewardsPool.sol
│   └── curve
│       └── ICurvePool.sol
├── strategies
│   ├── CLeverCVXStrategy.sol
│   └── LPStrategy.sol
└── utils
    ├── Zap.sol
    └── interfaces
        └── ICurveCryptoPool.sol
```

## Summary

| Identifier | Title | Severity | Status |
| ---------- | ----- | ---------| ------ |
| [I-1](#i-1-confusing-semantics-of-swap-and-lp-percentages-during-distribution) | Confusing semantics of swap and LP percentages during distribution | Informational | Fixed |
| [G-1](#g-1-change-convex-rewards-to-constant) | Change `CONVEX_REWARDS` to constant | Gas | Fixed |

## Critical Findings

None.

## High Findings

None.

## Medium Findings

None.

## Low Findings

None.

## Informational Findings

### <a name="I-1"></a>[I-1] Confusing semantics of swap and LP percentages during distribution

The [`distribute()`](https://github.com/asymmetryfinance/afCVX/blob/f039e4e158fda550c89e9945b4c8a410a7970b48/src/AfCvx.sol#L267) function now takes a `_lpPercentage` argument in addition to the existing `_swapPercentage`.

This new argument controls the portion of the deposited assets into the CLever strategy that should be allocated to the LP. 

```solidity
170:         uint256 _lpAmount;
171:         if (_lpPercentage > 0) {
172:             _lpAmount = _assets * _lpPercentage / PRECISION;
173:             _assets -= _lpAmount;
174:         }
175: 
176:         uint256 _swapAmount;
177:         uint256 _lockerAmount = _assets;
178:         if (_assets > 0 && _swapPercentage > 0) {
179:             _swapAmount = _assets * _swapPercentage / PRECISION;
180:             _lockerAmount = _assets - _swapAmount;
181:         }
182: 
183:         if (_lpAmount > 0) CVX.safeTransfer(address(lpStrategy), _lpAmount);
184:         if (_swapAmount > 0) FURNACE.deposit(Zap.swapCvxToClevCvx(_swapAmount, _minAmountOut));
185:         if (_lockerAmount > 0) CLEVER_CVX_LOCKER.deposit(_lockerAmount);
186: 
187:         emit Deposited(_assets, _swapAmount, _lockerAmount, _lpAmount);
```

When `_lpPercentage > 0`, the calculated `_lpAmount` is then subtracted to the total `_assets`. This means that `_swapPercentage` will be applied to the portion left after assigning the LP assets. For example, if LP percentage is 50% and swap percentage is 25%, the final swap amount will be 12.5% in relation to the total.

Additionally, note that by modifying the `_assets` variable, the `Deposited` event (line 187) could be emitted using the wrong number of total assets, as the portion that goes to the LP has been deducted from this variable (line 173).

## Gas Findings

### <a name="G-1"></a>[G-1] Change `CONVEX_REWARDS` to constant

In the LPStrategy contract, the variable [`CONVEX_REWARDS`](https://github.com/asymmetryfinance/afCVX/blob/f039e4e158fda550c89e9945b4c8a410a7970b48/src/strategies/LPStrategy.sol#L34) can be converted from immutable to constant, as the address is resolved at compile time.

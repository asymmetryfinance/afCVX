// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Ownable } from "solady/auth/Ownable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { TrackedAllowances, Allowance } from "../utils/TrackedAllowances.sol";
import { ICLeverCVXLocker, CLEVER_CVX_LOCKER } from "../interfaces/clever/ICLeverCVXLocker.sol";
import { IFurnace, FURNACE } from "../interfaces/clever/IFurnace.sol";
import { CVX } from "../interfaces/convex/Constants.sol";
import { CLEVCVX } from "../interfaces/clever/Constants.sol";
import { ICVXclevCVXPool, CVX_CLEVCVX_POOL, CVX_INDEX, CLEVCVX_INDEX } from "../interfaces/curve/ICVXclevCVXPool.sol";

contract CLeverCVXStrategy is TrackedAllowances, Ownable {
    using SafeTransferLib for address;

    /// @dev The denominator used for CLever fee calculation.
    uint256 private constant CLEVER_FEE_PRECISION = 1e9;

    /// @dev We assume that clevCVX/CVX pool on Curve is balanced if clevCVX/CVX = 0.97
    uint256 private constant CVX_CLEVCVX_POOL_PEG_RATIO = 97;
    uint256 private constant PEG_RATIO_PRECISION = 100;

    /// @dev Acceptable slippage in CVX/clevCVX pool is 0.1%
    uint256 private constant CVX_CLEVCVX_POOL_SLIPPAGE = 1;
    uint256 private constant SLIPPAGE_PRECISION = 1000;

    uint256 REWARDS_DURATION = 1 weeks;

    error NothingToClaim();
    error InsufficientOutput();

    /// @dev Tracks the total amount of CVX unlock obligations the contract has ever had.
    uint256 internal cumulativeCvxUnlockObligations;
    /// @dev Tracks the total amount of CVX that has ever been unlocked.
    uint256 internal cumulativeCvxUnlocked;

    mapping(address account => mapping(uint256 unlockEpoch => uint256 amount)) public withdrawableAfterUnlocked;

    constructor() {
        // Approve once to save gas later by avoiding having to re-approve every time.
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CVX_CLEVCVX_POOL), token: address(CVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(FURNACE), token: address(CLEVCVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CLEVER_CVX_LOCKER), token: address(CLEVCVX) }));
    }

    function getObligations()
        public
        view
        returns (uint256 cumCvxUnlocked, uint256 cumCvxUnlockObligations, uint256 totalUnlockObligations)
    {
        cumCvxUnlocked = cumulativeCvxUnlocked;
        cumCvxUnlockObligations = cumulativeCvxUnlockObligations;
        totalUnlockObligations = cumCvxUnlockObligations - cumCvxUnlocked;
    }

    /// @notice locks CVX on CLever, borrows clevCVX, and deposits it on Furnance
    /// @param _amount amount of CVX tokens to deposit
    function deposit(uint256 _amount) external {
        _lockCVXAndBorrowClevCVX(_amount);
    }

    /// @notice requests to unlock CVX
    function requestWithdraw(uint256 _amount, address _to)
        external
        returns (uint256 receivedCVX, uint256 unlockEpoch)
    {
        (uint256 unreleased, uint256 realised) = FURNACE.getUserInfo(address(this));
        if (realised > 0) {
            FURNACE.claim(address(this));
        }
        (,, uint256 totalUnlockObligations) = getObligations();
        uint256 availableCVX = CVX.balanceOf(address(this)) - totalUnlockObligations;

        if (availableCVX >= _amount) {
            // withdrawal is fully fulfilled from available CVX
            receivedCVX = _amount;
            unlockEpoch = 0;
        } else {
            uint256 requiredCVX = _amount - availableCVX;

            // If clevCVX is pegged to CVX withdraw clevCVX from Furnace and buy CVX
            uint256 amountIn = _getAmountClevCVXIn(_amount);
            if (_clevCVXPegged(requiredCVX, amountIn) && unreleased > amountIn) {
                receivedCVX = _withdrawClevCVXAndBuyCVX(amountIn, requiredCVX) + availableCVX;
                unlockEpoch = 0;
            } else {
                receivedCVX = availableCVX;
                unlockEpoch = _repayAndRequestUnlock(requiredCVX);
                cumulativeCvxUnlockObligations += requiredCVX;
                withdrawableAfterUnlocked[_to][unlockEpoch] += requiredCVX;
            }
        }

        if (receivedCVX > 0) {
            address(CVX).safeTransfer(_to, receivedCVX);
        }
    }

    /// @notice withdraws unlocked CVX
    function withdrawUnlocked() external {
        uint256 currentEpoch = block.timestamp / REWARDS_DURATION;
        uint256 withdrawableCVX = withdrawableAfterUnlocked[msg.sender][currentEpoch];
        if (withdrawableCVX == 0) return;

        uint256 availableCVX = CVX.balanceOf(address(this));

        if (availableCVX < withdrawableCVX) {
            (,, uint256 totalUnlocked,,) = CLEVER_CVX_LOCKER.getUserInfo(address(this));
            if (totalUnlocked > 0) {
                CLEVER_CVX_LOCKER.withdrawUnlocked();
                cumulativeCvxUnlocked += totalUnlocked;
            }
        }

        delete withdrawableAfterUnlocked[msg.sender][currentEpoch];
        cumulativeCvxUnlocked = availableCVX + withdrawableCVX;

        address(CVX).safeTransfer(msg.sender, withdrawableCVX);
    }

    function _withdrawClevCVXAndBuyCVX(uint256 _amountIn, uint256 _minAmountOut) private returns (uint256 amountOut) {
        uint256 availableClevCVX = CLEVCVX.balanceOf(address(this));
        // add 0.1% slippage
        uint256 requiredClevCVX = _amountIn * (SLIPPAGE_PRECISION + CVX_CLEVCVX_POOL_SLIPPAGE) / SLIPPAGE_PRECISION;
        if (availableClevCVX < requiredClevCVX) {
            FURNACE.withdraw(address(this), requiredClevCVX - availableClevCVX);
        }

        return _buyCVX(requiredClevCVX, _minAmountOut);
    }

    function _repayAndRequestUnlock(uint256 requiredCVX) private returns (uint256 unlockEpoch) {
        uint256 availableClevCVX = CLEVCVX.balanceOf(address(this));
        uint256 clevCVXToRepay = _calculateRepayAmount(requiredCVX);
        if (availableClevCVX < clevCVXToRepay) {
            FURNACE.withdraw(address(this), clevCVXToRepay - availableClevCVX);
        }
        // repay the dept
        CLEVER_CVX_LOCKER.repay(0, clevCVXToRepay);
        // request the unlock
        CLEVER_CVX_LOCKER.unlock(requiredCVX);
        ICLeverCVXLocker.UserInfo memory userInfo = CLEVER_CVX_LOCKER.userInfo(address(this));
        uint256 pendingUnlockListLength = userInfo.pendingUnlockList.length;
        unlockEpoch = userInfo.pendingUnlockList[pendingUnlockListLength - 1].unlockEpoch;
    }

    /// @notice claims CVX rewards from Furnance, then either buys clevCVX on Curve or borrow it on CLever,
    /// and finally deposit clevCVX it on Furnance
    /// @dev should be called every Epoch after the rewards are harvested on Furnance
    function compoundRewards() external {
        uint256 claimedCVX = _claimCVXRewards();
        if (claimedCVX == 0) revert NothingToClaim();

        // check if CVX can be swapped for clevCVX with a discount
        _redepositCVX(claimedCVX);
    }

    /// @notice claims CVX rewards from Furnance
    /// @return amount of claimed CVX tokens
    function _claimCVXRewards() private returns (uint256) {
        (, uint256 realised) = FURNACE.getUserInfo(address(this));
        if (realised == 0) return 0;

        FURNACE.claim(address(this));
        return CVX.balanceOf(address(this));
    }

    function _redepositCVX(uint256 _amount) private {
        // check if CVX can be swapped for clevCVX with a discount
        uint256 amountClevCVXOut = _getAmounClevCVXOut(_amount);
        if (!_clevCVXPegged(_amount, amountClevCVXOut)) {
            // sell CVX for clevCVX on Curve
            uint256 minAmountOut =
                amountClevCVXOut * (SLIPPAGE_PRECISION - CVX_CLEVCVX_POOL_SLIPPAGE) / SLIPPAGE_PRECISION;
            amountClevCVXOut = _sellCVX(_amount, minAmountOut);
            // deposit clevCVX on Furnance
            FURNACE.deposit(amountClevCVXOut);
        } else {
            // if the pool is balanced, lock CVX on CLever,
            // borrow maximum amount of clevCVX and deposit it on Furnance
            _lockCVXAndBorrowClevCVX(_amount);
        }
    }

    /// @notice locks CVX on CLever, borrows maximun amount of clevCVX and deposit it on Furnance
    /// @param _amount amount of CVX tokens to lock
    function _lockCVXAndBorrowClevCVX(uint256 _amount) private {
        CLEVER_CVX_LOCKER.deposit(_amount);
        CLEVER_CVX_LOCKER.borrow(_calculateMaxBorrowAmount(), true);
    }

    function _sellCVX(uint256 _amountIn, uint256 _minAmountOut) private returns (uint256) {
        return CVX_CLEVCVX_POOL.exchange(CVX_INDEX, CLEVCVX_INDEX, _amountIn, _minAmountOut, address(this));
    }

    function _buyCVX(uint256 _amountIn, uint256 _minAmountOut) private returns (uint256) {
        return CVX_CLEVCVX_POOL.exchange(CLEVCVX_INDEX, CVX_INDEX, _amountIn, _minAmountOut, address(this));
    }

    function _getAmounClevCVXOut(uint256 _amountIn) private view returns (uint256 amountOut) {
        amountOut = CVX_CLEVCVX_POOL.get_dy(CVX_INDEX, CLEVCVX_INDEX, _amountIn);
    }

    function _getAmountClevCVXIn(uint256 _amountOut) private view returns (uint256 amountIn) {
        // calculate amountIn by amountOut as Curve PlainPool contract doesn't have get_dx function
        // TODO: refactor with more accurate calculations or use CurveRouter
        // https://github.com/curvefi/curve-router-ng/blob/master/contracts/Router.vy
        // https://etherscan.io/address/0xF0d4c12A5768D806021F80a262B4d39d26C58b8D#code
        uint256 clevCVXIn = _amountOut;
        uint256 cvxOut = CVX_CLEVCVX_POOL.get_dy(CLEVCVX_INDEX, CVX_INDEX, clevCVXIn);
        amountIn = clevCVXIn * _amountOut / cvxOut;
    }

    function _clevCVXPegged(uint256 _amountCVX, uint256 _amountClevCVX) private pure returns (bool) {
        return _amountCVX * PEG_RATIO_PRECISION / _amountClevCVX >= CVX_CLEVCVX_POOL_PEG_RATIO;
    }

    function _calculateMaxBorrowAmount() private view returns (uint256) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        ICLeverCVXLocker.UserInfo memory userInfo = CLEVER_CVX_LOCKER.userInfo(address(this));
        return userInfo.totalLocked * reserveRate / CLEVER_FEE_PRECISION - userInfo.totalDebt;
    }

    function _calculateRepayAmount(uint256 _lockedCVX) private view returns (uint256) {
        uint256 reserveRate = CLEVER_CVX_LOCKER.reserveRate();
        return _lockedCVX * reserveRate / CLEVER_FEE_PRECISION;
    }
}

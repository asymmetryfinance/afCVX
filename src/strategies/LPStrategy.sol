// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILPStrategy} from "../interfaces/asymmetry/ILPStrategy.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";

import {Allowance, TrackedAllowances} from "../utils/TrackedAllowances.sol";

contract LPStrategy is ILPStrategy, TrackedAllowances, Ownable, UUPSUpgradeable {

    using SafeERC20 for IERC20;

    address public immutable afCVX;
    address public immutable cleverStrategy;

    uint256 private constant COIN0 = 0; // CVX
    uint256 private constant COIN1 = 1; // clevCVX

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CLEVCVX = IERC20(0xf05e58fCeA29ab4dA01A495140B349F8410Ba904);

    ICurvePool public constant LP = ICurvePool(0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(address _afCVX, address _cleverStrategy) {
        if  (_afCVX == address(0) || _cleverStrategy == address(0)) revert ZeroAddress();
        _disableInitializers();
        afCVX = _afCVX;
        cleverStrategy = _cleverStrategy;
    }

    function initialize() external initializer {
        Allowance memory _allowance = Allowance({ spender: address(LP), token: address(CVX) });
        _grantAndTrackInfiniteAllowance(_allowance);
        _allowance.token = address(CLEVCVX);
        _grantAndTrackInfiniteAllowance(_allowance);
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    function totalAssets() external view returns (uint256) {
        uint256[2] memory _balances = LP.get_balances();
        return
            CVX.balanceOf(address(this))
            + (LP.balanceOf(address(this)) * (_balances[COIN0] + _balances[COIN1]) / LP.totalSupply()); // assuming clevCVX == CVX
    }

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function addLiquidity(
        uint256 _cvxAmount,
        uint256 _clevCvxAmount,
        uint256 _minAmountOut
    ) external onlyCLeverStrategy returns (uint256) {
        if (_cvxAmount == 0 && _clevCvxAmount == 0) revert ZeroAmount();

        uint256[2] memory _amounts;
        _amounts[COIN0] = _cvxAmount;
        _amounts[COIN1] = _clevCvxAmount
;
        return LP.add_liquidity(_amounts, _minAmountOut);
    }

    function removeLiquidityOneCoin(
        uint256 _burnAmount,
        uint256 _minAmountOut,
        bool _isCVX
    ) external onlyCLeverStrategy returns (uint256) {
        if (_burnAmount == 0) revert ZeroAmount();
        return LP.remove_liquidity_one_coin(
            _burnAmount,
            _isCVX ? int128(int256(COIN0)) : int128(int256(COIN1)),
            _minAmountOut,
            cleverStrategy
        );
    }

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    function sendCVXBackToVault(uint256 _amount) external {
        CVX.safeTransfer(afCVX, _amount);
    }

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

    // ============================================================================================
    // Modifiers
    // ============================================================================================

    modifier onlyCLeverStrategy() {
        if (msg.sender != cleverStrategy) revert Unauthorized();
        _;
    }

    // ============================================================================================
    // Errors
    // ============================================================================================

    error ZeroAmount();
    error ZeroAddress();
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    function add_liquidity(uint256[2] memory _amounts, uint256 _min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 _burn_amount, int128 i, uint256 _min_received) external returns (uint256);
    function get_balances() external view returns (uint256[2] memory);
    function balanceOf(address _account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

library LPStrategy {

    using SafeERC20 for IERC20;

    uint256 private constant COIN0 = 0; // CVX
    uint256 private constant COIN1 = 1; // clevCVX

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CLEVCVX = IERC20(0xf05e58fCeA29ab4dA01A495140B349F8410Ba904);

    ICurvePool public constant LP = ICurvePool(0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6);

    // ============================================================================================
    // View functions
    // ============================================================================================

    function totalAssets() external view returns (uint256) {
        uint256[2] memory _balances = LP.get_balances();
        return LP.balanceOf(address(this)) * (_balances[COIN0] + _balances[COIN1]) / LP.totalSupply(); // assuming clevCVX == CVX
    }

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function deposit(uint256 _cvxAmount, uint256 _clevCvxAmount, uint256 _minAmountOut) external {
        if (_cvxAmount == 0 && _clevCvxAmount == 0) revert ZeroAmount();

        if (_cvxAmount > 0) CVX.forceApprove(address(LP), _cvxAmount);
        if (_clevCvxAmount > 0) CLEVCVX.forceApprove(address(LP), _clevCvxAmount);

        uint256[2] memory _amounts;
        _amounts[COIN0] = _cvxAmount;
        _amounts[COIN1] = _clevCvxAmount
;
        LP.add_liquidity(_amounts, _minAmountOut);
    }

    function withdraw(uint256 _burnAmount, uint256 _minAmountOut) external returns (uint256) {
        if (_burnAmount == 0) revert ZeroAmount();
        return LP.remove_liquidity_one_coin(_burnAmount, int128(int256(COIN1)), _minAmountOut);
    }

    // ============================================================================================
    // Errors
    // ============================================================================================

    error ZeroAmount();
}
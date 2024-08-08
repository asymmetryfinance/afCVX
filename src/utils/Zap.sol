// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveFactoryPlainPool} from "./interfaces/ICurveFactoryPlainPool.sol";
import {ICurveCryptoPool} from "./interfaces/ICurveCryptoPool.sol";

library Zap {

    using SafeERC20 for IERC20;

    IERC20 private constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CVXCRV = IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    ICurveCryptoPool public constant CRV_ETH_POOL = ICurveCryptoPool(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);
    ICurveCryptoPool private constant CVX_ETH_POOL = ICurveCryptoPool(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);

    ICurveFactoryPlainPool private constant CVXCRV_CRV_POOL = ICurveFactoryPlainPool(0x971add32Ea87f10bD192671630be3BE8A11b8623);
    ICurveFactoryPlainPool private constant CVX_CLEVCVX_POOL = ICurveFactoryPlainPool(0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6);

    function swapCvxToClevCvx(uint256 cvxAmount, uint256 minAmountOut) external returns (uint256) {
        CVX.forceApprove(address(CVX_CLEVCVX_POOL), cvxAmount);
        return CVX_CLEVCVX_POOL.exchange(0, 1, cvxAmount, minAmountOut);
    }

    function swapCvxCrvToCvx(uint256 _cvxCrvAmount, uint256 _minAmountOut) external returns (uint256) {

        // cvxCRV -> CRV
        CVXCRV.forceApprove(address(CVXCRV_CRV_POOL), _cvxCrvAmount);
        uint256 _crvAmount = CVXCRV_CRV_POOL.exchange(1, 0, _cvxCrvAmount, 0);

        // CRV -> ETH
        CRV.forceApprove(address(CRV_ETH_POOL), _crvAmount);
        uint256 _ethAmount = CRV_ETH_POOL.exchange_underlying(2, 1, _crvAmount, 0);

        // ETH -> CVX
        return CVX_ETH_POOL.exchange_underlying{ value: _ethAmount }(0, 1, _ethAmount, _minAmountOut);
    }
}

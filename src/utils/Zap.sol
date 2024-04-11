// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

interface ICurveFactoryPlainPool {
    function price_oracle() external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

interface ICurveCryptoPool {
    function price_oracle(uint256 index) external view returns (uint256);
    function exchange_underlying(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

library Zap {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    address constant CVXCRV = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    address constant CVXCRV_CRV_POOL = 0x971add32Ea87f10bD192671630be3BE8A11b8623;
    address constant CRV_ETH_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    address constant CVX_ETH_POOL = 0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4;
    address constant CVX_CLEVCVX_POOL = 0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6;

    function swapCvxToClevCvx(uint256 cvxAmount, uint256 minAmountOut) external returns (uint256) {
        CVX.safeApprove(CVX_CLEVCVX_POOL, cvxAmount);
        return ICurveFactoryPlainPool(CVX_CLEVCVX_POOL).exchange(0, 1, cvxAmount, minAmountOut);
    }

    function swapCvxCrvToCvx(uint256 cvxCrvAmount, uint256 minAmountOut) external returns (uint256) {
        // cvxCRV -> CRV
        CVXCRV.safeApprove(CVXCRV_CRV_POOL, cvxCrvAmount);
        uint256 crvAmount = ICurveFactoryPlainPool(CVXCRV_CRV_POOL).exchange(1, 0, cvxCrvAmount, 0);

        // CRV -> ETH
        CRV.safeApprove(CRV_ETH_POOL, crvAmount);
        uint256 ethAmount = ICurveCryptoPool(CRV_ETH_POOL).exchange_underlying(2, 1, crvAmount, 0);

        // ETH -> CVX
        return ICurveCryptoPool(CVX_ETH_POOL).exchange_underlying{ value: ethAmount }(0, 1, ethAmount, minAmountOut);
    }

    function convertCvxCrvToCvx(uint256 cvxCrvAmount) external view returns (uint256) {
        // cvxCRV -> CRV
        uint256 crvAmount = cvxCrvAmount.mulWad(ICurveFactoryPlainPool(CVXCRV_CRV_POOL).price_oracle());

        // CRV -> ETH
        uint256 ethUsdPrice = ICurveCryptoPool(CRV_ETH_POOL).price_oracle(0);
        uint256 crvUsdPrice = ICurveCryptoPool(CRV_ETH_POOL).price_oracle(1);
        uint256 ethAmount = crvUsdPrice * crvAmount / ethUsdPrice;

        // ETH -> CVX
        return ethAmount.divWad(ICurveFactoryPlainPool(CVX_ETH_POOL).price_oracle());
    }
}

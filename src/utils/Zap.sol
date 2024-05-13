// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { CVX, CVXCRV } from "src/interfaces/convex/Constants.sol";

// solhint-disable func-name-mixedcase, var-name-mixedcase
interface ICurveFactoryPlainPool {
    function price_oracle() external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

interface ICurveCryptoPool {
    function price_oracle(uint256 index) external view returns (uint256);
    function exchange_underlying(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}
// solhint-enable func-name-mixedcase, var-name-mixedcase

library Zap {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    IERC20 internal constant CRV = IERC20(address(0xD533a949740bb3306d119CC777fa900bA034cd52));

    address internal constant CVXCRV_CRV_POOL = 0x971add32Ea87f10bD192671630be3BE8A11b8623;
    address internal constant CRV_ETH_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    address internal constant CVX_ETH_POOL = 0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4;
    address internal constant CVX_CLEVCVX_POOL = 0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6;

    function swapCvxToClevCvx(uint256 cvxAmount, uint256 minAmountOut) external returns (uint256) {
        CVX.forceApprove(CVX_CLEVCVX_POOL, cvxAmount);
        return ICurveFactoryPlainPool(CVX_CLEVCVX_POOL).exchange(0, 1, cvxAmount, minAmountOut);
    }

    function swapCvxCrvToCvx(uint256 cvxCrvAmount, uint256 minAmountOut) external returns (uint256) {
        // cvxCRV -> CRV
        CVXCRV.forceApprove(CVXCRV_CRV_POOL, cvxCrvAmount);
        uint256 crvAmount = ICurveFactoryPlainPool(CVXCRV_CRV_POOL).exchange(1, 0, cvxCrvAmount, 0);

        // CRV -> ETH
        CRV.forceApprove(CRV_ETH_POOL, crvAmount);
        uint256 ethAmount = ICurveCryptoPool(CRV_ETH_POOL).exchange_underlying(2, 1, crvAmount, 0);

        // ETH -> CVX
        return ICurveCryptoPool(CVX_ETH_POOL).exchange_underlying{ value: ethAmount }(0, 1, ethAmount, minAmountOut);
    }
}

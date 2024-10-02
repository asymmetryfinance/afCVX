// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILPStrategy} from "../interfaces/asymmetry/ILPStrategy.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {IConvexRewardsPool} from "../interfaces/convex/IConvexRewardsPool.sol";
import {IConvexBooster} from "../interfaces/convex/IConvexBooster.sol";

import {Allowance, TrackedAllowances} from "../utils/TrackedAllowances.sol";

contract LPStrategy is ILPStrategy, TrackedAllowances, Ownable, UUPSUpgradeable {

    using SafeERC20 for IERC20;

    // bool public dump; // @todo - export swapping to Zap.sol

    uint256 public constant CONVEX_PID = 139;

    uint256 private constant COIN0 = 0; // CVX
    uint256 private constant COIN1 = 1; // clevCVX

    address public constant AFCVX = 0x8668a15b7b023Dc77B372a740FCb8939E15257Cf;
    address public constant CLEVER_STRATEGY = 0xB828a33aF42ab2e8908DfA8C2470850db7e4Fd2a;

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CLEVCVX = IERC20(0xf05e58fCeA29ab4dA01A495140B349F8410Ba904);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);

    ICurvePool public constant LP = ICurvePool(0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6);
    ICurvePool public constant TRICRV = ICurvePool(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);
    ICurvePool public constant CVXWETH = ICurvePool(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);

    IConvexBooster public constant CONVEX_BOOSTER = IConvexBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IConvexRewardsPool public immutable CONVEX_REWARDS = IConvexRewardsPool(0x706f34D0aB8f4f9838F15b0D155C8Ef42229294B);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        _initializeOwner(_owner);
        __UUPSUpgradeable_init();
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(LP), token: address(CVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(LP), token: address(CLEVCVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CONVEX_BOOSTER), token: address(LP) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(TRICRV), token: address(CRV) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CVXWETH), token: address(WETH) }));
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the total assets under management
    /// @dev Assumes that clevCVX == CVX, because we can redeem clevCVX for CVX using the cleverStrategy
    /// @return The total assets under management
    function totalAssets() external view returns (uint256) {
        uint256[2] memory _balances = LP.get_balances();
        return
            CVX.balanceOf(address(this))
            + (CONVEX_REWARDS.balanceOf(address(this)) * (_balances[COIN0] + _balances[COIN1]) / LP.totalSupply());
    }

    // function pendingRewards() external view returns (uint256) {
    //     return CONVEX_REWARDS.earned(address(this));
    // } // @todo

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    /// @notice Adds liquidity to the clevCVX/CVX Curve pool
    /// @param _cvxAmount The amount of CVX to add
    /// @param _clevCvxAmount The amount of clevCVX to add
    /// @param _minAmountOut The minimum amount of LP tokens to receive
    /// @return _amount The amount of LP tokens received
    function addLiquidity(
        uint256 _cvxAmount,
        uint256 _clevCvxAmount,
        uint256 _minAmountOut
    ) external onlyCLeverStrategy returns (uint256 _amount) {
        if (_cvxAmount == 0 && _clevCvxAmount == 0) revert ZeroAmount();

        uint256[2] memory _amounts;
        _amounts[COIN0] = _cvxAmount;
        _amounts[COIN1] = _clevCvxAmount
;
        _amount = LP.add_liquidity(_amounts, _minAmountOut);
        _stake(_amount);
    }

    /// @notice Removes liquidity from the clevCVX/CVX Curve pool
    /// @param _burnAmount The amount of LP tokens to burn
    /// @param _minAmountOut The minimum amount of CVX and clevCVX to receive
    /// @param _isCVX Whether to remove CVX or clevCVX
    /// @return The amounts of CVX and clevCVX received
    function removeLiquidityOneCoin(
        uint256 _burnAmount,
        uint256 _minAmountOut,
        bool _isCVX
    ) external onlyCLeverStrategy returns (uint256) {
        if (_burnAmount == 0) revert ZeroAmount();

        _unstake(_burnAmount);

        return LP.remove_liquidity_one_coin(
            _burnAmount,
            _isCVX ? int128(int256(COIN0)) : int128(int256(COIN1)),
            _minAmountOut,
            _isCVX ? AFCVX : CLEVER_STRATEGY
        );
    }

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    /// @notice Sweeps idle assets to the owner
    /// @dev If the token is CVX, it will be sent to the afCVX
    /// @param _amount The amount of tokens to sweep
    /// @param _token The token to sweep
    function sweep(uint256 _amount, address _token) external onlyOwner {
        _token == address(CVX) ? CVX.safeTransfer(AFCVX, _amount) : IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /// @notice Claims rewards from the Convex staking pool and swap CRV for CVX
    /// @dev Rewards are sent to this contract, and can be swept by the owner
    /// @dev Should be called using a private RPC to avoid sandwich attacks
    /// @param _minAmount The minimum amount of CVX to receive from CRV rewards
    function claimRewards(uint256 _minAmount) external onlyOwner {
        CONVEX_REWARDS.getReward(
            address(this),
            true // claimExtras
        );

        _dump(); // potential rewards in other tokens can be swept by the owner and reinvested manually
    }

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

    // ============================================================================================
    // Modifiers
    // ============================================================================================

    modifier onlyCLeverStrategy() {
        if (msg.sender != CLEVER_STRATEGY) revert Unauthorized();
        _;
    }

    // ============================================================================================
    // Private functions
    // ============================================================================================

    /// @notice Stakes LP tokens in the Convex staking pool
    /// @param _amount The amount of LP tokens to stake
    function _stake(uint256 _amount) private {
        CONVEX_BOOSTER.deposit(
            CONVEX_PID,
            _amount,
            true // deposit + stake
        );
    }

    /// @notice Unstakes LP tokens from the Convex staking pool
    /// @param _amount The amount of LP tokens to unstake
    function _unstake(uint256 _amount) private {
        CONVEX_REWARDS.withdrawAndUnwrap(
            _amount,
            false // claim rewards
        );
    }

    /// @notice Swaps CRV for CVX
    function _dump() private {

        // triCRV (CRV -> WETH)
        uint256 _triCRV = TRICRV.exchange(0, 2, TRICRV.balanceOf(address(this)), 0);
        // CVX/WETH (WETH -> CVX)
        CVXWETH.exchange(1, 0, IERC20(WETH).balanceOf(address(this)), 0);
    }

    // ============================================================================================
    // Errors
    // ============================================================================================

    error ZeroAmount();
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IPirexLiquidityPool, _CVX, _PX_CVX} from "./interfaces/pirex/IPirexLiquidityPool.sol";
import {IPirexCVX} from "./interfaces/pirex/IPirexCVX.sol";

contract PirexMigrator is ERC1155Holder {

    using SafeERC20 for IERC20;

    uint256 public constant FROM_INDEX = 1; // lpxCVX
    uint256 public constant TO_INDEX = 0; // CVX

    IERC20 public constant CVX = IERC20(_CVX);
    IERC20 public constant PX_CVX = IERC20(_PX_CVX);

    IERC1155 public constant UPX_CVX = IERC1155(0x7A3D81CFC5A942aBE9ec656EFF818f7daB4E0Fe1);

    IERC4626 public constant UNION_CVX = IERC4626(0x8659Fc767cad6005de79AF65dAfE4249C57927AF);
    IERC4626 public constant ASYMMETRY_CVX = IERC4626(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); // TODO

    IPirexCVX public constant PIREX_CVX = IPirexCVX(0x35A398425d9f1029021A92bc3d2557D42C8588D7);
    IPirexLiquidityPool public constant PIREX_LP = IPirexLiquidityPool(0x389fB29230D02e67eB963C1F5A00f2b16f95BEb7);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor() {
        CVX.forceApprove(address(ASYMMETRY_CVX), type(uint256).max);
        PX_CVX.forceApprove(address(PIREX_LP), type(uint256).max);
        // PX_CVX.forceApprove(address(PIREX_CVX), type(uint256).max); // TODO
        UPX_CVX.setApprovalForAll(address(PIREX_CVX), true);
    }

    // ============================================================================================
    // External functions
    // ============================================================================================

    /// @notice Migrate uCVX/pxCVX to afCVX
    /// @dev Migration using a swap will result in the `_receiver` receiving afCVX tokens immidiately
    ///      Migration not using a swap will result in the `_receiver` receiving upxCVX ERC1155 tokens
    ///      upxCVX can be redeemed for CVX and deposited into afCVX once the unlock time has passed using the other `migrate` function
    /// @param _amount Amount of uCVX/pxCVX
    /// @param _minSwapReceived Minimum amount of CVX to receive from the swap. Only used if `_isSwap` is true
    /// @param _lockIndex Locked balance index
    /// @param _receiver Receives of afCVX or upxCVX tokens
    /// @param _isUnionized True if the user is migrating from uCVX, false if the user is migrating from pxCVX
    /// @param _isSwap True if the user wants to swap uCVX/pxCVX for CVX, false if the user wants to redeem uCVX/pxCVX for upxCVX
    function migrate(
        uint256 _amount,
        uint256 _minSwapReceived,
        uint256 _lockIndex,
        address _receiver,
        bool _isUnionized,
        bool _isSwap
    ) external returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        if (_receiver == address(0)) revert ZeroAddress();

        if (_isUnionized) {
            _amount = UNION_CVX.redeem(_amount, address(this), msg.sender);
        } else {
            PX_CVX.safeTransferFrom(msg.sender, address(this), _amount);
        }

        if (_isSwap) {
            if (_minSwapReceived == 0) revert ZeroAmount();
            PIREX_LP.swap(IPirexLiquidityPool.Token._PX_CVX, _amount, _minSwapReceived, FROM_INDEX, TO_INDEX);
            _amount = ASYMMETRY_CVX.deposit(CVX.balanceOf(address(this)), _receiver);
        } else {
            uint256[] memory _assets = new uint256[](1);
            _assets[0] = _amount;
            uint256[] memory _lockIndexes = new uint256[](1);
            _lockIndexes[0] = _lockIndex;
            PIREX_CVX.initiateRedemptions(_lockIndexes, IPirexCVX.Futures.Reward, _assets, _receiver);
        }

        emit Migrated(_amount, _receiver, _isSwap);

        return _amount;
    }

    /// @notice Migrate upxCVX to afCVX
    /// @param _unlockTimes CVX unlock timestamps
    /// @param _amounts upxCVX amounts
    /// @param _receiver Receives afCVX
    function migrate(uint256[] calldata _unlockTimes, uint256[] calldata _amounts, address _receiver) external {
        if (_receiver == address(0)) revert ZeroAddress();

        UPX_CVX.safeBatchTransferFrom(msg.sender, address(this), _unlockTimes, _amounts, ""); // TODO - this section may be faulty
        PIREX_CVX.redeem(_unlockTimes, _amounts, address(this));

        uint256 _amount = CVX.balanceOf(address(this));
        if (_amount > 0) _amount = ASYMMETRY_CVX.deposit(_amount, _receiver);

        emit MigratedAfterRedemption(_amount, _receiver);
    }

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @param shares Amount of afCVX or CVX, depending on if a swap was used
    /// @param receiver Receives of afCVX or upxCVX tokens
    /// @param isSwap True if the user swaped pxCVX for CVX, false if the user redeemed pxCVX for upxCVX
    event Migrated(uint256 shares, address indexed receiver, bool indexed isSwap);

    /// @param shares Amount of afCVX
    /// @param receiver Receives of afCVX
    event MigratedAfterRedemption(uint256 shares, address indexed receiver);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error ZeroAmount();
    error ZeroAddress();
}
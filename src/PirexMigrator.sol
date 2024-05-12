// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPirexLiquidityPool, _CVX, _PX_CVX} from "./interfaces/pirex/IPirexLiquidityPool.sol";
import {IPirexCVX} from "./interfaces/pirex/IPirexCVX.sol";

import {ICVXLocker} from "./interfaces/convex/ICVXLocker.sol";

/// @title PirexMigrator
/// @author johnnyonline (https://github.com/johnnyonline)
/// @notice Migrate uCVX/pxCVX/upxCVX to afCVX
contract PirexMigrator is ERC1155Holder, ReentrancyGuard {

    using SafeERC20 for IERC20;

    mapping(address receiver => mapping(uint256 unlockTime => uint256 amount)) public balances;

    address public immutable sweepReceiver;

    uint256 public constant FROM_INDEX = 1; // lpxCVX
    uint256 public constant TO_INDEX = 0; // CVX

    IERC20 public constant CVX = IERC20(_CVX);
    IERC20 public constant PX_CVX = IERC20(_PX_CVX);

    IERC1155 public constant UPX_CVX = IERC1155(0x7A3D81CFC5A942aBE9ec656EFF818f7daB4E0Fe1);
    IERC1155 public constant RPX_CVX = IERC1155(0xC044613B702Ed11567A38108703Ac5478a3F7DB8);

    IERC4626 public constant UNION_CVX = IERC4626(0x8659Fc767cad6005de79AF65dAfE4249C57927AF);
    IERC4626 public constant ASYMMETRY_CVX = IERC4626(0x8668a15b7b023Dc77B372a740FCb8939E15257Cf);

    IPirexCVX public constant PIREX_CVX = IPirexCVX(0x35A398425d9f1029021A92bc3d2557D42C8588D7);
    IPirexLiquidityPool public constant PIREX_LP = IPirexLiquidityPool(0x389fB29230D02e67eB963C1F5A00f2b16f95BEb7);
    ICVXLocker public constant CVX_LOCKER = ICVXLocker(0x72a19342e8F1838460eBFCCEf09F6585e32db86E);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(address _sweepReceiver) {
        if (_sweepReceiver == address(0)) revert ZeroAddress();

        sweepReceiver = _sweepReceiver;

        CVX.forceApprove(address(ASYMMETRY_CVX), type(uint256).max);
        PX_CVX.forceApprove(address(PIREX_LP), type(uint256).max);
    }

    // ============================================================================================
    // External functions
    // ============================================================================================

    /// @notice Migrate uCVX/pxCVX to afCVX
    /// @dev nonReentrant modifier is used because not following the CEI pattern
    /// @dev Migration using a swap will result in the `_receiver` receiving afCVX tokens immidiately.
    ///      Migration not using a swap will result in the `_receiver`'s internal account being credited with upxCVX tokens.
    ///      Internally credited upxCVX can be redeemed for CVX and deposited into afCVX once the unlock time has passed using the `redeem` function.
    /// @param _rpxCvxIDs Array of RPX_CVX token IDs. NOTICE: If the caller fails to provide the correct IDs, he will lose the tokens.
    /// @param _amount Amount of uCVX/pxCVX
    /// @param _minSwapReceived Minimum amount of CVX to receive from the swap. Only used if `_isSwap` is true
    /// @param _lockIndex Lock index
    /// @param _receiver Receiver of afCVX or upxCVX tokens
    /// @param _isUnionized True if the user is migrating from uCVX, false if the user is migrating from pxCVX
    /// @param _isSwap True if the user wants to swap uCVX/pxCVX for CVX, false if the user wants to redeem uCVX/pxCVX for upxCVX
    /// @return Amount of afCVX sent or upxCVX credited to the `_receiver`
    function migrate(
        uint256[] calldata _rpxCvxIDs,
        uint256 _amount,
        uint256 _minSwapReceived,
        uint256 _lockIndex,
        address _receiver,
        bool _isUnionized,
        bool _isSwap
    ) external nonReentrant returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        if (_receiver == address(0)) revert ZeroAddress();
        if (_receiver == address(this)) revert InvalidAddress();

        if (_isUnionized) {
            _amount = UNION_CVX.redeem(_amount, address(this), msg.sender);
        } else {
            PX_CVX.safeTransferFrom(msg.sender, address(this), _amount);
        }

        if (_isSwap) {
            PIREX_LP.swap(IPirexLiquidityPool.Token._PX_CVX, _amount, _minSwapReceived, FROM_INDEX, TO_INDEX);
            _amount = ASYMMETRY_CVX.deposit(CVX.balanceOf(address(this)), _receiver);
        } else {
            _amount = _initiateRedemption(_rpxCvxIDs, _amount, _lockIndex, _receiver);
        }

        emit Migrated(_amount, _receiver, _isSwap);

        return _amount;
    }

    /// @notice Migrate upxCVX to afCVX
    /// @param _unlockTimes CVX unlock timestamps
    /// @param _amounts upxCVX amounts
    /// @param _receiver Receiver of afCVX
    /// @return _amount Amount of afCVX sent to the `_receiver`
    function migrate(uint256[] calldata _unlockTimes, uint256[] calldata _amounts, address _receiver) external returns (uint256 _amount) {
        if (_receiver == address(0)) revert ZeroAddress();
        if (_receiver == address(this)) revert InvalidAddress();

        UPX_CVX.safeBatchTransferFrom(msg.sender, address(this), _unlockTimes, _amounts, "");
        PIREX_CVX.redeem(_unlockTimes, _amounts, address(this));

        _amount = CVX.balanceOf(address(this));
        if (_amount > 0) _amount = ASYMMETRY_CVX.deposit(_amount, _receiver);

        emit MigratedAfterRedemption(_amount, _receiver);
    }

    /// @notice Redeem credited upxCVX for CVX and deposit into afCVX for multiple unlock times and users
    /// @param _unlockTimes CVX unlock timestamps
    /// @param _fors The addresses to redeem for
    /// @return _amount total amount of afCVX sent to users
    function multiRedeem(uint256[] calldata _unlockTimes, address[] calldata _fors) external returns (uint256 _amount) {

        uint256 _length = _unlockTimes.length;
        if (_length != _fors.length) revert InvalidLength();

        for (uint256 i; i < _length; ++i) {
            _amount += redeem(_unlockTimes[i], _fors[i], false);
        }
    }

    /// @notice Redeem credited upxCVX for CVX and deposit into afCVX
    /// @dev Anyone can redeem for anyone else
    /// @param _unlockTime CVX unlock timestamp
    /// @param _for The address to redeem for
    /// @param _legacy True if upxCVX has been deprecated
    /// @return _amount Amount of afCVX sent to the `_receiver`
    function redeem(uint256 _unlockTime, address _for, bool _legacy) public returns (uint256 _amount) {

        _amount = balances[_for][_unlockTime];
        balances[_for][_unlockTime] = 0;

        {
            uint256[] memory _unlockTimes = new uint256[](1);
            _unlockTimes[0] = _unlockTime;
            uint256[] memory _amounts = new uint256[](1);
            _amounts[0] = _amount;
            !_legacy ?
                PIREX_CVX.redeem(_unlockTimes, _amounts, address(this)) :
                PIREX_CVX.redeemLegacy(_unlockTimes, _amounts, address(this));
        }

        _amount = CVX.balanceOf(address(this));
        if (_amount > 0) _amount = ASYMMETRY_CVX.deposit(_amount, _for);

        emit Redeemed(_amount, _unlockTime, _for, msg.sender);
    }

    /// @notice Sweep RPX_CVX tokens to the `sweepReceiver`
    /// @param _rpxCvxIDs Array of RPX_CVX token IDs
    function sweep(uint256[] calldata _rpxCvxIDs) external {
        uint256 _length = _rpxCvxIDs.length;
        if (_length > 0) {
            for (uint256 i; i < _length; ++i) {
                uint256 _balance = RPX_CVX.balanceOf(address(this), _rpxCvxIDs[i]);
                RPX_CVX.safeTransferFrom(address(this), sweepReceiver, _rpxCvxIDs[i], _balance, "");
            }
        }
    }

    // ============================================================================================
    // Internal functions
    // ============================================================================================

    /// @dev Whoever calling should be nonReentrant because CEI pattern is violated
    function _initiateRedemption(
        uint256[] calldata _rpxCvxIDs,
        uint256 _amount,
        uint256 _lockIndex,
        address _receiver
    ) internal returns (uint256) {
        (,,,ICVXLocker.LockedBalance[] memory _lockData) = CVX_LOCKER.lockedBalances(address(PIREX_CVX));
        uint256 _unlockTime = _lockData[_lockIndex].unlockTime;
        uint256 _balance = UPX_CVX.balanceOf(address(this), _unlockTime);

        {
            uint256[] memory _assets = new uint256[](1);
            _assets[0] = _amount;
            uint256[] memory _lockIndexes = new uint256[](1);
            _lockIndexes[0] = _lockIndex;
            PIREX_CVX.initiateRedemptions(_lockIndexes, IPirexCVX.Futures.Reward, _assets, address(this));
        }

        _amount = UPX_CVX.balanceOf(address(this), _unlockTime) - _balance;
        balances[_receiver][_unlockTime] += _amount;

        emit InitiatedRedemption(_amount, _unlockTime, _receiver);

        uint256 _length = _rpxCvxIDs.length;
        if (_length > 0) {
            for (uint256 i; i < _length; ++i) {
                _balance = RPX_CVX.balanceOf(address(this), _rpxCvxIDs[i]);
                RPX_CVX.safeTransferFrom(
                    address(this),
                    _receiver,
                    _rpxCvxIDs[i],
                    _balance,
                    ""
                );
            }
        }

        return _amount;
    }

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @param shares Amount of afCVX sent, or amount of upxCVX credited, to the `_receiver`
    /// @param receiver Receiver of afCVX tokens or upxCVX credits
    /// @param isSwap True if the user swaped pxCVX for CVX, false if the user redeemed pxCVX for upxCVX
    event Migrated(uint256 shares, address indexed receiver, bool indexed isSwap);

    /// @param shares Amount of afCVX
    /// @param receiver Receiver of afCVX
    event MigratedAfterRedemption(uint256 shares, address indexed receiver);

    /// @param shares Amount of afCVX
    /// @param unlockTime CVX unlock timestamp
    /// @param receiver Address to redeem for
    /// @param caller Address that called the function
    event Redeemed(uint256 shares, uint256 unlockTime, address indexed receiver, address caller);

    /// @param shares Amount of upxCVX credited
    /// @param unlockTime CVX unlock timestamp
    /// @param receiver Receiver of upxCVX credits
    event InitiatedRedemption(uint256 shares, uint256 unlockTime, address indexed receiver);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error ZeroAmount();
    error ZeroAddress();
    error InvalidLength();
    error InvalidAddress();
}
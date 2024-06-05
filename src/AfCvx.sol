// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {ERC4626Upgradeable, ERC20Upgradeable, Math} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLeverStrategy} from "./interfaces/asymmetry/ICLeverStrategy.sol";
import {IConvexRewardsPool} from "./interfaces/convex/IConvexRewardsPool.sol";

import {TrackedAllowances} from "./utils/TrackedAllowances.sol";
import {Zap} from "./utils/Zap.sol";

contract AfCvx is TrackedAllowances, Ownable, ERC4626Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {

    using SafeERC20 for IERC20;

    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    uint16 public protocolFeeBps;
    address public protocolFeeCollector;

    uint16 public cleverStrategyShareBps;
    address public operator;

    bool public paused;
    uint128 public weeklyWithdrawalLimit;
    uint16 public withdrawalFeeBps;
    uint64 public withdrawalLimitNextUpdate;
    uint16 public weeklyWithdrawalShareBps;

    uint256 private constant PRECISION = 10_000;

    IERC20 private constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 private constant CVXCRV = IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    ICLeverStrategy public immutable cleverStrategy;

    IConvexRewardsPool private constant CVX_REWARDS_POOL = IConvexRewardsPool(0xCF50b810E57Ac33B91dCF525C6ddd9881B139332);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(address _strategy) {
        _disableInitializers();
        cleverStrategy = ICLeverStrategy(_strategy);
    }

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    /// @notice Sets the share of value that CLever CVX strategy should hold
    /// @dev Staked CVX share is automatically `100% - clevStrategyShareBps`
    /// @param _bps New share CLever strategy basis points
    function setCleverCvxStrategyShare(uint16 _bps) external onlyOwner {
        if (_bps > PRECISION) revert InvalidShare();

        cleverStrategyShareBps = _bps;
        emit CleverCvxStrategyShareSet(_bps);
    }

    /// @notice Sets the protocol performance fee
    /// @param _bps New fee basis points
    function setProtocolFee(uint16 _bps) external onlyOwner {
        if (_bps > PRECISION) revert InvalidFee();

        protocolFeeBps = _bps;
        emit ProtocolFeeSet(_bps);
    }

    /// @notice Sets the withdrawal fee
    /// @param _bps New withdrawal fee basis points
    function setWithdrawalFee(uint16 _bps) external onlyOwner {
        if (_bps > PRECISION) revert InvalidFee();

        withdrawalFeeBps = _bps;
        emit WithdrawalFeeSet(_bps);
    }

    /// @notice Sets the share of the protocol TVL that can be withdrawn in a week
    /// @param _bps New weekly withdraw share basis points
    function setWeeklyWithdrawShare(uint16 _bps) external onlyOwner {
        if (_bps > PRECISION) revert InvalidShare();

        weeklyWithdrawalShareBps = _bps;
        emit WeeklyWithdrawShareSet(_bps);
    }

    /// @notice Sets the recipient of the protocol performance fee
    /// @param _collector New protocol fee collector
    function setProtocolFeeCollector(address _collector) external onlyOwner {
        if (_collector == address(0)) revert InvalidAddress();

        protocolFeeCollector = _collector;
        emit ProtocolFeeCollectorSet(_collector);
    }

    /// @notice Sets the operator address
    /// @param _operator New operator address
    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();

        operator = _operator;
        emit OperatorSet(_operator);
    }

    /// @notice Set paused state
    /// @param _paused New paused state
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Sweeps stuck ETH from the contract
    /// @dev Transfers the entire contract balance to the owner
    function sweep() external onlyOwner {
        (bool _sent, bytes memory _data) = payable(owner()).call{value: address(this).balance}("");
        if (!_sent) revert SweepFailed(_data);
    }

    /// @dev Allows the owner of the contract to upgrade to *any* new address
    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @inheritdoc ERC4626Upgradeable
    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return 18;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address) public view override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address) public view override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused) return 0;

        uint256 _availableAssets = Math.min(
            CVX.balanceOf(address(this)) + CVX_REWARDS_POOL.balanceOf(address(this)),
            weeklyWithdrawalLimit
        );

        return Math.min(
            balanceOf(owner),
            _convertToShares(
                _availableAssets + Math.mulDiv(_availableAssets, withdrawalFeeBps, PRECISION, Math.Rounding.Ceil),
                Math.Rounding.Floor
            )
        );
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxWithdraw(address _owner) public view override returns (uint256) {
        if (paused) return 0;

        return Math.min(
            previewRedeem(balanceOf(_owner)),
            Math.min(
                weeklyWithdrawalLimit,
                CVX.balanceOf(address(this)) + CVX_REWARDS_POOL.balanceOf(address(this))
            )
        );
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewWithdraw(uint256 _assets) public view override returns (uint256) {
        return _convertToShares(
            _assets + Math.mulDiv(_assets, withdrawalFeeBps, PRECISION, Math.Rounding.Ceil),
            Math.Rounding.Floor
        );
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewRedeem(uint256 _shares) public view override returns (uint256) {
        uint256 _assets = _convertToAssets(_shares, Math.Rounding.Floor);
        return _assets - Math.mulDiv(_assets, withdrawalFeeBps, PRECISION, Math.Rounding.Ceil);
    }

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256) {
        return
            CVX.balanceOf(address(this)) // Idle CVX
            + CVX_REWARDS_POOL.balanceOf(address(this)) // Staked CVX
            + cleverStrategy.netAssets(protocolFeeBps);
    }

    /// @notice Returns the maximum amount of assets that can be unlocked by the `owner`.
    function maxRequestUnlock(address _owner) public view returns (uint256) {
        if (paused) return 0;

        return Math.min(
            balanceOf(_owner),
            _convertToShares(
                cleverStrategy.maxTotalUnlock(),
                Math.Rounding.Floor
            )
        );
    }

    /// @notice Returns the amount of assets that can be unlocked by burning _shares
    function previewRequestUnlock(uint256 _shares) public view returns (uint256) {
        return _convertToAssets(_shares, Math.Rounding.Floor);
    }

    // ============================================================================================
    // Unlock from Clever
    // ============================================================================================

    /// @notice Requests assets to be unlocked from CLever, by burning shares
    /// @dev Withdrawal fee is not charged, but CLever repayment fee is charged
    /// @param _shares The amount of shares to burn
    /// @param _receiver The receiver of the assets
    /// @param _owner The shares owner
    /// @return _unlockEpoch The epoch number when unlocked assets can be withdrawn
    /// @return _assets The amount of assets that will be unlocked
    function requestUnlock(uint256 _shares, address _receiver, address _owner) external returns (uint256 _unlockEpoch, uint256 _assets) {
        uint256 _maxShares = maxRequestUnlock(_owner);
        if (_shares > _maxShares) revert ERC4626ExceededMaxRedeem(_owner, _shares, _maxShares);

        _assets = previewRequestUnlock(_shares);

        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _shares);

        _burn(_owner, _shares);
        _unlockEpoch = cleverStrategy.requestUnlock(_assets, _receiver);

        emit UnlockRequested(msg.sender, _receiver, _owner, _assets, _shares, _unlockEpoch);
    }

    /// @notice Withdraws assets requested earlier by calling `requestUnlock`.
    /// @param _receiver The address to receive the assets.
    function withdrawUnlocked(address _receiver) external returns (uint256 _assets) {
        if (paused) revert Paused();

        _assets = cleverStrategy.withdrawUnlocked(_receiver);
        emit UnlockedWithdrawn(msg.sender, _receiver, _assets);
    }

    // ============================================================================================
    // Operator functions
    // ============================================================================================

    /// @notice distributes the deposited CVX between CLever Strategy and Convex Rewards Pool
    /// @dev If `_swap` is true, must call through a private RPC to avoid getting sandwiched, as totalAssets will spike
    function distribute(bool _swap, uint256 _minAmountOut) external {
        if (msg.sender != operator && msg.sender != owner()) revert Unauthorized();
        if (paused) revert Paused();

        (uint256 _cleverDeposit, uint256 _convexDeposit) = _calculateDistribute();
        if (_cleverDeposit > 0) cleverStrategy.deposit(_cleverDeposit, _swap, _minAmountOut);
        if (_convexDeposit > 0) CVX_REWARDS_POOL.stake(_convexDeposit);

        emit Distributed(_cleverDeposit, _convexDeposit);
    }

    /// @notice Harvest pending rewards from Convex and Furnace and update the weekly withdraw amount
    /// @dev Keeps harvested rewards in the contract. Call `distribute` to redeposit rewards
    /// @param _minAmountOut Minimum amount of CVX to receive from swapping cvxCRV
    /// @return _rewards The total amount of rewards harvested, minus the protocol fee
    function harvest(uint256 _minAmountOut) external returns (uint256 _rewards) {
        if (msg.sender != operator && msg.sender != owner()) revert Unauthorized();
        if (paused) revert Paused();

        // Claim cvxCRV rewards from Convex
        CVX_REWARDS_POOL.getReward(
            address(this), // account
            false, // claimExtras
            false // stake
        );

        uint256 _convexRewards = CVXCRV.balanceOf(address(this));
        if (_convexRewards != 0) _convexRewards = Zap.swapCvxCrvToCvx(_convexRewards, _minAmountOut);

        uint256 _cleverRewards = cleverStrategy.claim();
        _rewards = _convexRewards + _cleverRewards;

        if (_rewards != 0) {
            uint256 _fee = _rewards * protocolFeeBps / PRECISION;
            _rewards -= _fee;
            CVX.safeTransfer(protocolFeeCollector, _fee);
            emit Harvested(_cleverRewards, _convexRewards);
        }

        _updateWeeklyWithdrawalLimit();
    }

    // ============================================================================================
    // Internal view functions
    // ============================================================================================

    /// @notice Calculates the amount of CVX to deposit into Clever and Convex
    /// @return _cleverDeposit The amount of CVX to deposit into Clever
    /// @return _convexDeposit The amount of CVX to deposit into Convex
    function _calculateDistribute() internal view returns (uint256 _cleverDeposit, uint256 _convexDeposit) {
        uint256 _totalDeposit = CVX.balanceOf(address(this));
        if (_totalDeposit == 0) return (0, 0);

        uint256 _assetsInConvex = CVX_REWARDS_POOL.balanceOf(address(this));
        uint256 _assetsInCLever = cleverStrategy.netAssets(protocolFeeBps);

        uint256 _totalAssets = totalAssets();
        uint256 _cleverStrategyShareBps = cleverStrategyShareBps;
        uint256 _targetAssetsInCLever = _totalAssets * _cleverStrategyShareBps / PRECISION;
        uint256 _targetAssetsInConvex = _totalAssets * (PRECISION - _cleverStrategyShareBps) / PRECISION;

        uint256 _requiredCLeverDeposit = _targetAssetsInCLever > _assetsInCLever ? _targetAssetsInCLever - _assetsInCLever : 0;
        uint256 _requiredConvexDeposit = _targetAssetsInConvex > _assetsInConvex ? _targetAssetsInConvex - _assetsInConvex : 0;

        uint256 _totalRequiredDeposit = _requiredCLeverDeposit + _requiredConvexDeposit;

        if (_totalRequiredDeposit <= _totalDeposit) {
            _cleverDeposit = _requiredCLeverDeposit;
            _convexDeposit = _requiredConvexDeposit;
            
            // Adjust any remaining amount to ensure all assets are deposited
            uint256 _remainingDeposit = _totalDeposit - _totalRequiredDeposit;
            if (_remainingDeposit > 0) {
                _cleverDeposit += _remainingDeposit * cleverStrategyShareBps / PRECISION;
                _convexDeposit += _remainingDeposit * (PRECISION - cleverStrategyShareBps) / PRECISION;
            }
        } else {
            // Proportionally adjust deposits to fit the _totalDeposit
            _cleverDeposit = (_totalDeposit * _requiredCLeverDeposit) / _totalRequiredDeposit;
            _convexDeposit = (_totalDeposit * _requiredConvexDeposit) / _totalRequiredDeposit;
        }
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @notice Updates the weekly withdrawal limit and the next update date
    function _updateWeeklyWithdrawalLimit() private {
        if (block.timestamp < withdrawalLimitNextUpdate) return;

        uint128 _withdrawalLimit = uint128(totalAssets() * weeklyWithdrawalShareBps / PRECISION);
        uint64 _nextUpdate = uint64(block.timestamp + 7 days);

        weeklyWithdrawalLimit = _withdrawalLimit;
        withdrawalLimitNextUpdate = _nextUpdate;

        emit WeeklyWithdrawLimitUpdated(_withdrawalLimit, _nextUpdate);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {

        // Need to transfer before minting or ERC777s could reenter
        CVX.safeTransferFrom(_caller, address(this), _assets);

        _mint(_receiver, _shares);

        emit Deposit(_caller, _receiver, _assets, _shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares) internal override {
        unchecked {
            weeklyWithdrawalLimit -= uint128(_assets);
        }

        if (_assets != 0) {
            uint256 _idle = CVX.balanceOf(address(this));
            if (_idle < _assets) {
                unchecked {
                    _assets -= _idle;
                }
                CVX_REWARDS_POOL.withdraw(
                    _assets, // amount
                    false // claim
                );
            }
        }

        if (_caller != _owner) _spendAllowance(_owner, _caller, _shares);

        // Need to transfer after minting or ERC777s could reenter
        _burn(_owner, _shares);
        CVX.safeTransfer(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    // ============================================================================================
    // Receive
    // ============================================================================================

    /// @dev receives ETH when swapping cvxCRV to CVX via CVX-ETH pool
    receive() external payable {
        if (msg.sender != address(Zap.CRV_ETH_POOL)) revert DirectEthTransfer();
    }

    // ============================================================================================
    // Events
    // ============================================================================================

    event CleverCvxStrategyShareSet(uint256 indexed newShare);
    event ProtocolFeeSet(uint256 indexed newProtocolFee);
    event WithdrawalFeeSet(uint256 indexed newWithdrawalFee);
    event ProtocolFeeCollectorSet(address indexed newProtocolFeeCollector);
    event WeeklyWithdrawShareSet(uint256 indexed newShare);
    event OperatorSet(address indexed newOperator);
    event EmergencyShutdown();
    event Distributed(uint256 indexed cleverDepositAmount, uint256 indexed convexStakeAmount);
    event Harvested(uint256 indexed cleverRewards, uint256 indexed convexStakedRewards);
    event UnlockRequested(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares, uint256 unlockEpoch);
    event UnlockedWithdrawn(address indexed sender, address indexed receiver, uint256 amount);
    event WeeklyWithdrawLimitUpdated(uint256 indexed withdrawLimit, uint256 nextUpdateDate);
    event PausedSet(bool paused);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error InvalidShare();
    error InvalidFee();
    error InvalidAddress();
    error DirectEthTransfer();
    error ExceededMaxUnlock(address owner, uint256 assets, uint256 max);
    error Paused();
    error SweepFailed(bytes data);
}

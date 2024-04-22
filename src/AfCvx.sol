// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Ownable } from "solady/auth/Ownable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { TrackedAllowances, Allowance } from "./utils/TrackedAllowances.sol";
import { IAfCvx } from "./interfaces/afCvx/IAfCvx.sol";
import { ICleverCvxStrategy } from "./interfaces/afCvx/ICleverCvxStrategy.sol";
import { CVX } from "./interfaces/convex/Constants.sol";
import { CVX_REWARDS_POOL } from "./interfaces/convex/ICvxRewardsPool.sol";
import { CLEVER_CVX_LOCKER } from "./interfaces/clever/ICLeverCvxLocker.sol";
import { Zap } from "./utils/Zap.sol";

contract AfCvx is IAfCvx, TrackedAllowances, Ownable, ERC4626Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    uint256 internal constant BASIS_POINT_SCALE = 10000;

    ICleverCvxStrategy public immutable cleverCvxStrategy;

    uint16 public protocolFeeBps;
    address public protocolFeeCollector;

    uint16 public cleverStrategyShareBps;
    address public operator;

    bool public paused;
    uint128 public weeklyWithdrawalLimit;
    uint16 public withdrawalFeeBps;
    uint64 public withdrawalLimitNextUpdate;
    uint16 public weeklyWithdrawalShareBps;

    modifier onlyOperator() {
        if (msg.sender != owner()) {
            if (msg.sender != operator) revert Unauthorized();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(address strategy) {
        _disableInitializers();
        cleverCvxStrategy = ICleverCvxStrategy(strategy);
    }

    function initialize(address _owner, address _operator, address _feeCollector) external payable initializer {
        string memory name_ = "Asymmetry Finance afCVX";
        __ERC20_init(name_, "afCVX");
        __ERC4626_init(CVX);
        __ERC20Permit_init(name_);
        __UUPSUpgradeable_init();
        _initializeOwner(_owner);
        operator = _operator;
        protocolFeeCollector = _feeCollector;
        // 80% is deposited to Clever and 20% is staked on Convex
        cleverStrategyShareBps = 8000;

        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(CVX_REWARDS_POOL), token: address(CVX) }));
        _grantAndTrackInfiniteAllowance(Allowance({ spender: address(cleverCvxStrategy), token: address(CVX) }));
    }

    receive() external payable {
        if (msg.sender != Zap.CRV_ETH_POOL) revert DirectEthTransfer();
    }

    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return 18;
    }

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 unlocked, uint256 lockedInClever, uint256 staked) = _getAvailableAssets();
        return unlocked + lockedInClever + staked;
    }

    function getAvailableAssets() external view returns (uint256 unlocked, uint256 lockedInClever, uint256 staked) {
        (unlocked, lockedInClever, staked) = _getAvailableAssets();
    }

    function _getAvailableAssets() private view returns (uint256 unlocked, uint256 lockedInClever, uint256 staked) {
        unlocked = CVX.balanceOf(address(this));

        // NOTE: clevCVX is assumed to be 1:1 with CVX
        (uint256 deposited, uint256 rewards) = cleverCvxStrategy.totalValue();
        lockedInClever = deposited + (rewards == 0 ? 0 : (rewards - _mulBps(rewards, protocolFeeBps)));

        // NOTE: we consider only staked CVX in Convex and ignore the rewards, as they are paid in cvxCRV
        // and there is no reliable way to get cvxCRV to CVX price on chain
        staked = CVX_REWARDS_POOL.balanceOf(address(this));
    }

    /// @notice Mints `shares` (afCVX) to `receiver` by depositing exactly `assets` of CVX tokens.
    /// @dev Can be called only if afCVX is not paused.
    ///      See {IERC4626-deposit}
    /// @param assets The amount of assets (CVX) to deposit.
    /// @param receiver The address to receive shares (afCVX).
    /// @return shares The amount of shares minted.
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        returns (uint256 shares)
    {
        return super.deposit(assets, receiver);
    }

    /// @notice Mints exactly `shares` (afCVX) to receiver by depositing `assets` (CVX).
    /// @dev Can be called only if afCVX is not paused.
    ///      See {IERC4626-mint}
    /// @param shares The amount of shares (afCVX) to mint.
    /// @param receiver The address to receive shares (afCVX).
    /// @return assets The amount of assets deposited.
    function mint(uint256 shares, address receiver)
        public
        virtual
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        returns (uint256 assets)
    {
        return super.mint(shares, receiver);
    }

    /// @dev Copied from ERC4626Upgradeable to avoid unnecessary SLOAD of $._asset since _asset is a constant
    ///      https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v5.0/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol#L267
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // If _asset is ERC777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        address(CVX).safeTransferFrom(caller, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Returns the maximum amount of assets (CVX) that can be withdrawn by the `owner`.
    /// @dev Considers the remaining weekly withdrawal limit and the `owner`'s shares balance.
    ///      See {IERC4626-maxWithdraw}
    /// @param owner The address of the owner for which the maximum withdrawal amount is calculated.
    /// @return maxAssets The maximum amount of assets that can be withdrawn by the `owner`.
    function maxWithdraw(address owner)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 maxAssets)
    {
        return previewRedeem(balanceOf(owner)).min(weeklyWithdrawalLimit);
    }

    /// @notice Simulates the effects of assets withdrawal.
    /// @dev Considers shares to assets ratio and the withdrawal fee.
    ///      See {IERC4626-previewWithdraw}
    /// @param assets The number of assets to withdraw.
    /// @return The number of shares to be burnt.
    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        uint256 fee = assets.mulDivUp(withdrawalFeeBps, BASIS_POINT_SCALE);
        return super.previewWithdraw(assets + fee);
    }

    /// @notice Withdraws CVX assets, burning the `owner`'s (afCVX) shares.
    ///         The caller of this function does not have to be the `owner`
    ///         if the `owner` has approved the caller to spend their afCVX.
    /// @dev Can be called only if afCVX is not paused.
    ///      See {IERC4626-withdraw}
    /// @param assets The amount of assets (CVX) to withdraw.
    /// @param receiver The address to receive the assets (CVX).
    /// @param owner The address of the owner for which the shares (afCVX) are burned.
    /// @return shares The amount of shares (afCVX) burned.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Returns the maximum amount of shares (afCVX) that can be redeemed by the `owner`.
    /// @dev Considers the remaining weekly withdrawal limit converted to shares, and the `owner`'s shares balance.
    ///      See {IERC4626-maxRedeem}
    /// @param owner The address of the owner for which the maximum redeemable shares are calculated.
    /// @return maxShares The maximum amount of shares that can be redeemed by the `owner`.
    function maxRedeem(address owner)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 maxShares)
    {
        return balanceOf(owner).min(previewWithdraw(weeklyWithdrawalLimit));
    }

    /// @notice Simulates the effects of shares redemption.
    /// @dev Considers shares to assets ratio and the withdrawal fee.
    ///      See {IERC4626-previewRedeem}
    /// @param shares The number of shares to redeem.
    /// @return The number of assets to be withdrawn.
    function previewRedeem(uint256 shares)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        uint256 assets = super.previewRedeem(shares);
        uint256 feeBps = withdrawalFeeBps;
        return assets - assets.mulDivUp(feeBps, feeBps + BASIS_POINT_SCALE);
    }

    /// @notice Redeems (afCVX) `shares` to receive (CVX) assets, burning the `owner`'s (afCVX) `shares`.
    ///         The caller of this function does not have to be the `owner`
    ///         if the `owner` has approved the caller to spend their afCVX.
    /// @dev Can be called only if afCVX is not paused.
    ///      See {IERC4626-redeem}
    /// @param shares The amount of shares (afCVX) to redeem.
    /// @param receiver The address to receive the assets (CVX).
    /// @param owner The address of the owner for which the shares (afCVX) are burned.
    /// @return assets The amount of assets (CVX) withdrawn.
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        unchecked {
            weeklyWithdrawalLimit -= uint128(assets);
        }

        if (assets != 0) {
            uint256 cvxAvailable = CVX.balanceOf(address(this));
            if (cvxAvailable < assets) {
                // unstake CVX from Convex rewards pool
                uint256 unstakeAmount;
                unchecked {
                    unstakeAmount = assets - cvxAvailable;
                }
                CVX_REWARDS_POOL.withdraw(unstakeAmount, false);
            }
        }

        // Copied from ERC4626Upgradeable to avoid unnecessary SLOAD of $._asset since _asset is a constant
        // https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v5.0/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol#L292
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);
        address(CVX).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Returns the maximum amount of assets (CVX) that can be unlocked by the `owner`.
    /// @dev Considers the total CVX locked in Clever and the `owner`'s shares balance.
    /// @param owner The address of the owner for which the maximum unlock amount is calculated.
    /// @return maxAssets The maximum amount of assets that can be unlocked by the `owner`.
    function maxRequestUnlock(address owner) public view returns (uint256 maxAssets) {
        (uint256 totalLocked,,,,) = CLEVER_CVX_LOCKER.getUserInfo(address(cleverCvxStrategy));
        return super.previewRedeem(balanceOf(owner)).min(totalLocked);
    }

    /// @notice Simulates the effects of assets unlocking.
    /// @dev Withdrawal fee is not taken on unlocking.
    /// @param assets The number of assets to unlock.
    /// @return shares The number of shares to be burnt.
    function previewRequestUnlock(uint256 assets) public view returns (uint256 shares) {
        return super.previewWithdraw(assets);
    }

    /// @notice Requests CVX assets to be unlocked from Clever CVX locker, by burning the `owner`'s (afCVX) shares.
    ///         The caller of this function does not have to be the `owner`
    ///         if the `owner` has approved the caller to spend their afCVX.
    /// @dev Can be called only if afCVX is not paused.
    ///      Withdrawal fee is not taken.
    /// @param assets The amount of assets (CVX) to unlock.
    /// @param receiver The address to receive the assets (CVX).
    /// @param owner The address of the owner for which the shares (afCVX) are burned.
    /// @return unlockEpoch The epoch number when unlocked assets can be withdrawn (1 to 17 weeks from the request).
    /// @return shares The amount of shares (afCVX) burned.
    function requestUnlock(uint256 assets, address receiver, address owner)
        external
        whenNotPaused
        returns (uint256 unlockEpoch, uint256 shares)
    {
        uint256 maxAssets = maxRequestUnlock(owner);
        if (assets > maxAssets) {
            revert ExceededMaxUnlock(owner, assets, maxAssets);
        }

        shares = previewRequestUnlock(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        unlockEpoch = cleverCvxStrategy.requestUnlock(assets, receiver);

        emit UnlockRequested(msg.sender, receiver, owner, assets, shares, unlockEpoch);
    }

    /// @notice Withdraws assets requested earlier by calling `requestUnlock`.
    /// @param receiver The address to receive the assets.
    function withdrawUnlocked(address receiver) external whenNotPaused {
        uint256 cvxUnlocked = cleverCvxStrategy.withdrawUnlocked(receiver);
        if (cvxUnlocked != 0) {
            emit UnlockedWithdrawn(msg.sender, receiver, cvxUnlocked);
        }
    }

    function updateWeeklyWithdrawalLimit() external {
        _updateWeeklyWithdrawalLimit();
    }

    function _updateWeeklyWithdrawalLimit() private {
        if (block.timestamp < withdrawalLimitNextUpdate) return;

        uint256 tvl = totalAssets();
        uint128 withdrawalLimit = uint128(_mulBps(tvl, weeklyWithdrawalShareBps));
        uint64 nextUpdate = uint64(block.timestamp + 7 days);
        weeklyWithdrawalLimit = withdrawalLimit;
        withdrawalLimitNextUpdate = nextUpdate;

        emit WeeklyWithdrawLimitUpdated(withdrawalLimit, nextUpdate);
    }

    function previewDistribute() external view returns (uint256 cleverDepositAmount, uint256 convexStakeAmount) {
        (cleverDepositAmount, convexStakeAmount) = _previewDistribute();
    }

    function _previewDistribute() private view returns (uint256 cleverDepositAmount, uint256 convexStakeAmount) {
        (uint256 unlocked, uint256 lockedInClever, uint256 staked) = _getAvailableAssets();
        if (unlocked == 0) return (0, 0);

        uint256 totalLocked = lockedInClever + staked;
        uint256 targetLockedInClever = _mulBps(unlocked + totalLocked, cleverStrategyShareBps);
        if (targetLockedInClever >= lockedInClever) {
            uint256 delta;
            unchecked {
                delta = targetLockedInClever - lockedInClever;
            }
            cleverDepositAmount = delta > unlocked ? unlocked : delta;
        }

        if (unlocked > cleverDepositAmount) {
            unchecked {
                convexStakeAmount = unlocked - cleverDepositAmount;
            }
        }
    }

    /////////////////////////////////////////////////////////////////
    //                     OPERATOR FUNCTIONS                      //
    /////////////////////////////////////////////////////////////////

    /// @notice distributes the deposited CVX between CLever Strategy and Convex Rewards Pool
    function distribute(bool swap, uint256 minAmountOut) external onlyOperator {
        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = _previewDistribute();

        if (cleverDepositAmount == 0 && convexStakeAmount == 0) return;

        if (cleverDepositAmount > 0) {
            cleverCvxStrategy.deposit(cleverDepositAmount, swap, minAmountOut);
        }

        if (convexStakeAmount > 0) {
            CVX_REWARDS_POOL.stake(convexStakeAmount);
        }

        emit Distributed(cleverDepositAmount, convexStakeAmount);
    }

    /// @notice Harvest pending rewards from Convex and Furnace,
    ///         calculates maximum withdraw amount for the current epoch.
    /// @dev Should be called at the beginning of each epoch.
    ///      Keeps harvested rewards in the contract. Call `distribute` to redeposit rewards.
    function harvest(uint256 minAmountOut) external onlyOperator returns (uint256 rewards) {
        uint256 convexStakedRewards = CVX_REWARDS_POOL.earned(address(this));
        if (convexStakedRewards != 0) {
            CVX_REWARDS_POOL.getReward(false);
            convexStakedRewards = Zap.swapCvxCrvToCvx(convexStakedRewards, minAmountOut);
        }

        uint256 cleverRewards = cleverCvxStrategy.claim();
        rewards = convexStakedRewards + cleverRewards;

        if (rewards != 0) {
            uint256 fee = _mulBps(rewards, protocolFeeBps);
            rewards -= fee;
            address(CVX).safeTransfer(protocolFeeCollector, fee);
            emit Harvested(cleverRewards, convexStakedRewards);
        }

        _updateWeeklyWithdrawalLimit();
    }

    /////////////////////////////////////////////////////////////////
    //                   OWNER ONLY FUNCTIONS                      //
    /////////////////////////////////////////////////////////////////

    /// @notice Pauses deposits and withdrawals.
    /// @dev Called in emergencies to stop all calls and transfers until further notice.
    function emergencyShutdown() external onlyOwner {
        paused = true;
        cleverCvxStrategy.emergencyShutdown();
        _emergencyRevokeAllAllowances();
        emit EmergencyShutdown();
    }

    /// @notice Sets the share of value that CLever CVX strategy should hold.
    /// @notice Target ratio is maintained by directing deposits and rewards into either CLever CVX strategy or staked CVX
    /// @param newShareBps New share of CLever CVX strategy (staked CVX share is automatically 100% - clevStrategyShareBps)
    function setCleverCvxStrategyShare(uint16 newShareBps) external onlyOwner {
        if (newShareBps > BASIS_POINT_SCALE) revert InvalidShare();
        cleverStrategyShareBps = newShareBps;
        emit CleverCvxStrategyShareSet(newShareBps);
    }

    /// @notice Sets the protocol fee which takes a percentage of the rewards
    /// @param newFeeBps New protocol fee
    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > BASIS_POINT_SCALE) revert InvalidFee();
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeSet(newFeeBps);
    }

    /// @notice Sets the withdrawal fee.
    /// @param newFeeBps New withdrawal fee.
    function setWithdrawalFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > BASIS_POINT_SCALE) revert InvalidFee();
        withdrawalFeeBps = newFeeBps;
        emit WithdrawalFeeSet(newFeeBps);
    }

    /// @notice Sets the share of the protocol TVL that can be withdrawn in a week
    /// @param newShareBps New weekly withdraw share.
    function setWeeklyWithdrawShare(uint16 newShareBps) external onlyOwner {
        if (newShareBps > BASIS_POINT_SCALE) revert InvalidShare();
        weeklyWithdrawalShareBps = newShareBps;
        emit WeeklyWithdrawShareSet(newShareBps);
    }

    /// @notice Sets the recipient of the protocol fee.
    /// @param newProtocolFeeCollector New protocol fee collector.
    function setProtocolFeeCollector(address newProtocolFeeCollector) external onlyOwner {
        if (newProtocolFeeCollector != address(0)) revert InvalidAddress();
        protocolFeeCollector = newProtocolFeeCollector;
        emit ProtocolFeeCollectorSet(newProtocolFeeCollector);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator != address(0)) revert InvalidAddress();
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    /// @dev Allows the owner of the contract to upgrade to *any* new address.
    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner { }

    function _mulBps(uint256 value, uint256 bps) private pure returns (uint256) {
        return value * bps / BASIS_POINT_SCALE;
    }
}

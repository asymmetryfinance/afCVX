// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CVX_REWARDS_POOL } from "src/interfaces/convex/ICvxRewardsPool.sol";
import { FURNACE } from "src/interfaces/clever/IFurnace.sol";
import { SimpleProxyFactory } from "src/utils/SimpleProxyFactory.sol";
import { CleverCvxStrategy } from "src/strategies/CleverCvxStrategy.sol";
import { AfCvx } from "src/AfCvx.sol";
import { CVX_TREASURY } from "test/interfaces/ICvxTreasury.sol";

abstract contract BaseForkTest is Test {
    bytes private constant CREATE2_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    uint256 internal constant USE_MAX = 1 << 255;
    uint256 internal constant BASIS_POINT_SCALE = 10000;

    address internal immutable deployer = makeAddr("DEPLOYER");
    address internal immutable owner = makeAddr("OWNER");
    address internal immutable operator = makeAddr("OPERATOR");
    address internal immutable feeCollector = makeAddr("FEE COLLECTOR");

    SimpleProxyFactory internal factory;

    CleverCvxStrategy private _cleverCvxStrategyImplementation;
    CleverCvxStrategy internal cleverCvxStrategy;

    AfCvx private _afCvxImplementation;
    AfCvx internal afCvx;

    function setUp() public virtual {
        string memory rpcUrl = vm.rpcUrl("ethereum");
        uint256 forkBlockNumber = 19630300;
        vm.createSelectFork(rpcUrl, forkBlockNumber);

        factory = new SimpleProxyFactory();

        bytes32 cleverCvxStrategySalt = bytes32(abi.encodePacked(deployer, uint96(0x01)));
        bytes32 afCvxSalt = bytes32(abi.encodePacked(deployer, uint96(0x02)));

        address cleverCvxStrategyProxyAddr = factory.predictDeterministicAddress(cleverCvxStrategySalt);
        address afCvxProxyAddr = factory.predictDeterministicAddress(afCvxSalt);

        assertTrue(cleverCvxStrategyProxyAddr != afCvxProxyAddr, "Duplicate address");

        _cleverCvxStrategyImplementation = new CleverCvxStrategy(afCvxProxyAddr);
        _afCvxImplementation = new AfCvx(cleverCvxStrategyProxyAddr);

        startHoax(deployer, 1 ether);
        cleverCvxStrategy = CleverCvxStrategy(
            payable(
                factory.deployDeterministic(
                    cleverCvxStrategySalt,
                    address(_cleverCvxStrategyImplementation),
                    abi.encodeCall(CleverCvxStrategy.initialize, (owner, operator))
                )
            )
        );
        assertEq(
            address(cleverCvxStrategy), cleverCvxStrategyProxyAddr, "predicted wrong cleverCvxStrategy proxy address"
        );
        afCvx = AfCvx(
            payable(
                factory.deployDeterministic(
                    afCvxSalt,
                    address(_afCvxImplementation),
                    abi.encodeCall(AfCvx.initialize, (owner, operator, feeCollector))
                )
            )
        );
        assertEq(address(afCvx), afCvxProxyAddr, "predicted wrong afCvx proxy address");
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    //                       UTILS FUNCTIONS                       //
    /////////////////////////////////////////////////////////////////

    /// @notice Transfers CVX from CVX Treasury to the specified recipient
    function _transferCvx(address to, uint256 amount) internal {
        // Call mint as the operator
        address cvxOperator = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
        vm.prank(cvxOperator);
        CVX_TREASURY.withdrawTo(CVX, amount, to);
    }

    function _createAccountWithCvx(string memory name, uint256 amount) internal returns (address account) {
        account = makeAddr(name);
        _transferCvx(account, amount);
    }

    function _createAccountWithCvx(uint256 amount) internal returns (address account) {
        account = _createAccountWithCvx("account", amount);
    }

    function _distributeAndBorrow() internal {
        vm.startPrank(owner);
        afCvx.distribute(false, 0);
        vm.roll(block.number + 1);
        cleverCvxStrategy.borrow();
        vm.roll(block.number + 1);
        vm.stopPrank();
    }

    function _repayAndUnlock() internal {
        vm.startPrank(operator);
        cleverCvxStrategy.repay();
        vm.roll(block.number + 1);
        cleverCvxStrategy.unlock();
        vm.roll(block.number + 1);
        vm.stopPrank();
    }

    function _distributeFurnaceRewards(uint256 rewards) internal {
        address furnaceOwner = Ownable(address(FURNACE)).owner();
        _transferCvx(furnaceOwner, rewards);
        vm.startPrank(furnaceOwner);
        CVX.approve(address(FURNACE), rewards);
        FURNACE.distribute(furnaceOwner, rewards);
        vm.stopPrank();
    }

    function _deposit(uint256 amount) internal returns (uint256 afCvxReceived) {
        address account = _createAccountWithCvx(amount);
        return _deposit(account, amount);
    }

    function _deposit(address account, uint256 amount) internal returns (uint256 afCvxReceived) {
        vm.startPrank(account);
        CVX.approve(address(afCvx), amount);
        afCvxReceived = afCvx.deposit(amount, account);
        vm.stopPrank();
    }

    function _updateWeeklyWithdrawalLimit(uint16 share) internal {
        vm.startPrank(owner);
        afCvx.setWeeklyWithdrawShare(share);
        afCvx.updateWeeklyWithdrawalLimit();
        vm.stopPrank();
    }

    function _setFees(uint16 protocolFee, uint16 withdrawalFee) internal {
        vm.startPrank(owner);
        afCvx.setProtocolFee(protocolFee);
        afCvx.setWithdrawalFee(withdrawalFee);
        vm.stopPrank();
    }

    function _mockCleverTotalValue(uint256 deposited, uint256 rewards) internal {
        vm.mockCall(
            address(cleverCvxStrategy),
            abi.encodeWithSelector(cleverCvxStrategy.totalValue.selector),
            abi.encode(deposited, rewards)
        );
    }

    function _mockStakedTotalValue(uint256 staked, uint256 rewards) internal {
        vm.mockCall(
            address(CVX_REWARDS_POOL), abi.encodeWithSelector(CVX_REWARDS_POOL.balanceOf.selector), abi.encode(staked)
        );
        vm.mockCall(
            address(CVX_REWARDS_POOL), abi.encodeWithSelector(CVX_REWARDS_POOL.earned.selector), abi.encode(rewards)
        );
    }

    function _mulBps(uint256 value, uint256 bps) internal pure returns (uint256) {
        return value * bps / BASIS_POINT_SCALE;
    }
}

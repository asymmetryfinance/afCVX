// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IConvexRewardsPool} from "../../src/interfaces/convex/IConvexRewardsPool.sol";

import {SimpleProxyFactory} from "../../src/utils/SimpleProxyFactory.sol";

import {AfCvx, Ownable} from "../../src/AfCvx.sol";
import {CleverCvxStrategy, ICLeverLocker, IFurnace} from "../../src/strategies/CleverCvxStrategy.sol";
import {LPStrategy} from "../../src/strategies/LPStrategy.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

abstract contract Base is Test {

    address payable public user;

    address public immutable owner = 0x263b03BbA0BbbC320928B6026f5eAAFAD9F1ddeb;

    IERC20Metadata public constant CVX = IERC20Metadata(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20Metadata public constant CVXCRV = IERC20Metadata(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    IFurnace public constant FURNACE = IFurnace(0xCe4dCc5028588377E279255c0335Effe2d7aB72a);
    ICLeverLocker public constant CLEVER_CVX_LOCKER = ICLeverLocker(0x96C68D861aDa016Ed98c30C810879F9df7c64154);

    AfCvx public afCvxImplementation;
    CleverCvxStrategy public cleverCvxStrategyImplementation;
    LPStrategy public lpStrategyImplementation;
    LPStrategy public LPSTRATEGY_PROXY;

    AfCvx public constant AFCVX_PROXY = AfCvx(payable(0x8668a15b7b023Dc77B372a740FCb8939E15257Cf));
    CleverCvxStrategy public constant CLEVERCVXSTRATEGY_PROXY = CleverCvxStrategy(0xB828a33aF42ab2e8908DfA8C2470850db7e4Fd2a);
    SimpleProxyFactory public constant SIMPLE_PROXY_FACTORY = SimpleProxyFactory(0x156e0382068C3f96a629f51dcF99cEA5250B9eda);

    IConvexRewardsPool public constant CVX_REWARDS_POOL = IConvexRewardsPool(0xCF50b810E57Ac33B91dCF525C6ddd9881B139332);

    uint256 public constant PRECISION = 10_000;

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public virtual {

        vm.createSelectFork(
            vm.envString("ETHEREUM_RPC_URL"), // rpc url
            20791788 // fork block number
        );
        // vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        // Create user
        user = _createUser("user");

        // Set salt values
        bytes32 _lpStrategyProxySalt = bytes32(abi.encodePacked(address(this), uint96(0x420)));

        // Predict proxy addresses
        address _lpStrategyProxyAddr = SIMPLE_PROXY_FACTORY.predictDeterministicAddress(_lpStrategyProxySalt);

        // Deploy implementation contracts
        afCvxImplementation = new AfCvx(address(CLEVERCVXSTRATEGY_PROXY));
        cleverCvxStrategyImplementation = new CleverCvxStrategy(address(AFCVX_PROXY), _lpStrategyProxyAddr);
        lpStrategyImplementation = new LPStrategy();

        // Deploy CleverCvxStrategy proxy
        LPSTRATEGY_PROXY = LPStrategy(SIMPLE_PROXY_FACTORY.deployDeterministic(
            _lpStrategyProxySalt,
            address(lpStrategyImplementation),
            abi.encodeWithSignature("initialize(address)", owner)
        ));
        require(address(LPSTRATEGY_PROXY) == _lpStrategyProxyAddr, "predicted wrong lpStrategyProxyAddr proxy address");

        // Load implementation contracts
        vm.label({ account: address(afCvxImplementation), newLabel: "afCvxImplementation" });
        vm.label({ account: address(cleverCvxStrategyImplementation), newLabel: "cleverCvxStrategyImplementation" });
        vm.label({ account: address(AFCVX_PROXY), newLabel: "AFCVX_PROXY" });
        vm.label({ account: address(CLEVERCVXSTRATEGY_PROXY), newLabel: "CLEVERCVXSTRATEGY_PROXY" });
        vm.label({ account: address(LPSTRATEGY_PROXY), newLabel: "LPSTRATEGY_PROXY" });
    }

    // ============================================================================================
    // Internal helpers
    // ============================================================================================

    function _createUser(string memory _name) internal returns (address payable) {
        address payable _user = payable(makeAddr(_name));
        vm.deal({ account: _user, newBalance: 100 ether });
        deal({ token: address(CVX), to: _user, give: 100_000_000 * 10 ** CVX.decimals() });
        return _user;
    }

    function _upgradeImplementations() internal {
        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        bytes memory emptyData = "";
        vm.startPrank(owner);
        UUPSUpgradeable(AFCVX_PROXY).upgradeToAndCall(address(afCvxImplementation), emptyData);
        UUPSUpgradeable(CLEVERCVXSTRATEGY_PROXY).upgradeToAndCall(address(cleverCvxStrategyImplementation), emptyData);
        vm.stopPrank();
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "_upgradeImplementations: E0");
    }

    function _deposit(uint256 _assets, address _user) internal returns (uint256 _shares) {
        vm.startPrank(_user);
        CVX.approve(address(AFCVX_PROXY), _assets);
        _shares = AFCVX_PROXY.deposit(_assets, _user);
        vm.stopPrank();
    }
}
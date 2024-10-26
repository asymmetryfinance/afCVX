// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SimpleProxyFactory} from "../src/utils/SimpleProxyFactory.sol";

import {CleverCvxStrategy} from "../src/strategies/CleverCvxStrategy.sol";
import {LPStrategy} from "../src/strategies/LPStrategy.sol";

import {AfCvx} from "../src/AfCvx.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployAfCvx.s.sol:DeployAfCvx --verify --slow --legacy --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

// verify:
// --constructor-args $(cast abi-encode "constructor(address)" 0x5C1E6bA712e9FC3399Ee7d5824B6Ec68A0363C02)
// forge verify-contract --etherscan-api-key $KEY --watch --chain-id $CHAIN_ID --compiler-version $FULL_COMPILER_VER --verifier-url $VERIFIER_URL $ADDRESS $PATH:$FILE_NAME

contract DeployAfCvx is Script {

    address private constant _OWNER = 0x263b03BbA0BbbC320928B6026f5eAAFAD9F1ddeb;
    address private constant _OPERATOR = 0xa927c81CC214cc991613cB695751Bc932F042501;
    address private constant _FEE_COLLECTOR = _OPERATOR;

    address private constant AFCVX_PROXY = 0x8668a15b7b023Dc77B372a740FCb8939E15257Cf;
    address private constant CLEVER_STRATEGY_PROXY = 0xB828a33aF42ab2e8908DfA8C2470850db7e4Fd2a;

    function run() public {

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Deploy Proxy Factory
        SimpleProxyFactory _factory = SimpleProxyFactory(0x156e0382068C3f96a629f51dcF99cEA5250B9eda);

        // Set salt values
        address _deployer = vm.envAddress("DEPLOYER_ADDRESS");
        bytes32 _lpStrategyProxySalt = bytes32(abi.encodePacked(_deployer, uint96(0x420)));

        // Predict proxy addresses
        address _lpStrategyProxyAddr = _factory.predictDeterministicAddress(_lpStrategyProxySalt);

        // Deploy implementation contracts
        address _afCvxImplementation = address(new AfCvx(address(CLEVER_STRATEGY_PROXY)));
        address _cleverCvxStrategyImplementation = address(new CleverCvxStrategy(address(AFCVX_PROXY), _lpStrategyProxyAddr));
        address _lpStrategyImplementation = address(new LPStrategy());

        // Deploy LPStrategy proxy
        address _lpStrategyProxy = address(LPStrategy(_factory.deployDeterministic(
            _lpStrategyProxySalt,
            address(_lpStrategyImplementation),
            abi.encodeWithSignature("initialize(address)", _OWNER)
        )));
        require(_lpStrategyProxy == _lpStrategyProxyAddr, "predicted wrong lpStrategyProxyAddr proxy address");

        vm.stopBroadcast();

        console.log("=====================================");
        console.log("=====================================");
        console.log("Implementation Addresses:");
        console.log("CleverCvxStrategyImplementation: ", _cleverCvxStrategyImplementation);
        console.log("AfCvxImplementation: ", _afCvxImplementation);
        console.log("LPStrategyImplementation: ", _lpStrategyImplementation);
        console.log("=====================================");
        console.log("Proxy Addresses:");
        console.log("LPStrategyProxy: ", _lpStrategyProxy);
        console.log("=====================================");
        console.log("=====================================");

    }
}

// =====================================
// Implementation Addresses V1:
// CleverCvxStrategyImplementation:  0xE55E68166E45FC24f769d6039CC020d77802D8d9
// AfCvxImplementation:  0xCca90892f22554FAdC0cB652fE4cc26040335319
// =====================================
// Implementation Addresses V2:
// CleverCvxStrategyImplementation:  0xA71021CA12f4A6c0389b7ca6f0a2a2E2FC86426E
// AfCvxImplementation:  0x47D1226489A28Ae7dEe404d7A8Db03d3B21694f8
// =====================================
// Implementation Addresses V3:
// CleverCvxStrategyImplementation:  0xD0F77441B70c84aa3366a9F79F2fD16618739aB0
// AfCvxImplementation:  0x56664FFcCfF6BB282CcA96808AF03d9042e1f799
// =====================================
// =====================================
// Implementation Addresses V4:
// CleverCvxStrategyImplementation: TODO
// AfCvxImplementation: TODO
// LPStrategyImplementation: TODO
// =====================================
// Proxy Addresses:
// CleverCvxStrategyProxy:  0xB828a33aF42ab2e8908DfA8C2470850db7e4Fd2a
// AfCvxProxy:  0x8668a15b7b023Dc77B372a740FCb8939E15257Cf
// LPStrategyProxy: TODO
// =====================================
// Factory Address:
// SimpleProxyFactory:  0x156e0382068C3f96a629f51dcF99cEA5250B9eda
// =====================================
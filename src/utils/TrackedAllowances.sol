// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

struct Allowance {
    address spender;
    address token;
}

/// @author philogy <https://github.com/philogy>
/// @dev Tracks the list of addresses that have received an allowance from this contract
abstract contract TrackedAllowances {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeTransferLib for address;

    /// @dev Derived from `bytes32(uint256(keccak256("afCVX.TrackedAllowances.storage")) - 1)`
    uint256 internal constant TRACKED_ALLOWANCES_SLOT =
        0xcf09ed1c65d3a49ce8ff8c0bdbfb0b548ac50dd4a0bc44a32f5731c431171273;

    struct TrackedAllowanceStorage {
        /// @dev While using extra gas, the enumerable set allows all allowances to be enumerated
        /// atomatically without relying on any additional indexing or log querying. This can be
        /// particularly useful in emergencies when allowances need to be revoked en-mass with minimal
        /// effort.
        EnumerableSet.Bytes32Set allowanceKeys;
        mapping(bytes32 => Allowance) allowances;
    }

    function _emergencyRevokeAllAllowances() internal {
        TrackedAllowanceStorage storage s = _storage();
        uint256 totalAllowances = s.allowanceKeys.length();
        for (uint256 i = 0; i < totalAllowances; i++) {
            bytes32 allowanceKey = s.allowanceKeys.at(i);
            Allowance storage allowance = s.allowances[allowanceKey];
            allowance.token.safeApproveWithRetry(allowance.spender, 0);
        }
        // Could remove keys now that allowance is revoked but want to reduce gas to be spend in
        // emergencies beyond what is directly needed for ease-of-use.
    }

    function _revokeSingleAllowance(Allowance memory allowance) internal {
        TrackedAllowanceStorage storage s = _storage();
        bytes32 allowanceKey = _allowanceKey(allowance);
        s.allowanceKeys.remove(allowanceKey);
        allowance.token.safeApproveWithRetry(allowance.spender, 0);
    }

    function _grantAndTrackInfiniteAllowance(Allowance memory allowance) internal {
        TrackedAllowanceStorage storage s = _storage();
        bytes32 allowanceKey = _allowanceKey(allowance);
        s.allowanceKeys.add(allowanceKey);
        s.allowances[allowanceKey] = allowance;
        allowance.token.safeApproveWithRetry(allowance.spender, type(uint256).max);
    }

    function _allowanceKey(Allowance memory allowance) internal pure returns (bytes32) {
        return keccak256(abi.encode(allowance));
    }

    function _storage() internal pure returns (TrackedAllowanceStorage storage s) {
        /// @solidity memory-safe-assembly
        assembly {
            s.slot := TRACKED_ALLOWANCES_SLOT
        }
    }
}

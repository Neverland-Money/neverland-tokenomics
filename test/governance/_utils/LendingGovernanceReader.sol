// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GovernanceAddressBookReader} from "./GovernanceAddressBookReader.sol";
import {ISafeLike} from "./ISafeLike.sol";

interface ILendingPoolAddressesProviderGov {
    function getACLManager() external view returns (address);
    function getACLAdmin() external view returns (address);
    function owner() external view returns (address);
}

interface ILendingAclManagerView {
    function RISK_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

abstract contract LendingGovernanceReader is GovernanceAddressBookReader {
    struct LendingGovernanceSnapshot {
        address aclAdmin;
        address providerOwner;
        address[] defaultAdminMembers;
        address[] riskAdminMembers;
        address[] aclAdminSafeOwners;
        uint256 aclAdminSafeThreshold;
    }

    function _buildLendingGovernanceSnapshot(GovernanceAddressBook memory addressBook)
        internal
        view
        returns (LendingGovernanceSnapshot memory snapshot)
    {
        ILendingPoolAddressesProviderGov provider =
            ILendingPoolAddressesProviderGov(addressBook.lendingPoolAddressesProvider);
        ILendingAclManagerView aclManager = ILendingAclManagerView(provider.getACLManager());

        snapshot.aclAdmin = provider.getACLAdmin();
        snapshot.providerOwner = provider.owner();
        (snapshot.aclAdminSafeOwners, snapshot.aclAdminSafeThreshold) = _readSafeInfo(snapshot.aclAdmin);

        address[] memory candidates =
            _buildCandidateSet(addressBook, snapshot.aclAdmin, snapshot.providerOwner, snapshot.aclAdminSafeOwners);

        snapshot.defaultAdminMembers = _readRoleMembers(aclManager, bytes32(0), candidates);
        snapshot.riskAdminMembers = _readRoleMembers(aclManager, aclManager.RISK_ADMIN_ROLE(), candidates);
    }

    function _buildCandidateSet(
        GovernanceAddressBook memory addressBook,
        address aclAdmin,
        address providerOwner,
        address[] memory safeOwners
    ) internal pure returns (address[] memory) {
        address[] memory candidates = new address[](7 + safeOwners.length);
        uint256 length;

        length = _pushUnique(candidates, length, addressBook.governanceSafe);
        length = _pushUnique(candidates, length, addressBook.sentinelSafe);
        length = _pushUnique(candidates, length, address(0));
        length = _pushUnique(candidates, length, aclAdmin);
        length = _pushUnique(candidates, length, providerOwner);
        length = _pushUnique(candidates, length, addressBook.governanceTimelock);
        length = _pushUnique(candidates, length, addressBook.riskTimelock);

        for (uint256 i; i < safeOwners.length; ++i) {
            length = _pushUnique(candidates, length, safeOwners[i]);
        }

        address[] memory resized = new address[](length);
        for (uint256 i; i < length; ++i) {
            resized[i] = candidates[i];
        }

        return resized;
    }

    function _readRoleMembers(ILendingAclManagerView aclManager, bytes32 role, address[] memory candidates)
        internal
        view
        returns (address[] memory)
    {
        uint256 count;

        for (uint256 i; i < candidates.length; ++i) {
            if (aclManager.hasRole(role, candidates[i])) {
                ++count;
            }
        }

        address[] memory members = new address[](count);
        uint256 index;
        for (uint256 i; i < candidates.length; ++i) {
            if (aclManager.hasRole(role, candidates[i])) {
                members[index] = candidates[i];
                ++index;
            }
        }

        return members;
    }

    function _readSafeInfo(address maybeSafe) internal view returns (address[] memory owners, uint256 threshold) {
        try ISafeLike(maybeSafe).getOwners() returns (address[] memory safeOwners) {
            owners = safeOwners;
            try ISafeLike(maybeSafe).getThreshold() returns (uint256 safeThreshold) {
                threshold = safeThreshold;
            } catch {}
        } catch {
            owners = new address[](0);
            threshold = 0;
        }
    }

    function _pushUnique(address[] memory candidates, uint256 length, address candidate)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < length; ++i) {
            if (candidates[i] == candidate) {
                return length;
            }
        }

        candidates[length] = candidate;
        return length + 1;
    }

    function _containsAddress(address[] memory values, address expected) internal pure returns (bool) {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] == expected) {
                return true;
            }
        }

        return false;
    }
}

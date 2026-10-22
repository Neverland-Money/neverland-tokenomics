// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {INeverlandUiProvider} from "../../../src/interfaces/INeverlandUiProvider.sol";

import {NeverlandUiProvider} from "../../../src/utils/NeverlandUiProvider.sol";

/**
 * @title MockDustLockReverting
 * @notice Minimal IDustLock stub whose `ownerToNFTokenIdList` REVERTS for a configured index.
 * @dev Exercises the `NeverlandUiEnumerationLibrary.getValidatedOwnedTokenPage` catch path, where a
 *      corrupted raw entry is skipped and the page compacts to the surviving token ids. Every other
 *      read returns benign data so the rest of the dashboard build succeeds.
 */
contract MockDustLockReverting {
    error EnumerationEntryReadReverted();

    uint256 internal _balance;
    uint256 internal _revertIndex;
    bool internal _revertEnabled;
    mapping(uint256 => address) internal _tokenOwnerOverride;

    constructor(uint256 balance_) {
        _balance = balance_;
    }

    function setRevertIndex(uint256 index_) external {
        _revertIndex = index_;
        _revertEnabled = true;
    }

    function setTokenOwner(uint256 tokenId, address owner) external {
        _tokenOwnerOverride[tokenId] = owner;
    }

    function balanceOf(address) external view returns (uint256) {
        return _balance;
    }

    function ownerToNFTokenIdList(address, uint256 index) external view returns (uint256) {
        if (_revertEnabled && index == _revertIndex) {
            revert EnumerationEntryReadReverted();
        }

        // Non-zero, deterministic tokenId for the non-reverting slots (index 0 -> 1001, ...).
        return 1001 + index;
    }

    function locked(uint256) external pure returns (IDustLock.LockedBalance memory) {
        return IDustLock.LockedBalance({amount: 0, effectiveStart: 0, end: 0, isPermanent: false});
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _tokenOwnerOverride[tokenId];

        return owner == address(0) ? address(0xBEEF) : owner;
    }

    function balanceOfNFT(uint256) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title MockRevenueRewardEmpty
 * @notice Minimal IRevenueReward stub: no reward tokens, so `getUserDashboard` skips `earnedRewardsAll`.
 * @dev Only the calls reachable from `getUserDashboard` are implemented; `tokenRewardReceiver` is
 *      consulted by `_getLockInfo` for each tokenId in the page.
 */
contract MockRevenueRewardEmpty {
    function getRewardTokens() external pure returns (address[] memory) {
        return new address[](0);
    }

    function tokenRewardReceiver(uint256) external pure returns (address) {
        return address(0);
    }
}

/**
 * @title NeverlandUiProviderEnumCoverageTest
 * @notice Targets `NeverlandUiEnumerationLibrary.getValidatedOwnedTokenPage`, asserting a reverting
 *         `ownerToNFTokenIdList` entry is skipped and the page compacts to surviving token ids.
 */
contract NeverlandUiProviderEnumCoverageTest is Test {
    MockDustLockReverting internal dustLock;
    MockRevenueRewardEmpty internal revenueReward;
    NeverlandUiProvider internal uiProvider;

    /*
     * Non-zero stand-ins for constructor address-zero guards; these dependencies are not exercised
     * on the getUserDashboard tokenId-enumeration path under test.
     */
    address internal constant DUST_REWARDS_CONTROLLER = address(0xDEAD01);
    address internal constant DUST_HELPER = address(0xDEAD02);
    address internal constant POOL_ADDRESSES_PROVIDER_REGISTRY = address(0xDEAD03);

    function setUp() public {
        // Two tokens in the user's enumeration; index 0 will revert, index 1 succeeds.
        dustLock = new MockDustLockReverting(2);
        revenueReward = new MockRevenueRewardEmpty();

        uiProvider = new NeverlandUiProvider(
            address(dustLock),
            address(revenueReward),
            DUST_REWARDS_CONTROLLER,
            DUST_HELPER,
            POOL_ADDRESSES_PROVIDER_REGISTRY
        );
    }

    /// @notice Sanity: with no reverting index, both enumeration slots carry real tokenIds.
    function test_baseline_dashboardEnumeratesTokenIds() public view {
        INeverlandUiProvider.UserDashboardData memory dash =
            uiProvider.getUserDashboard(address(0xBEEF), 0, type(uint256).max);

        assertEq(dash.tokenIds.length, 2);
        assertEq(dash.tokenIds[0], 1001);
        assertEq(dash.tokenIds[1], 1002);
    }

    /**
     * @notice Drives the enumeration catch path: index zero reverts, so that slot is skipped and the
     *         page compacts to the surviving token id at index one.
     */
    function test_dashboardSkipsRevertingEnumerationEntry() public {
        dustLock.setRevertIndex(0);

        _assertSingleDashboardToken(1002);
    }

    function test_dashboardSkipsStaleEnumerationEntryOwnedByAnotherUser() public {
        dustLock.setTokenOwner(1001, address(0xCAFE));

        _assertSingleDashboardToken(1002);
    }

    /**
     * @notice Pins the raw-offset pagination metadata so a length-based paginator cannot mis-advance.
     *         Index 0 reverts, so the provider scans through it and fills the one-valid-token page
     *         from index 1. `nextRawOffset` advances by scanned raw slots, not `tokenIds.length`.
     */
    function test_dashboardExposesRawOffsetMetadataForCompactedPage() public {
        dustLock.setRevertIndex(0);

        // First page asks for 1 valid token: index 0 reverts, index 1 succeeds.
        INeverlandUiProvider.UserDashboardData memory firstPage = uiProvider.getUserDashboard(address(0xBEEF), 0, 1);

        assertEq(firstPage.tokenIds.length, 1);
        assertEq(firstPage.tokenIds[0], 1002);
        _assertPaginationComplete(firstPage);

        // Advancing by nextRawOffset reaches the bounded end; advancing by tokenIds.length would rescan index 1.
        INeverlandUiProvider.UserDashboardData memory secondPage =
            uiProvider.getUserDashboard(address(0xBEEF), firstPage.nextRawOffset, 1);

        assertEq(secondPage.tokenIds.length, 0);
        _assertPaginationComplete(secondPage);
    }

    /**
     * @notice Asserts the terminal pagination metadata shared by compacted pages in this fixture.
     * @param page Dashboard page whose raw enumeration metadata is checked.
     */
    function _assertPaginationComplete(INeverlandUiProvider.UserDashboardData memory page) internal pure {
        assertEq(page.rawTokenCount, 2);
        assertEq(page.nextRawOffset, 2);
        assertFalse(page.hasMore);
    }

    function _assertSingleDashboardToken(uint256 expectedTokenId) internal view {
        INeverlandUiProvider.UserDashboardData memory dash =
            uiProvider.getUserDashboard(address(0xBEEF), 0, type(uint256).max);

        assertEq(dash.tokenIds.length, 1);
        assertEq(dash.tokenIds[0], expectedTokenId);
    }
}

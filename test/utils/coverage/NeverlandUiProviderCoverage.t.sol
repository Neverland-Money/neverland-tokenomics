// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolDataProvider.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IDustRewardsController} from "../../../src/interfaces/IDustRewardsController.sol";
import {INeverlandDustHelper} from "../../../src/interfaces/INeverlandDustHelper.sol";
import {INeverlandUiProvider} from "../../../src/interfaces/INeverlandUiProvider.sol";

import {NeverlandUiArrayLibrary} from "../../../src/utils/libraries/NeverlandUiArrayLibrary.sol";
import {NeverlandUiEmissionLibrary} from "../../../src/utils/libraries/NeverlandUiEmissionLibrary.sol";
import {NeverlandUiPriceMarketLibrary} from "../../../src/utils/libraries/NeverlandUiPriceMarketLibrary.sol";

import {RevenueReward} from "../../../src/rewards/RevenueReward.sol";
import {NeverlandUiProvider} from "../../../src/utils/NeverlandUiProvider.sol";

import {MockPoolAddressesProviderRegistry} from "../../_utils/MockPoolAddressesProviderRegistry.sol";

contract UiMockERC20 {
    error BalanceReadReverted();

    mapping(address => uint256) internal balances;
    string internal tokenSymbol;
    bool internal revertBalance;

    function setSymbol(string memory value) external {
        tokenSymbol = value;
    }

    function setBalance(address user, uint256 amount) external {
        balances[user] = amount;
    }

    function setRevertBalance(bool value) external {
        revertBalance = value;
    }

    function balanceOf(address user) external view returns (uint256) {
        if (revertBalance) revert BalanceReadReverted();

        return balances[user];
    }

    function symbol() external view returns (string memory) {
        return tokenSymbol;
    }
}

contract UiShortReturnErc20 {
    /// @notice Returns 4 bytes (< 32) for any call so defensive balance reads fail soft.
    fallback() external {
        assembly {
            mstore(0x00, 1)
            return(0x00, 4)
        }
    }
}

contract UiRevertingSymbolToken {
    error SymbolReadReverted();

    function symbol() external pure returns (string memory) {
        revert SymbolReadReverted();
    }
}

contract UiReturnBombErc20 {
    uint256 internal immutable _balance;

    constructor(uint256 balance_) {
        _balance = balance_;
    }

    /// @notice Returns a 512KB payload (first word = balance) to pin bounded returndata copying.
    fallback() external {
        uint256 bal = _balance;

        assembly {
            mstore(0x00, bal)
            return(0x00, 0x80000)
        }
    }
}

contract UiMockDustLock {
    error EnumerationReadReverted();
    error TokenNotMinted();

    address internal immutable dustToken;
    mapping(address => uint256[]) internal ownedTokens;
    mapping(uint256 => IDustLock.LockedBalance) internal locks;
    mapping(uint256 => address) internal owners;
    mapping(uint256 => uint256) internal votingPower;
    mapping(address => mapping(uint256 => bool)) internal revertEnumerationAt;
    uint256 internal maxTokenId = 9;
    bool internal revertEnumeration;

    constructor(address dustToken_) {
        dustToken = dustToken_;
    }

    function setOwnedTokens(address user, uint256[] memory tokenIds) external {
        ownedTokens[user] = tokenIds;
        for (uint256 i; i < tokenIds.length; ++i) {
            owners[tokenIds[i]] = user;
        }
    }

    function setOwner(uint256 id, address owner) external {
        owners[id] = owner;
    }

    function setLock(uint256 id, uint256 amount, uint256 end, bool permanent, uint256 power) external {
        locks[id] = IDustLock.LockedBalance({
            amount: int128(uint128(amount)), end: end, effectiveStart: block.timestamp, isPermanent: permanent
        });
        votingPower[id] = power;
    }

    function setRevertEnumeration(bool value) external {
        revertEnumeration = value;
    }

    function setRevertEnumerationAt(address user, uint256 index, bool value) external {
        revertEnumerationAt[user][index] = value;
    }

    function setTokenId(uint256 value) external {
        maxTokenId = value;
    }

    function token() external view returns (address) {
        return dustToken;
    }

    function balanceOf(address user) external view returns (uint256) {
        return ownedTokens[user].length;
    }

    function ownerToNFTokenIdList(address user, uint256 index) external view returns (uint256) {
        if (revertEnumeration || revertEnumerationAt[user][index]) revert EnumerationReadReverted();

        return ownedTokens[user][index];
    }

    function locked(uint256 id) external view returns (IDustLock.LockedBalance memory) {
        return locks[id];
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (id == 0 || owners[id] == address(0)) revert TokenNotMinted();

        return owners[id];
    }

    function balanceOfNFT(uint256 id) external view returns (uint256) {
        return votingPower[id];
    }

    function supply() external pure returns (uint256) {
        return 1_000 ether;
    }

    function totalSupplyAt(uint256) external pure returns (uint256) {
        return 500 ether;
    }

    function permanentLockBalance() external pure returns (uint256) {
        return 100 ether;
    }

    function epoch() external pure returns (uint256) {
        return 7;
    }

    function tokenId() external view returns (uint256) {
        return maxTokenId;
    }

    function earlyWithdrawPenalty() external pure returns (uint256) {
        return 5000;
    }

    function minLockAmount() external pure returns (uint256) {
        return 1 ether;
    }
}

contract UiMockRevenueReward {
    error EarnedRewardsReadReverted();
    error ForbiddenTokenId();
    error RewardDistributorReadReverted();
    error RewardTokensLimitExceeded();
    error RewardTokensNotSortedUnique();
    error TokenIdsLimitExceeded();
    error TokenIdsNotSortedUnique();

    uint256 internal constant MAX_TOKENS_VALUE = 20;
    uint256 internal constant MAX_TOKENIDS_VALUE = 200;

    uint256 internal maxTokens = MAX_TOKENS_VALUE;
    uint256 internal maxTokenIds = MAX_TOKENIDS_VALUE;
    address[] internal rewardTokens;
    mapping(address => uint256[]) internal selfRepayTokensByUser;
    mapping(address => uint256) internal totals;
    mapping(address => mapping(uint256 => uint256)) internal earnedByTokenId;
    mapping(address => mapping(uint256 => uint256)) internal rewardsPerEpoch;
    mapping(uint256 => address) internal receivers;
    mapping(address => mapping(address => uint256)) internal pendingByTokenUser;
    address internal vaultFactory;
    bool internal revertEarned;
    bool internal emptyMatrix;
    bool internal shortTotals;
    bool internal revertDistributor;
    uint256 internal forbiddenTokenId;

    function setRewardTokens(address[] memory tokens) external {
        rewardTokens = tokens;
    }

    function setSelfRepayTokens(address user, uint256[] memory tokenIds) external {
        selfRepayTokensByUser[user] = tokenIds;
    }

    function setTotal(address token, uint256 amount) external {
        totals[token] = amount;
    }

    function setEarned(address token, uint256 tokenId, uint256 amount) external {
        earnedByTokenId[token][tokenId] = amount;
    }

    function setEpochReward(address token, uint256 epoch, uint256 amount) external {
        rewardsPerEpoch[token][epoch] = amount;
    }

    function setReceiver(uint256 tokenId, address receiver) external {
        receivers[tokenId] = receiver;
    }

    function setRevertEarned(bool value) external {
        revertEarned = value;
    }

    function setEmptyMatrix(bool value) external {
        emptyMatrix = value;
    }

    function setShortTotals(bool value) external {
        shortTotals = value;
    }

    function setRevertDistributor(bool value) external {
        revertDistributor = value;
    }

    function setForbiddenTokenId(uint256 value) external {
        forbiddenTokenId = value;
    }

    function setMaxCaps(uint256 maxTokens_, uint256 maxTokenIds_) external {
        maxTokens = maxTokens_;
        maxTokenIds = maxTokenIds_;
    }

    function setPendingRewards(address token, address user, uint256 amount) external {
        pendingByTokenUser[token][user] = amount;
    }

    function setUserVaultFactory(address factory) external {
        vaultFactory = factory;
    }

    function MAX_TOKENS() external view returns (uint256) {
        return maxTokens;
    }

    function MAX_TOKENIDS() external view returns (uint256) {
        return maxTokenIds;
    }

    function rewardDistributor() external view returns (address) {
        if (revertDistributor) revert RewardDistributorReadReverted();

        return address(0xD157);
    }

    function totalRewardsPerToken(address token) external view returns (uint256) {
        return totals[token];
    }

    function tokenRewardsPerEpoch(address token, uint256 epoch) external view returns (uint256) {
        return rewardsPerEpoch[token][epoch];
    }

    function tokenRewardReceiver(uint256 tokenId) external view returns (address) {
        return receivers[tokenId];
    }

    function earnedRewardsAll(address[] calldata tokens, uint256[] calldata tokenIds)
        external
        view
        returns (uint256[][] memory matrix, uint256[] memory totalsPerToken)
    {
        if (revertEarned) revert EarnedRewardsReadReverted();
        if (tokens.length > maxTokens) revert RewardTokensLimitExceeded();
        if (tokenIds.length > maxTokenIds) revert TokenIdsLimitExceeded();
        _requireSortedUniqueAddresses(tokens);
        _requireSortedUniqueUint256(tokenIds);
        for (uint256 i; i < tokenIds.length; ++i) {
            if (tokenIds[i] == forbiddenTokenId) revert ForbiddenTokenId();
        }

        uint256 totalsLength = shortTotals && tokens.length != 0 ? tokens.length - 1 : tokens.length;
        totalsPerToken = new uint256[](totalsLength);
        if (emptyMatrix) return (new uint256[][](0), totalsPerToken);

        matrix = new uint256[][](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            matrix[i] = new uint256[](tokens.length);
            for (uint256 j; j < tokens.length; ++j) {
                uint256 amount = earnedByTokenId[tokens[j]][tokenIds[i]];
                matrix[i][j] = amount;
                if (j < totalsLength) totalsPerToken[j] += amount;
            }
        }
    }

    function getRewardTokens() external view returns (address[] memory tokens) {
        return rewardTokens;
    }

    function getUserTokensWithSelfRepayingLoan(address user) external view returns (uint256[] memory tokenIds) {
        return selfRepayTokensByUser[user];
    }

    function pendingRewards(address token, address user) external view returns (uint256) {
        return pendingByTokenUser[token][user];
    }

    function userVaultFactory() external view returns (address) {
        return vaultFactory;
    }

    function _requireSortedUniqueAddresses(address[] calldata tokens) internal pure {
        for (uint256 i = 1; i < tokens.length; ++i) {
            if (tokens[i - 1] >= tokens[i]) revert RewardTokensNotSortedUnique();
        }
    }

    function _requireSortedUniqueUint256(uint256[] calldata tokenIds) internal pure {
        for (uint256 i = 1; i < tokenIds.length; ++i) {
            if (tokenIds[i - 1] >= tokenIds[i]) revert TokenIdsNotSortedUnique();
        }
    }
}

contract UiMockUserVaultFactory {
    mapping(address => address) internal vaults;

    function setUserVault(address user, address vault) external {
        vaults[user] = vault;
    }

    function getUserVault(address user) external view returns (address) {
        return vaults[user];
    }
}

contract UiMockRewardsController {
    error RewardsReadReverted();

    address[] internal rewardTokens;
    address[] internal registeredAssets;
    mapping(address => address) internal strategies;
    mapping(address => mapping(address => mapping(address => uint256))) internal rewardsByAssetUserToken;
    mapping(address => bool) internal revertAsset;

    function setRewardTokens(address[] memory tokens) external {
        rewardTokens = tokens;
    }

    function setRegisteredAssets(address[] memory assets) external {
        registeredAssets = assets;
    }

    function setStrategy(address reward, address strategy) external {
        strategies[reward] = strategy;
    }

    function setUserReward(address asset, address user, address rewardToken, uint256 amount) external {
        rewardsByAssetUserToken[asset][user][rewardToken] = amount;
    }

    function setAssetRevert(address asset, bool value) external {
        revertAsset[asset] = value;
    }

    function getRewardsList() external view returns (address[] memory) {
        return rewardTokens;
    }

    function getAssetsList() external view returns (address[] memory) {
        return registeredAssets;
    }

    function getTransferStrategy(address reward) external view returns (address) {
        return strategies[reward];
    }

    function getUserRewards(address[] calldata assets, address user, address rewardToken)
        external
        view
        returns (uint256)
    {
        if (revertAsset[assets[0]]) revert RewardsReadReverted();

        return rewardsByAssetUserToken[assets[0]][user][rewardToken];
    }

    function getAllUserRewards(address[] calldata assets, address user)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256[] memory amounts = new uint256[](rewardTokens.length);
        for (uint256 a; a < assets.length; ++a) {
            if (revertAsset[assets[a]]) revert RewardsReadReverted();

            for (uint256 r; r < rewardTokens.length; ++r) {
                amounts[r] += rewardsByAssetUserToken[assets[a]][user][rewardTokens[r]];
            }
        }

        return (rewardTokens, amounts);
    }
}

contract UiMockDustHelper {
    uint256 internal price = 25_000_000;
    uint256 internal timestamp = 1234;

    function setPrice(uint256 value) external {
        price = value;
    }

    function getPrice() external view returns (uint256, bool) {
        return (price, false);
    }

    function latestTimestamp() external view returns (uint256) {
        return timestamp;
    }

    function getDustValueInUSD(uint256 amount) external view returns (uint256) {
        return (amount * price) / 1e18;
    }
}

contract UiMockAddressesProvider {
    error MarketIdReadReverted();
    error PoolDataProviderReadReverted();

    address internal dataProvider;
    address internal oracle;
    string internal marketId;
    bool internal revertDataProvider;
    bool internal revertMarketId;

    function setMarketId(string memory value) external {
        marketId = value;
    }

    function setPoolDataProvider(address value) external {
        dataProvider = value;
    }

    function setPriceOracle(address value) external {
        oracle = value;
    }

    function setRevertMarketId(bool value) external {
        revertMarketId = value;
    }

    function setRevertPoolDataProvider(bool value) external {
        revertDataProvider = value;
    }

    function getMarketId() external view returns (string memory) {
        if (revertMarketId) revert MarketIdReadReverted();

        return marketId;
    }

    function getPoolDataProvider() external view returns (address) {
        if (revertDataProvider) revert PoolDataProviderReadReverted();

        return dataProvider;
    }

    function getPriceOracle() external view returns (address) {
        return oracle;
    }
}

contract UiMockPoolDataProvider {
    error ReserveEnumerationReverted();
    error ReserveTokensReadReverted();

    IPoolDataProvider.TokenData[] internal reserves;
    mapping(address => address) internal aTokens;
    mapping(address => address) internal variableDebtTokens;
    mapping(address => bool) internal revertReserve;
    bool internal revertReserves;

    function setReserve(address underlying, string memory symbol, address aToken, address variableDebtToken) external {
        reserves.push(IPoolDataProvider.TokenData({symbol: symbol, tokenAddress: underlying}));
        aTokens[underlying] = aToken;
        variableDebtTokens[underlying] = variableDebtToken;
    }

    function setReserveRevert(address underlying, bool value) external {
        revertReserve[underlying] = value;
    }

    function setReservesRevert(bool value) external {
        revertReserves = value;
    }

    function clearReserves() external {
        delete reserves;
    }

    function getAllReservesTokens() external view returns (IPoolDataProvider.TokenData[] memory) {
        if (revertReserves) revert ReserveEnumerationReverted();

        return reserves;
    }

    function getReserveTokensAddresses(address asset) external view returns (address, address, address) {
        if (revertReserve[asset]) revert ReserveTokensReadReverted();

        return (aTokens[asset], address(0), variableDebtTokens[asset]);
    }
}

contract UiMockPriceOracle {
    error AssetPriceReadReverted();
    error BaseCurrencyUnitReadReverted();

    uint256 internal unit = 1e18;
    mapping(address => uint256) internal prices;
    bool internal revertUnit;
    bool internal revertPrice;

    function setUnit(uint256 value) external {
        unit = value;
    }

    function setPrice(address token, uint256 value) external {
        prices[token] = value;
    }

    function setRevertUnit(bool value) external {
        revertUnit = value;
    }

    function setRevertPrice(bool value) external {
        revertPrice = value;
    }

    function BASE_CURRENCY_UNIT() external view returns (uint256) {
        if (revertUnit) revert BaseCurrencyUnitReadReverted();

        return unit;
    }

    function getAssetPrice(address token) external view returns (uint256) {
        if (revertPrice) revert AssetPriceReadReverted();

        return prices[token];
    }
}

contract NeverlandUiProviderHarness is NeverlandUiProvider {
    constructor(
        address dustLock,
        address revenueReward,
        address rewardsController,
        address dustHelper,
        address addressesProvider
    ) NeverlandUiProvider(dustLock, revenueReward, rewardsController, dustHelper, addressesProvider) {}

    function exposedSortAndDedupAddresses(address[] memory arr) external pure returns (address[] memory) {
        return NeverlandUiArrayLibrary.sortAndDedupAddresses(arr);
    }
}

contract NeverlandUiProviderCoverageTest is Test {
    using stdJson for string;

    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    string internal constant UI_PROVIDER_ARTIFACT = "out/NeverlandUiProvider.sol/NeverlandUiProvider.json";
    string internal constant UI_REWARDS_SUMMARY_ARTIFACT =
        "out/NeverlandUiRewardsSummaryLibrary.sol/NeverlandUiRewardsSummaryLibrary.json";
    string internal constant UI_EMISSION_LIBRARY_SOURCE = "src/utils/libraries/NeverlandUiEmissionLibrary.sol";
    string internal constant UI_ENUMERATION_LIBRARY_SOURCE = "src/utils/libraries/NeverlandUiEnumerationLibrary.sol";
    string internal constant UI_PRICE_MARKET_LIBRARY_SOURCE = "src/utils/libraries/NeverlandUiPriceMarketLibrary.sol";
    string internal constant UI_REWARDS_SUMMARY_LIBRARY_SOURCE =
        "src/utils/libraries/NeverlandUiRewardsSummaryLibrary.sol";
    address internal constant PENDLE_AUSD_POOL_ADDRESSES_PROVIDER = 0xb80397A931FcFdA3aC999a3a5639C328Dc72A58F;

    address internal user = makeAddr("user");
    UiMockERC20 internal dust;
    UiMockERC20 internal rewardA;
    UiMockERC20 internal rewardB;
    UiMockERC20 internal aToken;
    UiMockERC20 internal debtToken;
    UiMockDustLock internal dustLock;
    UiMockRevenueReward internal revenueReward;
    UiMockRewardsController internal rewardsController;
    UiMockDustHelper internal dustHelper;
    UiMockAddressesProvider internal addressesProvider;
    UiMockPoolDataProvider internal dataProvider;
    UiMockPriceOracle internal priceOracle;
    MockPoolAddressesProviderRegistry internal poolRegistry;
    NeverlandUiProviderHarness internal uiProvider;

    function setUp() public {
        dust = new UiMockERC20();
        rewardA = new UiMockERC20();
        rewardB = new UiMockERC20();
        aToken = new UiMockERC20();
        debtToken = new UiMockERC20();
        dustLock = new UiMockDustLock(address(dust));
        revenueReward = new UiMockRevenueReward();
        rewardsController = new UiMockRewardsController();
        dustHelper = new UiMockDustHelper();
        addressesProvider = new UiMockAddressesProvider();
        dataProvider = new UiMockPoolDataProvider();
        priceOracle = new UiMockPriceOracle();
        // Register addressesProvider at id one so it resolves as the suite's canonical market.
        poolRegistry = new MockPoolAddressesProviderRegistry();
        poolRegistry.registerAddressesProvider(address(addressesProvider), 1);

        uiProvider = new NeverlandUiProviderHarness(
            address(dustLock),
            address(revenueReward),
            address(rewardsController),
            address(dustHelper),
            address(poolRegistry)
        );

        _seedCoreState();
    }

    function testProviderArtifactFitsEip170WithLinkedLibraries() public view {
        string memory artifact = vm.readFile(UI_PROVIDER_ARTIFACT);

        assertLe(_artifactRuntimeSize(artifact), EIP_170_RUNTIME_LIMIT);
        string[] memory linkedSources = vm.parseJsonKeys(artifact, ".deployedBytecode.linkReferences");
        assertEq(linkedSources.length, 4, "unexpected provider direct-library link set");
        assertTrue(
            _containsString(linkedSources, UI_EMISSION_LIBRARY_SOURCE), "missing emission library link reference"
        );
        assertTrue(
            _containsString(linkedSources, UI_ENUMERATION_LIBRARY_SOURCE), "missing enumeration library link reference"
        );
        assertTrue(
            _containsString(linkedSources, UI_PRICE_MARKET_LIBRARY_SOURCE),
            "missing price-market library link reference"
        );
        assertTrue(
            _containsString(linkedSources, UI_REWARDS_SUMMARY_LIBRARY_SOURCE),
            "missing rewards-summary library link reference"
        );

        string memory summaryArtifact = vm.readFile(UI_REWARDS_SUMMARY_ARTIFACT);
        string[] memory summaryLinkedSources = vm.parseJsonKeys(summaryArtifact, ".deployedBytecode.linkReferences");
        assertEq(summaryLinkedSources.length, 1, "unexpected rewards-summary nested-library link set");
        assertTrue(
            _containsString(summaryLinkedSources, UI_EMISSION_LIBRARY_SOURCE),
            "missing rewards-summary nested emission link reference"
        );
    }

    function testEmissionLibraryDirectAssetEnumerators() public view {
        IDustRewardsController controller = IDustRewardsController(address(rewardsController));
        IPoolAddressesProvider provider = IPoolAddressesProvider(address(addressesProvider));
        address[] memory providers = new address[](2);
        providers[0] = address(provider);
        providers[1] = PENDLE_AUSD_POOL_ADDRESSES_PROVIDER;

        /*
         * PENDLE_AUSD_POOL_ADDRESSES_PROVIDER has no code in this test, so it is a no-code enumeration
         * failure rather than a healthy empty market. Both returned assets come from providers[0].
         */
        (address[] memory assets, bool assetsEnumerationResolved) =
            NeverlandUiEmissionLibrary.getAllLendingPoolAssets(controller, providers);

        assertEq(assets.length, 2);
        assertEq(assets[0], address(aToken));
        assertEq(assets[1], address(debtToken));
        assertFalse(assetsEnumerationResolved, "no-code providers[1] makes the aggregate unresolved");

        (NeverlandUiEmissionLibrary.AssetData[] memory assetData, bool assetDataEnumerationResolved) =
            NeverlandUiEmissionLibrary.getAllLendingPoolAssetData(controller, providers);

        assertEq(assetData.length, 2);
        assertFalse(assetDataEnumerationResolved, "no-code providers[1] makes the aggregate unresolved");
        assertEq(assetData[0].asset, address(aToken));
        assertFalse(assetData[0].isDebt);
        assertEq(assetData[1].asset, address(debtToken));
        assertTrue(assetData[1].isDebt);
    }

    function testUserBundleSortingSrlAndEmissionBreakdown() public {
        assertEq(uiProvider.getUserTokenCount(user), 2);
        assertEq(uiProvider.getUserTokenCount(makeAddr("emptyUser")), 0);

        vm.expectRevert();
        uiProvider.getUserTokenCount(address(0));

        INeverlandUiProvider.UserDashboardData memory dashboard = uiProvider.getUserDashboard(user, 0, 10);

        assertEq(dashboard.tokenIds.length, 2);

        INeverlandUiProvider.UserRewardsSummary memory summary = _assertDefaultRevenueSummary();

        assertEq(summary.totalEmissions.length, 2);

        _getCanonicalEmissionBreakdown(address(rewardA), 2);

        (INeverlandUiProvider.UserEmissionAsset[] memory breakdown,) =
            uiProvider.getUserEmissionBreakdown(user, address(rewardB));

        assertEq(breakdown[0].amount, 101);
        assertEq(breakdown[1].amount, 202);

        (address[] memory emissionTokens, uint256[] memory totalRewards,,,) = uiProvider.getUserEmissions(user);

        assertEq(emissionTokens.length, 1);
        assertEq(totalRewards[0], 33);

        INeverlandUiProvider.UiFullBundle memory bundle = uiProvider.getUiFullBundle(user, 0, 10);

        assertEq(bundle.essential.user.tokenIds.length, 2);
        assertEq(bundle.extended.unlockSchedule.tokenIds.length, 1);
        assertEq(bundle.extended.unlockSchedule.tokenIds[0], 2);
    }

    function _artifactRuntimeSize(string memory artifact) internal pure returns (uint256) {
        bytes memory runtimeHex = bytes(artifact.readString(".deployedBytecode.object"));
        if (runtimeHex.length <= 2) return 0;

        uint256 prefixLength = runtimeHex[0] == "0" && (runtimeHex[1] == "x" || runtimeHex[1] == "X") ? 2 : 0;

        return (runtimeHex.length - prefixLength) / 2;
    }

    function _containsString(string[] memory values, string memory needle) internal pure returns (bool) {
        bytes32 needleHash = keccak256(bytes(needle));
        for (uint256 i; i < values.length;) {
            if (keccak256(bytes(values[i])) == needleHash) return true;
            unchecked {
                ++i;
            }
        }

        return false;
    }

    function testEmissionsUseControllerRegisteredAssetsOutsideCanonicalPool() public {
        UiMockERC20 isolatedAToken = new UiMockERC20();
        UiMockERC20 isolatedDebtToken = new UiMockERC20();

        address[] memory registeredAssets = new address[](5);
        registeredAssets[0] = address(aToken);
        registeredAssets[1] = address(debtToken);
        registeredAssets[2] = address(isolatedAToken);
        registeredAssets[3] = address(isolatedDebtToken);
        registeredAssets[4] = address(aToken);
        rewardsController.setRegisteredAssets(registeredAssets);
        rewardsController.setUserReward(address(isolatedAToken), user, address(rewardA), 44);
        rewardsController.setUserReward(address(isolatedDebtToken), user, address(rewardA), 55);

        INeverlandUiProvider.UserEmissionAsset[] memory breakdown = _getCanonicalEmissionBreakdown(address(rewardA), 4);
        _assertEmissionRow(breakdown, 2, address(isolatedAToken), 44, "", false);
        _assertEmissionRow(breakdown, 3, address(isolatedDebtToken), 55, "", false);

        _assertRewardAEmissionTotal(132);
    }

    function testEmissionBreakdownFailsSoftForMissingAndRevertingSymbols() public {
        address noCodeAsset = address(0xCAFE);
        UiRevertingSymbolToken revertingSymbolAsset = new UiRevertingSymbolToken();
        address[] memory registeredAssets = new address[](2);
        registeredAssets[0] = noCodeAsset;
        registeredAssets[1] = address(revertingSymbolAsset);
        rewardsController.setRegisteredAssets(registeredAssets);
        rewardsController.setUserReward(noCodeAsset, user, address(rewardA), 7);
        rewardsController.setUserReward(address(revertingSymbolAsset), user, address(rewardA), 8);

        (INeverlandUiProvider.UserEmissionAsset[] memory breakdown,) =
            uiProvider.getUserEmissionBreakdown(user, address(rewardA));

        assertEq(breakdown.length, 2);
        _assertEmissionRow(breakdown, 0, noCodeAsset, 7, "", false);
        _assertEmissionRow(breakdown, 1, address(revertingSymbolAsset), 8, "", false);
    }

    function testEmissionsFallbackUnionsPendleAusdPoolAssets() public {
        UiMockAddressesProvider isolatedProviderCode = new UiMockAddressesProvider();
        UiMockPoolDataProvider isolatedDataProvider = new UiMockPoolDataProvider();
        UiMockERC20 isolatedPtAToken = new UiMockERC20();
        UiMockERC20 isolatedAusdAToken = new UiMockERC20();
        UiMockERC20 isolatedAusdDebtToken = new UiMockERC20();
        isolatedPtAToken.setSymbol("npPT");
        isolatedAusdAToken.setSymbol("npAUSD");
        isolatedAusdDebtToken.setSymbol("variableDebtNpAUSD");

        vm.etch(PENDLE_AUSD_POOL_ADDRESSES_PROVIDER, address(isolatedProviderCode).code);
        UiMockAddressesProvider(PENDLE_AUSD_POOL_ADDRESSES_PROVIDER).setPoolDataProvider(address(isolatedDataProvider));
        // Registering this second market is what makes the provider include its emission assets.
        poolRegistry.registerAddressesProvider(PENDLE_AUSD_POOL_ADDRESSES_PROVIDER, 2);
        isolatedDataProvider.setReserve(makeAddr("duplicateCanonical"), "DUP", address(aToken), address(0));
        isolatedDataProvider.setReserve(makeAddr("isolatedPT"), "PT", address(isolatedPtAToken), address(0));
        isolatedDataProvider.setReserve(
            makeAddr("isolatedAUSD"), "AUSD", address(isolatedAusdAToken), address(isolatedAusdDebtToken)
        );
        rewardsController.setUserReward(address(isolatedPtAToken), user, address(rewardA), 44);
        rewardsController.setUserReward(address(isolatedAusdAToken), user, address(rewardA), 55);
        rewardsController.setUserReward(address(isolatedAusdDebtToken), user, address(rewardA), 66);

        INeverlandUiProvider.UserEmissionAsset[] memory breakdown = _getCanonicalEmissionBreakdown(address(rewardA), 5);
        _assertEmissionRow(breakdown, 2, address(isolatedPtAToken), 44, "npPT", false);
        _assertEmissionRow(breakdown, 3, address(isolatedAusdAToken), 55, "npAUSD", false);
        _assertEmissionRow(breakdown, 4, address(isolatedAusdDebtToken), 66, "variableDebtNpAUSD", true);

        _assertRewardAEmissionTotal(198);
    }

    function testDashboardRewardSummaryAndEnumerationFallbacks() public {
        revenueReward.setEmptyMatrix(true);

        INeverlandUiProvider.UserDashboardData memory dashboard = uiProvider.getUserDashboard(user, 0, 1);

        assertEq(dashboard.rewardSummaries[0].revenueRewards.length, 2);

        revenueReward.setEmptyMatrix(false);
        revenueReward.setRevertEarned(true);

        dashboard = uiProvider.getUserDashboard(user, 0, 1);

        assertEq(dashboard.rewardSummaries[0].revenueRewards[0], 0);

        INeverlandUiProvider.UserRewardsSummary memory summary = _singleRewardSummary(user, address(rewardA));

        assertEq(summary.totalRevenue[0], 0);

        address[] memory emptyTokens = new address[](0);

        summary = uiProvider.getUserRewardsSummary(makeAddr("emptySummaryUser"), emptyTokens);

        assertEq(summary.totalRevenue.length, 0);
        assertEq(summary.totalEmissions.length, 0);

        address[] memory sortedAddresses = uiProvider.exposedSortAndDedupAddresses(emptyTokens);

        assertEq(sortedAddresses.length, 0);
    }

    function testDashboardScansSparseTailWhenOffsetAtOrPastLiveBalance() public {
        dustLock.setTokenId(100);

        INeverlandUiProvider.UserDashboardData memory dashboard = uiProvider.getUserDashboard(user, 2, 1);

        assertEq(dashboard.rawTokenCount, 2, "live balance");
        assertEq(dashboard.tokenIds.length, 0, "no live token in the scanned tail slice");
        assertGt(dashboard.nextRawOffset, 2, "cursor advances into the sparse tail");
        assertTrue(dashboard.hasMore, "raw tail past the compact balance stays scannable (sparse-tail-open)");
    }

    /// @notice `getUserRewardsSummary` adds receiver-bound deferred (`pendingRewards`) balances to per-token revenue.
    function testUserRewardsSummaryIncludesPendingRewards() public {
        INeverlandUiProvider.UserRewardsSummary memory baseline = _assertDefaultRevenueSummary();

        revenueReward.setPendingRewards(address(rewardA), user, 123);

        INeverlandUiProvider.UserRewardsSummary memory withPending =
            uiProvider.getUserRewardsSummary(user, _tokens2(address(rewardA), address(rewardB)));

        assertEq(withPending.totalRevenue[0] - baseline.totalRevenue[0], 123, "pending added to revenue");
        assertEq(withPending.totalRevenue[1], baseline.totalRevenue[1], "other token unchanged");
    }

    /// @notice `getUserRewardsSummary` folds the user's canonical-vault `pendingRewards` into per-token revenue.
    function testUserRewardsSummaryFoldsVaultPendingRewards() public {
        address vault = _installUserVault();

        INeverlandUiProvider.UserRewardsSummary memory baseline = _assertDefaultRevenueSummary();

        revenueReward.setPendingRewards(address(rewardA), user, 123);
        revenueReward.setPendingRewards(address(rewardA), vault, 77);

        INeverlandUiProvider.UserRewardsSummary memory withPending =
            uiProvider.getUserRewardsSummary(user, _tokens2(address(rewardA), address(rewardB)));

        assertEq(
            withPending.totalRevenue[0] - baseline.totalRevenue[0], 200, "user + vault pending folded into revenue"
        );
        assertEq(withPending.totalRevenue[1], baseline.totalRevenue[1], "other token unchanged");
    }

    function testUserRewardsSummaryFailsSoftWhenRewardsListReverts() public {
        vm.mockCallRevert(
            address(rewardsController),
            abi.encodeWithSignature("getRewardsList()"),
            abi.encodeWithSignature("Error(string)", "list")
        );

        INeverlandUiProvider.UserRewardsSummary memory summary = _assertDefaultRevenueSummary();

        assertEq(summary.totalEmissions[0], 0, "unknown emissions list contributes no guessed amount");
        assertEq(summary.totalEmissions[1], 0, "unknown emissions list contributes no guessed amount");
        assertEq(summary.revenueResolvedMask & 3, 3, "independent revenue rows remain resolved");
        assertEq(summary.emissionsResolvedMask & 3, 0, "unknown emissions membership clears every queried row");
    }

    function testUserRewardsSummaryFailsSoftWhenVaultFactoryReadReverts() public {
        vm.mockCallRevert(
            address(revenueReward),
            abi.encodeWithSignature("userVaultFactory()"),
            abi.encodeWithSignature("Error(string)", "factory")
        );

        INeverlandUiProvider.UserRewardsSummary memory summary = _assertDefaultRevenueSummary();

        assertEq(summary.revenueResolvedMask & 3, 0, "an unknown vault makes every pending total partial");
    }

    function testUserRewardsSummaryFailsSoftWhenUserVaultReadReverts() public {
        UiMockUserVaultFactory factory = new UiMockUserVaultFactory();
        revenueReward.setUserVaultFactory(address(factory));
        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSignature("getUserVault(address)", user),
            abi.encodeWithSignature("Error(string)", "vault")
        );

        INeverlandUiProvider.UserRewardsSummary memory summary = _assertDefaultRevenueSummary();

        assertEq(summary.revenueResolvedMask & 3, 0, "an unresolved vault makes every pending total partial");
    }

    function testUserRewardsSummaryEnumeratesEmissionAssetsOnce() public {
        address[] memory emissionTokens = _tokens2(address(rewardA), address(rewardB));
        address[] memory registeredAssets = _tokens2(address(aToken), address(debtToken));
        rewardsController.setRewardTokens(emissionTokens);
        rewardsController.setRegisteredAssets(registeredAssets);

        vm.expectCall(address(rewardsController), abi.encodeWithSignature("getAssetsList()"), uint64(1));

        INeverlandUiProvider.UserRewardsSummary memory summary = uiProvider.getUserRewardsSummary(user, emissionTokens);

        assertEq(summary.totalEmissions[0], 33);
        assertEq(summary.totalEmissions[1], 303);
        assertEq(summary.emissionsResolvedMask & 3, 3);
    }

    function testUserRewardsSummaryPreservesPartialEmissionsWhenAssetEnumerationIncomplete() public {
        address[] memory emissionTokens = _tokens2(address(rewardA), address(rewardB));
        rewardsController.setRewardTokens(emissionTokens);

        INeverlandUiProvider.UserRewardsSummary memory summary = uiProvider.getUserRewardsSummary(user, emissionTokens);

        assertEq(summary.totalEmissions[0], 33, "readable reward A asset totals preserved");
        assertEq(summary.totalEmissions[1], 303, "readable reward B asset totals preserved");
        assertEq(summary.emissionsResolvedMask & 3, 0, "incomplete shared enumeration clears both matching rows");
    }

    function testUserRewardsSummaryTreatsSuccessfulEmptyEmissionListAsResolvedZero() public {
        rewardsController.setRewardTokens(new address[](0));

        INeverlandUiProvider.UserRewardsSummary memory summary =
            uiProvider.getUserRewardsSummary(user, _tokens2(address(rewardA), address(rewardB)));

        assertEq(summary.totalEmissions[0], 0);
        assertEq(summary.totalEmissions[1], 0);
        assertEq(summary.emissionsResolvedMask & 3, 3, "known non-emission rows are resolved zeros");
    }

    function testProductionRevenueRewardShapeDegradesRatherThanRevertsOnMissingPendingRewardsSelector() public {
        RevenueReward productionRevenueRewardShape = new RevenueReward(address(0));
        (bool selectorExists, bytes memory directRevertData) = address(productionRevenueRewardShape)
            .staticcall(abi.encodeWithSignature("pendingRewards(address,address)", address(rewardA), user));

        assertFalse(selectorExists, "recovered production RevenueReward unexpectedly exposes pendingRewards");
        assertEq(directRevertData.length, 0, "missing selector should return empty revert data");

        NeverlandUiProvider productionProvider = new NeverlandUiProvider(
            address(dustLock),
            address(productionRevenueRewardShape),
            address(rewardsController),
            address(dustHelper),
            address(poolRegistry)
        );
        address[] memory queryTokens = new address[](1);
        queryTokens[0] = address(rewardA);

        /*
         * NeverlandUiRewardsSummaryLibrary wraps pendingRewards in try/catch, so a missing selector
         * degrades that reward-token row rather than reverting the whole summary.
         */
        INeverlandUiProvider.UserRewardsSummary memory summary =
            productionProvider.getUserRewardsSummary(makeAddr("productionShapeUser"), queryTokens);

        assertEq(summary.totalRevenue[0], 0, "missing pendingRewards selector contributes nothing, not a revert");
        assertEq(summary.revenueResolvedMask & 1, 0, "missing pendingRewards selector must flag the row unresolved");
    }

    function testUserRewardsSummarySkipsStaleOwnedEnumerationEntry() public {
        revenueReward.setForbiddenTokenId(1);
        dustLock.setOwner(1, makeAddr("otherOwner"));

        address[] memory queryTokens = _tokens2(address(rewardA), address(rewardB));

        INeverlandUiProvider.UserRewardsSummary memory summary = uiProvider.getUserRewardsSummary(user, queryTokens);

        assertEq(summary.totalRevenue[0], 7);
        assertEq(summary.totalRevenue[1], 15);
    }

    function testUserRewardsSummarySkipsZeroAndRevertingOwnerEntries() public {
        uint256[] memory owned = new uint256[](4);
        owned[0] = 0;
        owned[1] = 1;
        owned[2] = 2;
        owned[3] = 99;
        dustLock.setOwnedTokens(user, owned);
        dustLock.setOwner(99, address(0));
        revenueReward.setForbiddenTokenId(99);

        _assertDefaultRevenueSummary();

        INeverlandUiProvider.UserDashboardData memory dashboard = uiProvider.getUserDashboard(user, 0, 10);

        assertEq(dashboard.tokenIds.length, 2);
        assertEq(dashboard.tokenIds[0], 1);
        assertEq(dashboard.tokenIds[1], 2);
    }

    function testUserRewardsSummarySkipsStaleSrlEntryButKeepsOwnedSrlEntry() public {
        address otherOwner = makeAddr("srlOtherOwner");
        uint256 staleTokenId = 3;
        uint256 validTokenId = 4;
        uint256[] memory srl = new uint256[](2);
        srl[0] = staleTokenId;
        srl[1] = validTokenId;
        revenueReward.setSelfRepayTokens(user, srl);
        dustLock.setOwner(staleTokenId, otherOwner);
        dustLock.setOwner(validTokenId, user);
        revenueReward.setEarned(address(rewardA), staleTokenId, 999);
        revenueReward.setEarned(address(rewardA), validTokenId, 41);

        _assertSingleRewardRevenue(51, "owned rewards plus valid SRL only");
    }

    function testUserRewardsSummaryKeepsBurnedSrlRewardsClaimableToStoredVault() public {
        uint256 burnedTokenId = 5;
        uint256[] memory srl = new uint256[](1);
        srl[0] = burnedTokenId;
        revenueReward.setSelfRepayTokens(user, srl);
        revenueReward.setReceiver(burnedTokenId, makeAddr("burnedTokenVault"));
        revenueReward.setEarned(address(rewardA), burnedTokenId, 41);

        _assertSingleRewardRevenue(51, "owned rewards plus burned SRL salvage rewards");
    }

    function testUserRewardsSummaryReturnsZeroWhenRegisteredRewardsEmpty() public {
        revenueReward.setRewardTokens(new address[](0));

        _assertSingleRewardRevenueZero();
    }

    function testUserRewardsSummaryReturnsZeroWhenRewardPreviewCapsZero() public {
        revenueReward.setMaxCaps(0, revenueReward.MAX_TOKENIDS());

        INeverlandUiProvider.UserRewardsSummary memory summary = _assertSingleRewardRevenueZero();

        assertEq(summary.revenueResolvedMask & 1, 0, "zero reward-token cap cannot be reported resolved");
    }

    function testUserRewardsSummaryClearsRevenueBitWhenTokenIdPreviewCapZero() public {
        revenueReward.setMaxCaps(revenueReward.MAX_TOKENS(), 0);

        INeverlandUiProvider.UserRewardsSummary memory summary = _assertSingleRewardRevenueZero();

        assertEq(summary.revenueResolvedMask & 1, 0, "zero token-id cap cannot be reported resolved");
    }

    function testUserRewardsSummaryClearsOnlyMissingShortTotalsRow() public {
        address firstToken = address(0x100);
        address missingToken = address(0x200);
        address[] memory registeredTokens = _tokens2(firstToken, missingToken);
        revenueReward.setRewardTokens(registeredTokens);
        revenueReward.setEarned(firstToken, 1, 3);
        revenueReward.setEarned(firstToken, 2, 7);
        revenueReward.setEarned(missingToken, 1, 5);
        revenueReward.setEarned(missingToken, 2, 15);
        revenueReward.setShortTotals(true);

        INeverlandUiProvider.UserRewardsSummary memory summary =
            uiProvider.getUserRewardsSummary(user, registeredTokens);

        assertEq(summary.totalRevenue[0], 10, "available aggregate retained");
        assertEq(summary.totalRevenue[1], 0, "missing aggregate remains zero");
        assertEq(summary.revenueResolvedMask & 1, 1, "available aggregate stays resolved");
        assertEq(summary.revenueResolvedMask & 2, 0, "missing aggregate is unresolved");
    }

    function testUnlockScheduleSkipsStaleOwnedEnumerationEntry() public {
        dustLock.setOwner(2, makeAddr("otherOwner"));

        (uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds) =
            uiProvider.getUnlockSchedule(user);

        assertEq(unlockTimes.length, 0);
        assertEq(amounts.length, 0);
        assertEq(tokenIds.length, 0);
    }

    function testUnlockScheduleReadsEachOwnedLockOnceAndPreservesOrder() public {
        uint256[] memory owned = new uint256[](4);
        owned[0] = 4;
        owned[1] = 2;
        owned[2] = 1;
        owned[3] = 5;
        dustLock.setOwnedTokens(user, owned);
        dustLock.setLock(4, 400 ether, block.timestamp + 28 days, true, 40 ether);
        dustLock.setLock(5, 500 ether, block.timestamp + 14 days, false, 50 ether);

        for (uint256 i; i < owned.length; ++i) {
            vm.expectCall(address(dustLock), abi.encodeWithSignature("locked(uint256)", owned[i]), uint64(1));
        }

        (uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds) =
            uiProvider.getUnlockSchedule(user);

        assertEq(tokenIds.length, 2);
        assertEq(tokenIds[0], 2, "first future non-permanent lock follows owned-token order");
        assertEq(tokenIds[1], 5, "second future non-permanent lock follows owned-token order");
        assertEq(unlockTimes[0], block.timestamp + 7 days);
        assertEq(unlockTimes[1], block.timestamp + 14 days);
        assertEq(amounts[0], 200 ether);
        assertEq(amounts[1], 500 ether);
    }

    function testUserRewardsSummaryChunksOversizedRegisteredRewardTokens() public {
        uint256 len = revenueReward.MAX_TOKENS() + 1;
        address[] memory tokens = _sequentialTokens(len);
        revenueReward.setRewardTokens(tokens);
        revenueReward.setEarned(tokens[len - 1], 2, 42);

        INeverlandUiProvider.UserRewardsSummary memory summary = _singleRewardSummary(user, tokens[len - 1]);

        assertEq(summary.totalRevenue[0], 42);
    }

    function testUserRewardsSummaryChunksOversizedRelatedTokenIds() public {
        address bigUser = makeAddr("bigUser");
        uint256 len = revenueReward.MAX_TOKENIDS() + 1;
        uint256[] memory tokenIds = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 tokenId = i + 1;
            tokenIds[i] = tokenId;
            revenueReward.setEarned(address(rewardA), tokenId, 1);
        }
        dustLock.setOwnedTokens(bigUser, tokenIds);

        INeverlandUiProvider.UserRewardsSummary memory summary = _singleRewardSummary(bigUser, address(rewardA));

        assertEq(summary.totalRevenue[0], len);
    }

    function testMetadataAssetsBalanceAndRewardFallbacks() public {
        revenueReward.setRevertDistributor(true);

        INeverlandUiProvider.ProtocolMeta memory meta = uiProvider.getProtocolMeta();

        assertEq(meta.rewardDistributor, address(0));

        addressesProvider.setPoolDataProvider(address(0));

        (INeverlandUiProvider.UserEmissionAsset[] memory breakdown, bool enumerationResolved) =
            uiProvider.getUserEmissionBreakdown(user, address(rewardA));

        assertEq(breakdown.length, 0);
        assertFalse(enumerationResolved, "unset pool data provider is an enumeration failure, not a real empty");

        addressesProvider.setPoolDataProvider(address(dataProvider));

        addressesProvider.setRevertPoolDataProvider(true);

        (breakdown, enumerationResolved) = uiProvider.getUserEmissionBreakdown(user, address(rewardA));

        assertEq(breakdown.length, 0);
        assertFalse(enumerationResolved, "reverting getPoolDataProvider is an enumeration failure");

        addressesProvider.setRevertPoolDataProvider(false);

        dataProvider.setReservesRevert(true);

        (breakdown, enumerationResolved) = uiProvider.getUserEmissionBreakdown(user, address(rewardA));

        assertEq(breakdown.length, 0);
        assertFalse(enumerationResolved, "reverting getAllReservesTokens is an enumeration failure");

        dataProvider.setReservesRevert(false);

        dataProvider.clearReserves();

        (breakdown, enumerationResolved) = uiProvider.getUserEmissionBreakdown(user, address(rewardA));

        assertEq(breakdown.length, 0);
        assertTrue(enumerationResolved, "a pool that genuinely has zero reserves is a real resolved empty");

        (address[] memory emissionTokensNoAssets, uint256[] memory totalsNoAssets, bool noAssetsResolved,,) =
            uiProvider.getUserEmissions(user);

        assertEq(emissionTokensNoAssets.length, rewardsController.getRewardsList().length, "no-asset emission tokens");
        assertTrue(noAssetsResolved, "zero contributing assets is a legitimate resolved zero");
        for (uint256 i; i < totalsNoAssets.length; ++i) {
            assertEq(totalsNoAssets[i], 0, "no-asset emissions zeroed");
        }

        /*
         * _seedReserves configures a second reserve whose token-address read always reverts. This
         * proves one bad reserve preserves resolved assets while correctly marking enumeration incomplete.
         */
        _seedReserves();

        rewardsController.setAssetRevert(address(aToken), true);

        (breakdown, enumerationResolved) = uiProvider.getUserEmissionBreakdown(user, address(rewardA));

        assertEq(breakdown[0].amount, 0);
        assertFalse(breakdown[0].resolved, "a single reverting asset read degrades only that row");
        assertFalse(
            enumerationResolved, "the always-reverting underlyingB reserve makes this provider's enumeration incomplete"
        );
    }

    function testMarketDataReadsBoundedRewardTokenBalances() public {
        UiReturnBombErc20 returnBombToken = new UiReturnBombErc20(77e18);

        address[] memory rewardTokens = _tokens2(address(rewardA), address(returnBombToken));
        revenueReward.setRewardTokens(rewardTokens);
        rewardA.setBalance(address(revenueReward), 11e18);

        INeverlandUiProvider.MarketData memory marketData = uiProvider.getMarketData();

        /*
         * The oversized-return token is still readable (first word = balance) thanks to the bounded
         * one-word returndata copy, so getMarketData reports both real balances.
         */
        assertEq(marketData.rewardTokenBalances.length, 2);
        assertEq(marketData.rewardTokenBalances[0], 11e18);
        assertEq(marketData.rewardTokenBalances[1], 77e18);
    }

    function testMarketDataRevertsOnUnreadableRewardTokenBalance() public {
        UiShortReturnErc20 shortReturnToken = new UiShortReturnErc20();

        address[] memory rewardTokens = _tokens2(address(rewardA), address(shortReturnToken));
        revenueReward.setRewardTokens(rewardTokens);

        /*
         * A short-return reward token surfaces as a hard failure so monitors can detect a
         * dead/non-callable token instead of masking it behind a silent zero balance.
         */
        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandUiProvider.BalanceUnreadable.selector, address(shortReturnToken), address(revenueReward)
            )
        );
        uiProvider.getMarketData();
    }

    function testMarketDataRevertsWhenRewardTokenBalanceReverts() public {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(rewardA);
        revenueReward.setRewardTokens(rewardTokens);
        rewardA.setRevertBalance(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandUiProvider.BalanceUnreadable.selector, address(rewardA), address(revenueReward)
            )
        );
        uiProvider.getMarketData();
    }

    function testPriceFallbackBranches() public {
        INeverlandUiProvider.PriceData memory prices = uiProvider.getAllPrices();

        assertEq(prices.prices[1], 200_000_000);
        assertEq(prices.lastUpdated[1], block.timestamp);

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(dust);
        revenueReward.setRewardTokens(rewardTokens);

        prices = uiProvider.getAllPrices();

        assertEq(prices.prices[1], 25_000_000);

        rewardTokens = _tokens2(address(rewardB), address(rewardA));
        revenueReward.setRewardTokens(rewardTokens);
        priceOracle.setUnit(1e8);
        priceOracle.setPrice(address(rewardB), 300_000_000);

        prices = uiProvider.getAllPrices();

        assertEq(prices.prices[1], 300_000_000);

        addressesProvider.setPriceOracle(address(0));

        _assertRewardPriceUnavailable();

        addressesProvider.setPriceOracle(address(priceOracle));

        priceOracle.setRevertUnit(true);

        _assertRewardPriceUnavailable();

        priceOracle.setRevertUnit(false);

        priceOracle.setUnit(1e18);
        priceOracle.setRevertPrice(true);

        _assertRewardPriceUnavailable();

        priceOracle.setRevertPrice(false);

        priceOracle.setPrice(address(rewardB), 0);

        _assertRewardPriceUnavailable();

        priceOracle.setUnit(0);
        priceOracle.setPrice(address(rewardB), 1e18);

        _assertRewardPriceUnavailable();
    }

    function testZeroDustPriceIsUnresolvedForPricesAndTvl() public {
        dustHelper.setPrice(0);

        INeverlandUiProvider.PriceData memory prices = uiProvider.getAllPrices();
        INeverlandUiProvider.MarketData memory marketData = uiProvider.getMarketData();

        assertEq(prices.prices[0], 0);
        assertEq(prices.lastUpdated[0], 0);
        assertEq(prices.resolvedMask & 1, 0, "zero is the helper's unavailable-price sentinel");
        assertFalse(prices.dustPriceFromOracle);
        assertEq(marketData.totalValueLockedUSD, 0);
        assertFalse(marketData.totalValueLockedUSDResolved, "zero-price conversion is unavailable");
    }

    function testZeroSupplyWithNonzeroDustPriceIsResolvedZeroTvl() public {
        vm.mockCall(address(dustLock), abi.encodeWithSignature("supply()"), abi.encode(uint256(0)));

        INeverlandUiProvider.PriceData memory prices = uiProvider.getAllPrices();
        INeverlandUiProvider.MarketData memory marketData = uiProvider.getMarketData();

        assertEq(prices.prices[0], 25_000_000);
        assertEq(prices.resolvedMask & 1, 1, "nonzero fallback price is usable");
        assertFalse(prices.dustPriceFromOracle, "mock helper reports hardcoded provenance");
        assertEq(marketData.totalValueLockedUSD, 0);
        assertTrue(marketData.totalValueLockedUSDResolved, "zero amount, not missing price, caused the zero TVL");
    }

    /// @notice Market discovery reports each registered provider in registry order with its own label.
    function testRegisteredPoolMarketsListsEveryProviderWithItsLabel() public {
        UiMockAddressesProvider isolatedProvider = new UiMockAddressesProvider();
        addressesProvider.setMarketId("Neverland Market V3");
        isolatedProvider.setMarketId("Neverland Isolated Market");
        poolRegistry.registerAddressesProvider(address(isolatedProvider), 2);

        INeverlandUiProvider.PoolMarket[] memory markets = uiProvider.getRegisteredPoolMarkets();

        assertEq(markets.length, 2);
        assertEq(markets[0].provider, address(addressesProvider));
        assertEq(markets[0].marketId, "Neverland Market V3");
        assertEq(markets[1].provider, address(isolatedProvider));
        assertEq(markets[1].marketId, "Neverland Isolated Market");
    }

    /// @notice A provider whose label read reverts keeps its row with an empty label and hides no other market.
    function testRegisteredPoolMarketsKeepsRowWithEmptyLabelWhenMarketIdReverts() public {
        UiMockAddressesProvider healthyProvider = new UiMockAddressesProvider();
        healthyProvider.setMarketId("Neverland Market V3");
        addressesProvider.setRevertMarketId(true);
        poolRegistry.registerAddressesProvider(address(healthyProvider), 2);

        INeverlandUiProvider.PoolMarket[] memory markets = uiProvider.getRegisteredPoolMarkets();

        assertEq(markets.length, 2);
        assertEq(markets[0].provider, address(addressesProvider));
        assertEq(markets[0].marketId, "", "a reverting label read degrades to an empty label");
        assertEq(markets[1].provider, address(healthyProvider));
        assertEq(markets[1].marketId, "Neverland Market V3", "other markets keep their labels");
    }

    /// @notice An empty registry yields an empty market list instead of reverting.
    function testRegisteredPoolMarketsReturnsEmptyListWhenRegistryIsEmpty() public {
        poolRegistry.unregisterAddressesProvider(address(addressesProvider));

        INeverlandUiProvider.PoolMarket[] memory markets = uiProvider.getRegisteredPoolMarkets();

        assertEq(markets.length, 0);
    }

    /// @notice The direct resolved total sums every readable asset but only resolves when nothing was skipped.
    function testEmissionLibraryResolvedTotalTracksEnumerationAndAssetReads() public {
        // The fixture's second reserve is unreadable, so enumeration is incomplete while the sum stays whole.
        (uint256 total, bool resolved) = _directEmissionRewards(address(rewardA));

        assertEq(total, 33);
        assertFalse(resolved, "incomplete provider enumeration is never resolved");

        // A controller-native asset list is complete by construction, so every read resolves.
        rewardsController.setRegisteredAssets(_tokens2(address(aToken), address(debtToken)));

        (total, resolved) = _directEmissionRewards(address(rewardA));

        assertEq(total, 33);
        assertTrue(resolved);

        rewardsController.setAssetRevert(address(debtToken), true);

        (total, resolved) = _directEmissionRewards(address(rewardA));

        assertEq(total, 11, "readable assets are still summed");
        assertFalse(resolved, "a skipped asset read is never resolved");
    }

    /// @notice A pool with zero reserves is a real resolved zero for the direct emission total.
    function testEmissionLibraryResolvedTotalIsResolvedZeroWhenNoAssets() public {
        dataProvider.clearReserves();

        (uint256 total, bool resolved) = _directEmissionRewards(address(rewardA));

        assertEq(total, 0);
        assertTrue(resolved, "zero assets to query is a legitimate resolved zero");
    }

    /// @notice The token-list variant returns the aggregate on success and the supplied list with zeros on failure.
    function testEmissionLibraryUserEmissionsWithTokensFallsBackToSuppliedList() public {
        address[] memory suppliedTokens = _tokens2(address(rewardA), address(rewardB));

        (address[] memory rewardTokens, uint256[] memory totals) = _directEmissionsWithTokens(suppliedTokens);

        assertEq(rewardTokens.length, 1, "the controller aggregate replaces the supplied list");
        assertEq(rewardTokens[0], address(rewardA));
        assertEq(totals.length, 1);
        assertEq(totals[0], 33);

        rewardsController.setAssetRevert(address(aToken), true);

        (rewardTokens, totals) = _directEmissionsWithTokens(suppliedTokens);

        assertEq(rewardTokens.length, 2, "the supplied list is kept when the aggregate read fails");
        assertEq(rewardTokens[0], address(rewardA));
        assertEq(rewardTokens[1], address(rewardB));
        assertEq(totals.length, 2);
        assertEq(totals[0], 0);
        assertEq(totals[1], 0);
    }

    /// @notice `getUserEmissions` zeroes its totals and reports unresolved when the aggregate rewards read reverts.
    function testUserEmissionsFailSoftWhenAggregateRewardsReadReverts() public {
        // A controller-native asset list resolves enumeration, so only the aggregate read can clear the flag.
        rewardsController.setRegisteredAssets(_tokens2(address(aToken), address(debtToken)));

        (, uint256[] memory totalRewards, bool resolved,,) = uiProvider.getUserEmissions(user);

        assertEq(totalRewards[0], 33);
        assertTrue(resolved);

        rewardsController.setAssetRevert(address(aToken), true);

        address[] memory emissionTokens;
        (emissionTokens, totalRewards, resolved,,) = uiProvider.getUserEmissions(user);

        assertEq(emissionTokens.length, 1);
        assertEq(emissionTokens[0], address(rewardA));
        assertEq(totalRewards[0], 0, "a failed aggregate read is zeroed, not guessed");
        assertFalse(resolved, "a failed aggregate read is unresolved even with complete enumeration");
    }

    /// @notice Direct token pricing resolves DUST through the helper and pool assets through the pool oracle.
    function testPriceMarketLibraryTokenPriceResolvesDustAndPoolAssets() public view {
        _assertTokenPrice(address(dust), 25_000_000, true);
        _assertTokenPrice(address(rewardA), 300_000_000, true);
    }

    /// @notice Every unavailable price source is price zero with resolved false, never a guessed value.
    function testPriceMarketLibraryTokenPriceIsUnresolvedWhenSourceUnavailable() public {
        dustHelper.setPrice(0);

        _assertTokenPrice(address(dust), 0, false);

        addressesProvider.setPriceOracle(address(0));

        _assertTokenPrice(address(rewardA), 0, false);

        addressesProvider.setPriceOracle(address(priceOracle));
        priceOracle.setRevertUnit(true);

        _assertTokenPrice(address(rewardA), 0, false);

        priceOracle.setRevertUnit(false);
        priceOracle.setRevertPrice(true);

        _assertTokenPrice(address(rewardA), 0, false);

        // A raw price that scales below one USD unit is unavailable, not a resolved zero.
        priceOracle.setRevertPrice(false);
        priceOracle.setPrice(address(rewardA), 1);

        _assertTokenPrice(address(rewardA), 0, false);
    }

    /// @notice Direct DUST pricing forwards the helper's source flag; a zero price or a revert is unavailable.
    function testPriceMarketLibraryDustPriceResolved() public {
        _assertDustPrice(25_000_000, true, false);

        vm.mockCall(address(dustHelper), abi.encodeWithSignature("getPrice()"), abi.encode(uint256(30_000_000), true));

        _assertDustPrice(30_000_000, true, true);

        vm.clearMockedCalls();
        vm.mockCall(address(dustHelper), abi.encodeWithSignature("getPrice()"), abi.encode(uint256(0), true));

        _assertDustPrice(0, false, false);

        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(dustHelper),
            abi.encodeWithSignature("getPrice()"),
            abi.encodeWithSignature("Error(string)", "price")
        );

        _assertDustPrice(0, false, false);
    }

    /// @notice The direct DUST timestamp read fails soft to zero when the helper reverts.
    function testPriceMarketLibraryDustLatestTimestampFailsSoftToZero() public {
        assertEq(NeverlandUiPriceMarketLibrary.getDustLatestTimestampOrZero(_helper()), 1234);

        _mockDustTimestampRevert();

        assertEq(NeverlandUiPriceMarketLibrary.getDustLatestTimestampOrZero(_helper()), 0);
    }

    /// @notice The direct DUST value is resolved only when both the price read and the value read succeed.
    function testPriceMarketLibraryDustValueResolvedTracksPriceAndValueReads() public {
        (uint256 value, bool resolved) = NeverlandUiPriceMarketLibrary.getDustValueInUSDResolved(_helper(), 2 ether);

        assertEq(value, 50_000_000);
        assertTrue(resolved);

        dustHelper.setPrice(0);

        (value, resolved) = NeverlandUiPriceMarketLibrary.getDustValueInUSDResolved(_helper(), 2 ether);

        assertEq(value, 0);
        assertFalse(resolved, "an unavailable DUST price leaves the value unresolved");

        dustHelper.setPrice(25_000_000);
        vm.mockCallRevert(
            address(dustHelper),
            abi.encodeWithSignature("getDustValueInUSD(uint256)", 2 ether),
            abi.encodeWithSignature("Error(string)", "value")
        );

        (value, resolved) = NeverlandUiPriceMarketLibrary.getDustValueInUSDResolved(_helper(), 2 ether);

        assertEq(value, 0);
        assertFalse(resolved, "a reverting value read is unresolved even with a usable price");
    }

    /// @notice A resolved DUST price keeps its row but reports a zero timestamp when the timestamp read reverts.
    function testAllPricesReportsZeroDustTimestampWhenTimestampReadReverts() public {
        _mockDustTimestampRevert();

        INeverlandUiProvider.PriceData memory prices = uiProvider.getAllPrices();

        assertEq(prices.prices[0], 25_000_000);
        assertEq(prices.resolvedMask & 1, 1, "the price read itself resolved");
        assertEq(prices.lastUpdated[0], 0, "an unreadable timestamp is reported as zero");
    }

    /// @notice A reverting vault `pendingRewards` read keeps the readable user pending and clears only that row's bit.
    function testUserRewardsSummaryFailsSoftWhenVaultPendingRewardsReverts() public {
        address vault = _installUserVault();
        revenueReward.setPendingRewards(address(rewardA), user, 123);
        revenueReward.setPendingRewards(address(rewardA), vault, 77);
        vm.mockCallRevert(
            address(revenueReward),
            abi.encodeWithSignature("pendingRewards(address,address)", address(rewardA), vault),
            abi.encodeWithSignature("Error(string)", "vault pending")
        );

        INeverlandUiProvider.UserRewardsSummary memory summary =
            uiProvider.getUserRewardsSummary(user, _tokens2(address(rewardA), address(rewardB)));

        assertEq(summary.totalRevenue[0], 10 + 123, "readable user pending counts, unreadable vault does not");
        assertEq(summary.totalRevenue[1], 20, "other rows are unaffected");
        assertEq(summary.revenueResolvedMask & 3, 2, "only the row with the unreadable vault pending is partial");
    }

    /// @notice A 256-token query saturates both resolved masks instead of shifting past the word width.
    function testUserRewardsSummaryResolvedMasksSaturateAtTwoHundredFiftySixRewardTokens() public view {
        INeverlandUiProvider.UserRewardsSummary memory summary =
            uiProvider.getUserRewardsSummary(user, _sequentialTokens(256));

        assertEq(summary.totalRevenue.length, 256);
        assertEq(summary.revenueResolvedMask, type(uint256).max);
        assertEq(summary.emissionsResolvedMask, type(uint256).max);
    }

    function _tokens2(address first, address second) internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = first;
        tokens[1] = second;
    }

    function _assertCanonicalEmissionRows(INeverlandUiProvider.UserEmissionAsset[] memory breakdown) internal view {
        _assertEmissionRow(breakdown, 0, address(aToken), 11, "nA", false);
        _assertEmissionRow(breakdown, 1, address(debtToken), 22, "variableDebtA", true);
    }

    /**
     * @notice Asserts one emission-breakdown row against its expected display and classification data.
     * @param breakdown Emission rows returned by the provider.
     * @param index Row index to inspect.
     * @param expectedAsset Expected emission asset address.
     * @param expectedAmount Expected accrued reward amount.
     * @param expectedSymbol Expected fail-soft asset symbol.
     * @param expectedIsDebt Expected aToken/debt-token classification.
     */
    function _assertEmissionRow(
        INeverlandUiProvider.UserEmissionAsset[] memory breakdown,
        uint256 index,
        address expectedAsset,
        uint256 expectedAmount,
        string memory expectedSymbol,
        bool expectedIsDebt
    ) internal pure {
        assertEq(breakdown[index].asset, expectedAsset);
        assertEq(breakdown[index].amount, expectedAmount);
        assertEq(breakdown[index].symbol, expectedSymbol);
        assertEq(breakdown[index].isDebt, expectedIsDebt);
    }

    function _getCanonicalEmissionBreakdown(address rewardToken, uint256 expectedLength)
        internal
        view
        returns (INeverlandUiProvider.UserEmissionAsset[] memory breakdown)
    {
        (breakdown,) = uiProvider.getUserEmissionBreakdown(user, rewardToken);

        assertEq(breakdown.length, expectedLength);
        _assertCanonicalEmissionRows(breakdown);

        return breakdown;
    }

    function _singleRewardSummary(address account, address rewardToken)
        internal
        view
        returns (INeverlandUiProvider.UserRewardsSummary memory)
    {
        address[] memory queryTokens = new address[](1);
        queryTokens[0] = rewardToken;

        return uiProvider.getUserRewardsSummary(account, queryTokens);
    }

    function _assertDefaultRevenueSummary()
        internal
        view
        returns (INeverlandUiProvider.UserRewardsSummary memory summary)
    {
        address[] memory queryTokens = _tokens2(address(rewardA), address(rewardB));

        summary = uiProvider.getUserRewardsSummary(user, queryTokens);

        assertEq(summary.totalRevenue[0], 10);
        assertEq(summary.totalRevenue[1], 20);
    }

    function _assertRewardAEmissionTotal(uint256 expectedTotal) internal view {
        (address[] memory emissionTokens, uint256[] memory totalRewards,,,) = uiProvider.getUserEmissions(user);

        assertEq(emissionTokens.length, 1);
        assertEq(emissionTokens[0], address(rewardA));
        assertEq(totalRewards[0], expectedTotal);
    }

    function _assertSingleRewardRevenueZero()
        internal
        view
        returns (INeverlandUiProvider.UserRewardsSummary memory summary)
    {
        summary = _singleRewardSummary(user, address(rewardA));

        assertEq(summary.totalRevenue.length, 1);
        assertEq(summary.totalRevenue[0], 0);
    }

    function _assertSingleRewardRevenue(uint256 expectedRevenue, string memory message) internal view {
        INeverlandUiProvider.UserRewardsSummary memory summary = _singleRewardSummary(user, address(rewardA));

        assertEq(summary.totalRevenue[0], expectedRevenue, message);
        assertEq(summary.revenueResolvedMask & 1, 1);
    }

    function _assertRewardPriceUnavailable() internal view {
        INeverlandUiProvider.PriceData memory prices = uiProvider.getAllPrices();

        assertEq(prices.prices[1], 0);
        assertEq(prices.lastUpdated[1], 0);
    }

    /// @notice Returns the fixture DUST helper typed for direct price-library calls.
    function _helper() internal view returns (INeverlandDustHelper) {
        return INeverlandDustHelper(address(dustHelper));
    }

    /// @notice Makes the fixture DUST helper's `latestTimestamp()` read revert.
    function _mockDustTimestampRevert() internal {
        vm.mockCallRevert(
            address(dustHelper),
            abi.encodeWithSignature("latestTimestamp()"),
            abi.encodeWithSignature("Error(string)", "timestamp")
        );
    }

    /**
     * @notice Registers a user vault factory on the RevenueReward mock that maps the fixture user to a vault.
     * @return vault Vault address the factory reports for the fixture user.
     */
    function _installUserVault() internal returns (address vault) {
        UiMockUserVaultFactory factory = new UiMockUserVaultFactory();
        vault = makeAddr("userVault");
        factory.setUserVault(user, vault);
        revenueReward.setUserVaultFactory(address(factory));
    }

    /**
     * @notice Builds a list of distinct synthetic token addresses.
     * @param count Number of addresses to generate.
     * @return tokens Addresses `0xA11CE + i` for every index `i` below `count`.
     */
    function _sequentialTokens(uint256 count) internal pure returns (address[] memory tokens) {
        tokens = new address[](count);
        for (uint256 i; i < count; ++i) {
            tokens[i] = address(uint160(0xA11CE + i));
        }
    }

    /**
     * @notice Asserts one direct `getTokenPriceInUSDResolved` result against its expected price and flag.
     * @param token Token whose USD price is requested from the fixture DUST helper or pool oracle.
     * @param expectedPrice Expected USD price in 8 decimals.
     * @param expectedResolved Expected resolution flag.
     */
    function _assertTokenPrice(address token, uint256 expectedPrice, bool expectedResolved) internal view {
        (uint256 price, bool resolved) = NeverlandUiPriceMarketLibrary.getTokenPriceInUSDResolved(
            IDustLock(address(dustLock)), _helper(), IPoolAddressesProvider(address(addressesProvider)), token
        );

        assertEq(price, expectedPrice);
        assertEq(resolved, expectedResolved);
    }

    /**
     * @notice Asserts one direct `getDustPriceResolved` result against its expected price and flags.
     * @param expectedPrice Expected DUST USD price in 8 decimals.
     * @param expectedResolved Expected resolution flag.
     * @param expectedFromOracle Expected oracle-source flag.
     */
    function _assertDustPrice(uint256 expectedPrice, bool expectedResolved, bool expectedFromOracle) internal view {
        (uint256 price, bool resolved, bool fromOracle) = NeverlandUiPriceMarketLibrary.getDustPriceResolved(_helper());

        assertEq(price, expectedPrice);
        assertEq(resolved, expectedResolved);
        assertEq(fromOracle, expectedFromOracle);
    }

    /**
     * @notice Reads the direct resolved emission total for the fixture user across every registered market.
     * @param rewardToken Reward token whose emission total is read.
     * @return total Emission rewards summed over the enumerated assets.
     * @return resolved True when enumeration and every asset read resolved.
     */
    function _directEmissionRewards(address rewardToken) internal view returns (uint256 total, bool resolved) {
        return NeverlandUiEmissionLibrary.getUserEmissionRewardsResolved(
            IDustRewardsController(address(rewardsController)),
            poolRegistry.getAddressesProvidersList(),
            user,
            rewardToken
        );
    }

    /**
     * @notice Reads the direct token-list emission aggregate for the fixture user across every registered market.
     * @param suppliedTokens Reward-token list handed to the library as its fail-soft fallback.
     * @return rewardTokens The controller's aggregate token list, or `suppliedTokens` when the aggregate read failed.
     * @return totals Totals aligned with `rewardTokens`.
     */
    function _directEmissionsWithTokens(address[] memory suppliedTokens)
        internal
        view
        returns (address[] memory rewardTokens, uint256[] memory totals)
    {
        return NeverlandUiEmissionLibrary.getUserEmissionsWithTokens(
            IDustRewardsController(address(rewardsController)),
            poolRegistry.getAddressesProvidersList(),
            user,
            suppliedTokens
        );
    }

    function _seedCoreState() internal {
        address[] memory rewardTokens = _tokens2(address(rewardB), address(rewardA));
        revenueReward.setRewardTokens(rewardTokens);
        rewardA.setBalance(address(revenueReward), 1_000);
        rewardB.setBalance(address(revenueReward), 2_000);
        revenueReward.setTotal(address(rewardA), 10);
        revenueReward.setTotal(address(rewardB), 20);
        revenueReward.setEarned(address(rewardA), 1, 3);
        revenueReward.setEarned(address(rewardA), 2, 7);
        revenueReward.setEarned(address(rewardB), 1, 5);
        revenueReward.setEarned(address(rewardB), 2, 15);
        revenueReward.setEpochReward(address(rewardA), 0, 3);
        revenueReward.setEpochReward(address(rewardB), 0, 4);
        revenueReward.setReceiver(1, user);
        revenueReward.setReceiver(2, user);

        uint256[] memory owned = new uint256[](2);
        owned[0] = 2;
        owned[1] = 1;
        dustLock.setOwnedTokens(user, owned);
        dustLock.setLock(2, 200 ether, block.timestamp + 7 days, false, 20 ether);
        dustLock.setLock(1, 100 ether, block.timestamp - 1, false, 10 ether);

        uint256[] memory srl = new uint256[](2);
        srl[0] = 2;
        srl[1] = 3;
        revenueReward.setSelfRepayTokens(user, srl);

        address[] memory emissionTokens = new address[](1);
        emissionTokens[0] = address(rewardA);
        rewardsController.setRewardTokens(emissionTokens);
        rewardsController.setStrategy(address(rewardA), makeAddr("strategy"));
        rewardsController.setUserReward(address(aToken), user, address(rewardA), 11);
        rewardsController.setUserReward(address(debtToken), user, address(rewardA), 22);
        rewardsController.setUserReward(address(aToken), user, address(rewardB), 101);
        rewardsController.setUserReward(address(debtToken), user, address(rewardB), 202);
        aToken.setSymbol("nA");
        debtToken.setSymbol("variableDebtA");

        _seedReserves();
        addressesProvider.setPoolDataProvider(address(dataProvider));
        addressesProvider.setPriceOracle(address(priceOracle));
        priceOracle.setPrice(address(rewardA), 3e18);
        priceOracle.setPrice(address(rewardB), 2e18);
    }

    function _seedReserves() internal {
        address underlyingA = makeAddr("underlyingA");
        address underlyingB = makeAddr("underlyingB");
        dataProvider.setReserve(underlyingA, "A", address(aToken), address(debtToken));
        dataProvider.setReserve(underlyingB, "B", address(0), address(0));
        dataProvider.setReserveRevert(underlyingB, true);
    }
}

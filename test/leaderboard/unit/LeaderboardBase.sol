// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {EpochManager} from "../../../src/leaderboard/EpochManager.sol";
import {LeaderboardConfig} from "../../../src/leaderboard/LeaderboardConfig.sol";
import {NFTPartnershipRegistry} from "../../../src/leaderboard/NFTPartnershipRegistry.sol";
import {VotingPowerMultiplier} from "../../../src/leaderboard/VotingPowerMultiplier.sol";
import {Dust} from "../../../src/tokens/Dust.sol";
import {DustLock} from "../../../src/tokens/DustLock.sol";

import {BaseTest} from "../../BaseTest.sol";
import {MockERC721} from "../../_utils/MockERC721.sol";

/**
 * @title LeaderboardBase
 * @author Neverland
 * @notice Lean shared fixture for leaderboard tests without Aave or self-repay deployments
 */
abstract contract LeaderboardBase is BaseTest {
    Dust internal DUST;
    IDustLock internal dustLock;
    ProxyAdmin public proxyAdmin;

    EpochManager internal epochManager;
    LeaderboardConfig internal leaderboardConfig;
    NFTPartnershipRegistry internal nftRegistry;
    VotingPowerMultiplier internal vpMultiplier;

    MockERC721 internal nftCollection1;
    MockERC721 internal nftCollection2;
    MockERC721 internal nftCollection3;

    // Test constants
    uint256 constant DEPOSIT_RATE = 100; // 0.01 per USD/day
    uint256 constant BORROW_RATE = 500; // 0.05 per USD/day
    uint256 constant VP_RATE = 200; // 0.02 per veDUST/day
    uint256 constant SUPPLY_BONUS = 10e18; // 10 points/day
    uint256 constant BORROW_BONUS = 20e18; // 20 points/day
    uint256 constant COOLDOWN = 3600; // 1 hour
    uint256 constant MIN_DAILY_BONUS_USD = 100e18; // $100

    uint256 constant FIRST_BONUS = 1000; // 0.1 (10%)
    uint256 constant DECAY_RATIO = 9000; // 0.9 (90%)

    /**
     * @notice Deploys the DUST, DustLock, and leaderboard fixtures used by leaderboard tests.
     */
    function _testSetup() internal virtual override {
        _testSetUpDust();
        _testSetupLeaderboard();
    }

    /**
     * @notice Deploys the minimal DUST and DustLock fixtures needed for voting-power tests.
     */
    function _testSetUpDust() internal {
        // Seed setup with initial time.
        skip(1 weeks);

        Dust dustImpl = new Dust();
        proxyAdmin = new ProxyAdmin();
        DUST = Dust(_deployProxy(address(dustImpl)));
        DUST.initialize(admin, 0);

        string memory baseUrl = "https://neverland.money/nfts/";
        DustLock dustLockImpl = new DustLock(FORWARDER);
        dustLock = IDustLock(_deployProxy(address(dustLockImpl)));
        DustLock(address(dustLock)).initialize(FORWARDER, address(DUST), baseUrl);

        vm.label(address(DUST), "DUST");
        vm.label(address(dustLock), "DustLock");
    }

    /**
     * @notice Deploys the leaderboard contract fixtures and partner NFT mocks.
     */
    function _testSetupLeaderboard() internal {
        // Deploy EpochManager (Upgradeable)
        EpochManager epochManagerImpl = new EpochManager();
        TransparentUpgradeableProxy epochManagerProxy =
            new TransparentUpgradeableProxy(address(epochManagerImpl), address(proxyAdmin), "");
        epochManager = EpochManager(address(epochManagerProxy));
        epochManager.initialize(admin);

        // Deploy LeaderboardConfig (Upgradeable)
        LeaderboardConfig leaderboardConfigImpl = new LeaderboardConfig();
        TransparentUpgradeableProxy leaderboardConfigProxy =
            new TransparentUpgradeableProxy(address(leaderboardConfigImpl), address(proxyAdmin), "");
        leaderboardConfig = LeaderboardConfig(address(leaderboardConfigProxy));
        leaderboardConfig.initialize(
            admin, DEPOSIT_RATE, BORROW_RATE, VP_RATE, SUPPLY_BONUS, BORROW_BONUS, 0, 0, COOLDOWN, MIN_DAILY_BONUS_USD
        );

        // Deploy NFTPartnershipRegistry (Upgradeable)
        NFTPartnershipRegistry nftRegistryImpl = new NFTPartnershipRegistry();
        TransparentUpgradeableProxy nftRegistryProxy =
            new TransparentUpgradeableProxy(address(nftRegistryImpl), address(proxyAdmin), "");
        nftRegistry = NFTPartnershipRegistry(address(nftRegistryProxy));
        nftRegistry.initialize(admin, FIRST_BONUS, DECAY_RATIO);

        // Deploy VotingPowerMultiplier (Upgradeable)
        VotingPowerMultiplier vpMultiplierImpl = new VotingPowerMultiplier(address(dustLock));
        TransparentUpgradeableProxy vpMultiplierProxy =
            new TransparentUpgradeableProxy(address(vpMultiplierImpl), address(proxyAdmin), "");
        vpMultiplier = VotingPowerMultiplier(address(vpMultiplierProxy));
        vpMultiplier.initialize(admin);

        // Deploy mock NFT collections
        nftCollection1 = new MockERC721("Collection1", "C1");
        nftCollection2 = new MockERC721("Collection2", "C2");
        nftCollection3 = new MockERC721("Collection3", "C3");

        // Labels
        vm.label(address(epochManager), "EpochManager");
        vm.label(address(leaderboardConfig), "LeaderboardConfig");
        vm.label(address(nftRegistry), "NFTPartnershipRegistry");
        vm.label(address(vpMultiplier), "VotingPowerMultiplier");
        vm.label(address(nftCollection1), "NFTCollection1");
        vm.label(address(nftCollection2), "NFTCollection2");
        vm.label(address(nftCollection3), "NFTCollection3");
    }

    /**
     * @notice Mints a mock NFT to a test user.
     * @param collection Mock NFT collection to mint from
     * @param to Recipient address
     * @param tokenId Token ID to mint
     */
    function _mintNFT(MockERC721 collection, address to, uint256 tokenId) internal {
        collection.mint(to, tokenId);
    }

    /**
     * @notice Locks DUST for a user and returns the created veNFT token ID.
     * @param user User creating the lock
     * @param amount Amount of DUST to lock
     * @param duration Lock duration
     * @return tokenId Created DustLock veNFT token ID
     */
    function _lockDust(address user, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        deal(address(DUST), user, amount);

        vm.startPrank(user);
        DUST.approve(address(dustLock), amount);
        tokenId = dustLock.createLock(amount, duration);
        vm.stopPrank();
    }

    /**
     * @notice Deploys a TransparentUpgradeableProxy for a test implementation.
     * @param implementation Implementation contract address
     * @return Proxy address
     */
    function _deployProxy(address implementation) internal returns (address) {
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, address(proxyAdmin), "");
        return address(proxy);
    }
}

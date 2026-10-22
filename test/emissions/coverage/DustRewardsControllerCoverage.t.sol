// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IScaledBalanceToken} from "@aave/core-v3/contracts/interfaces/IScaledBalanceToken.sol";
import {IEACAggregatorProxy} from "@aave-v3-periphery/contracts/misc/interfaces/IEACAggregatorProxy.sol";
import {ITransferStrategyBase} from "@aave-v3-periphery/contracts/rewards/interfaces/ITransferStrategyBase.sol";
import {RewardsDataTypes} from "@aave-v3-periphery/contracts/rewards/libraries/RewardsDataTypes.sol";

import {DustRewardsController} from "../../../src/emissions/DustRewardsController.sol";
import {DustTransferStrategyBase} from "../../../src/emissions/DustTransferStrategyBase.sol";
import {IDustRewardsController} from "../../../src/interfaces/IDustRewardsController.sol";
import {IDustTransferStrategy} from "../../../src/interfaces/IDustTransferStrategy.sol";

import {Test} from "forge-std/Test.sol";

contract CoverageScaledToken is ERC20, IScaledBalanceToken {
    uint256 public constant MOCK_LIQUIDITY_INDEX = 1e27;

    mapping(address => uint256) private _previousIndex;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return balanceOf(user);
    }

    function getScaledUserBalanceAndSupply(address user) external view returns (uint256, uint256) {
        return (balanceOf(user), totalSupply());
    }

    function scaledTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    function getPreviousIndex(address user) external view returns (uint256) {
        return _previousIndex[user];
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);

        if (amount == 0) return;
        if (from != address(0)) _previousIndex[from] = MOCK_LIQUIDITY_INDEX;
        if (to != address(0)) _previousIndex[to] = MOCK_LIQUIDITY_INDEX;
    }
}

contract CoverageRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CoverageDustTransferStrategy is DustTransferStrategyBase {
    bool internal shouldSucceed = true;
    address public lastTo;
    address public lastReward;
    uint256 public lastAmount;
    uint256 public lastLockTime;
    uint256 public lastTokenId;

    constructor(address incentivesController, address rewardsAdmin)
        DustTransferStrategyBase(incentivesController, rewardsAdmin)
    {}

    function setShouldSucceed(bool value) external {
        shouldSucceed = value;
    }

    function performTransfer(address to, address reward, uint256 amount, uint256 lockTime, uint256 tokenId)
        external
        override
        onlyIncentivesController
        returns (bool)
    {
        lastTo = to;
        lastReward = reward;
        lastAmount = amount;
        lastLockTime = lockTime;
        lastTokenId = tokenId;
        return shouldSucceed;
    }
}

contract DustRewardsControllerCoverageTest is Test {
    address internal constant DUMMY_POOL_ADDRESSES_PROVIDER = address(0x1234);

    address internal emissionManager = makeAddr("emissionManager");
    address internal rewardsAdmin = makeAddr("rewardsAdmin");
    address internal user = makeAddr("user");
    address internal claimer = makeAddr("claimer");
    address internal receiver = makeAddr("receiver");

    DustRewardsController internal controller;
    CoverageScaledToken internal asset;
    CoverageScaledToken internal secondAsset;
    CoverageRewardToken internal reward;
    CoverageDustTransferStrategy internal strategy;

    address[] internal assets;

    function setUp() public {
        controller = new DustRewardsController(emissionManager);
        controller.initialize(DUMMY_POOL_ADDRESSES_PROVIDER);

        asset = new CoverageScaledToken("Asset", "AST");
        secondAsset = new CoverageScaledToken("Second Asset", "AST2");
        reward = new CoverageRewardToken();
        strategy = new CoverageDustTransferStrategy(address(controller), rewardsAdmin);

        asset.mint(user, 100 ether);
        asset.mint(address(0xB0B), 100 ether);
        secondAsset.mint(address(0xB0B), 200 ether);
        reward.mint(address(strategy), 1_000_000 ether);

        assets.push(address(asset));
        assets.push(address(secondAsset));

        RewardsDataTypes.RewardsConfigInput[] memory config = new RewardsDataTypes.RewardsConfigInput[](2);
        config[0] = _config(address(asset));
        config[1] = _config(address(secondAsset));

        vm.prank(emissionManager);
        controller.configureAssets(config);
    }

    function testAdminAndStrategyGuards() public {
        assertEq(controller.getTransferStrategy(address(reward)), address(strategy));

        CoverageDustTransferStrategy replacement = new CoverageDustTransferStrategy(address(controller), rewardsAdmin);
        vm.prank(emissionManager);
        controller.setTransferStrategy(address(reward), replacement);
        assertEq(controller.getTransferStrategy(address(reward)), address(replacement));

        vm.prank(emissionManager);
        vm.expectRevert(IDustRewardsController.InvalidRewardAddress.selector);
        controller.setTransferStrategy(address(0), replacement);

        vm.prank(emissionManager);
        vm.expectRevert(IDustRewardsController.StrategyZeroAddress.selector);
        controller.setTransferStrategy(address(reward), IDustTransferStrategy(address(0)));

        vm.prank(emissionManager);
        vm.expectRevert(IDustRewardsController.StrategyNotContract.selector);
        controller.setTransferStrategy(address(reward), IDustTransferStrategy(address(0xBEEF)));

        vm.expectRevert();
        controller.setTransferStrategy(address(reward), replacement);
    }

    function testScaledTokenPreviousIndexTracksBalanceUpdates() public {
        address recipient = makeAddr("scaledRecipient");

        assertEq(asset.getPreviousIndex(user), asset.MOCK_LIQUIDITY_INDEX());
        assertEq(asset.getPreviousIndex(recipient), 0);

        vm.prank(user);
        asset.transfer(recipient, 1 ether);

        assertEq(asset.getPreviousIndex(user), asset.MOCK_LIQUIDITY_INDEX());
        assertEq(asset.getPreviousIndex(recipient), asset.MOCK_LIQUIDITY_INDEX());
    }

    function testClaimRewardsEntryPointsAndPartialAccounting() public {
        _accrue(user, 10);

        vm.prank(user);
        uint256 zeroClaimed = controller.claimRewards(assets, 0, receiver, address(reward), 0, 0);
        assertEq(zeroClaimed, 0);

        vm.prank(user);
        uint256 partialClaimed = controller.claimRewards(assets, 1, receiver, address(reward), 11, 22);
        assertEq(partialClaimed, 1);
        assertEq(strategy.lastTo(), receiver);
        assertEq(strategy.lastReward(), address(reward));
        assertEq(strategy.lastAmount(), 1);
        assertEq(strategy.lastLockTime(), 11);
        assertEq(strategy.lastTokenId(), 22);

        _accrue(user, 10);
        vm.prank(user);
        uint256 claimedToSelf = controller.claimRewardsToSelf(assets, type(uint256).max, address(reward), 33, 44);
        assertGt(claimedToSelf, 0);
        assertEq(strategy.lastTo(), user);
        assertEq(strategy.lastLockTime(), 33);
        assertEq(strategy.lastTokenId(), 44);

        vm.prank(user);
        uint256 noRewards = controller.claimRewards(assets, type(uint256).max, receiver, address(reward), 0, 0);
        assertEq(noRewards, 0);
    }

    function testClaimRewardsOnBehalfGuardsAndSuccess() public {
        vm.prank(user);
        vm.expectRevert(IDustRewardsController.ClaimerUnauthorized.selector);
        controller.claimRewardsOnBehalf(assets, 1, user, receiver, address(reward), 0, 0);

        vm.prank(user);
        controller.setClaimer(user, claimer);

        vm.prank(emissionManager);
        controller.setClaimer(address(0), claimer);

        vm.prank(claimer);
        vm.expectRevert(IDustRewardsController.InvalidUserAddress.selector);
        controller.claimRewardsOnBehalf(assets, 1, address(0), receiver, address(reward), 0, 0);

        _accrue(user, 10);
        vm.prank(claimer);
        uint256 claimed =
            controller.claimRewardsOnBehalf(assets, type(uint256).max, user, receiver, address(reward), 0, 0);
        assertGt(claimed, 0);
        assertEq(strategy.lastTo(), receiver);
    }

    function testClaimAllRewardsEntryPoints() public {
        _accrue(user, 10);

        vm.prank(user);
        (address[] memory rewardList, uint256[] memory amounts) = controller.claimAllRewards(assets, receiver, 55, 66);
        assertEq(rewardList.length, 1);
        assertEq(rewardList[0], address(reward));
        assertGt(amounts[0], 0);
        assertEq(strategy.lastTo(), receiver);
        assertEq(strategy.lastLockTime(), 55);
        assertEq(strategy.lastTokenId(), 66);

        vm.prank(user);
        controller.setClaimer(user, claimer);

        _accrue(user, 10);
        vm.prank(claimer);
        (rewardList, amounts) = controller.claimAllRewardsOnBehalf(assets, user, receiver, 77, 88);
        assertEq(rewardList[0], address(reward));
        assertGt(amounts[0], 0);
        assertEq(strategy.lastTo(), receiver);
        assertEq(strategy.lastLockTime(), 77);
        assertEq(strategy.lastTokenId(), 88);

        vm.prank(emissionManager);
        controller.setClaimer(address(0), claimer);

        vm.prank(claimer);
        vm.expectRevert(IDustRewardsController.InvalidUserAddress.selector);
        controller.claimAllRewardsOnBehalf(assets, address(0), receiver, 0, 0);

        _accrue(user, 10);
        vm.prank(user);
        (rewardList, amounts) = controller.claimAllRewardsToSelf(assets, 99, 111);
        assertEq(rewardList[0], address(reward));
        assertGt(amounts[0], 0);
        assertEq(strategy.lastTo(), user);
    }

    function testTransferFailureAndBaseEmergencyWithdrawal() public {
        _accrue(user, 10);
        strategy.setShouldSucceed(false);

        vm.prank(user);
        vm.expectRevert(IDustRewardsController.TransferError.selector);
        controller.claimRewards(assets, type(uint256).max, receiver, address(reward), 0, 0);

        strategy.setShouldSucceed(true);
        uint256 receiverBefore = reward.balanceOf(receiver);

        vm.prank(rewardsAdmin);
        strategy.emergencyWithdrawal(address(reward), receiver, 1 ether);
        assertEq(reward.balanceOf(receiver), receiverBefore + 1 ether);

        vm.prank(user);
        vm.expectRevert(IDustTransferStrategy.OnlyRewardsAdmin.selector);
        strategy.emergencyWithdrawal(address(reward), receiver, 1 ether);

        vm.expectRevert(IDustTransferStrategy.CallerNotIncentivesController.selector);
        strategy.performTransfer(receiver, address(reward), 1, 0, 0);
    }

    function _config(address asset_) internal view returns (RewardsDataTypes.RewardsConfigInput memory config) {
        config.emissionPerSecond = 1 ether;
        config.totalSupply = 0;
        config.distributionEnd = uint32(block.timestamp + 365 days);
        config.asset = asset_;
        config.reward = address(reward);
        config.transferStrategy = ITransferStrategyBase(address(strategy));
        config.rewardOracle = IEACAggregatorProxy(address(0));
    }

    function _accrue(address account, uint256 secondsToSkip) internal {
        skip(secondsToSkip);
        vm.prank(address(asset));
        controller.handleAction(account, asset.totalSupply(), asset.balanceOf(account));
    }
}

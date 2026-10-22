// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFlashLoanReceiver} from "@neverland-money/lending-core/contracts/flashloan/interfaces/IFlashLoanReceiver.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";

import {IMorphoFlashLoanCallback} from "../../../src/interfaces/IMorphoFlashLoanCallback.sol";
import {IPendlePtLeverageRouter} from "../../../src/interfaces/IPendlePtLeverageRouter.sol";
import {IPendleRouterV4} from "../../../src/interfaces/IPendleRouterV4.sol";
import {
    MockAclManager,
    MockAddressesProvider,
    MockGatewayAToken,
    MockGatewayToken,
    MockPendleMarket,
    MockPendleRouter
} from "./PendleMaturityGatewayMocks.sol";

/// @title MockPendleLeveragerRouter
/// @author Neverland
/// @notice Local Pendle AMM fixture; lending and receipt-token behavior remains real.
contract MockPendleLeveragerRouter is MockPendleRouter {
    uint256 public salePriceWad = 1e18;
    bool public lieAboutOutput;

    function setSalePriceWad(uint256 value) external {
        salePriceWad = value;
    }

    function setLieAboutOutput(bool value) external {
        lieAboutOutput = value;
    }

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        IPendlePtLeverageRouter.TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256, uint256, uint256) {
        require(
            output.tokenOut == output.tokenRedeemSy && output.pendleSwap == address(0)
                && output.swapData.swapType == SwapType.NONE && output.swapData.extRouter == address(0)
                && output.swapData.extCalldata.length == 0 && !output.swapData.needScale,
            "sale route"
        );
        require(
            limit.limitRouter == address(0) && limit.normalFills.length == 0 && limit.flashFills.length == 0
                && limit.optData.length == 0,
            "orders"
        );
        if (mode == Mode.REENTER_CLOSE || mode == Mode.FLASH_POOL_SPOOF) _callHook();
        (, address pt,) = MockPendleMarket(market).readTokens();
        IERC20(pt).transferFrom(msg.sender, address(this), exactPtIn);
        uint256 received = exactPtIn * salePriceWad / 1e18;
        MockGatewayToken(output.tokenOut).mint(receiver, received);

        return (lieAboutOutput ? type(uint256).max : received, 0, 0);
    }
}

/// @title MaliciousPendleMorpho
/// @author Neverland
/// @notice Exercises missing, replayed and tampered callbacks on an external lender boundary.
contract MaliciousPendleMorpho {
    uint256 public mode;
    address public hookTarget;
    bytes public hookData;

    function setMode(uint256 value) external {
        mode = value;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function flashLoan(address token, uint256 amount, bytes calldata data) external {
        IERC20(token).transfer(msg.sender, amount);
        if (hookTarget != address(0)) {
            (bool success, bytes memory reason) = hookTarget.call(hookData);
            if (!success) {
                assembly ("memory-safe") { revert(add(reason, 0x20), mload(reason)) }
            }
        }
        if (mode == 1) return;
        bytes memory echoed = data;
        if (mode == 2) echoed = abi.encode(uint256(1));
        if (mode == 5) {
            (address user, uint256 cash, uint256 pt, uint256 debtEntry, uint256 minimumPt) =
                abi.decode(data, (address, uint256, uint256, uint256, uint256));
            echoed = abi.encode(user, cash, pt, debtEntry, minimumPt + 1);
        }
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(mode == 3 ? amount + 1 : amount, echoed);
        if (mode == 4) IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(amount, data);
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice Shared `mode` knob of the malicious pools and their faulty `executeOperation` callback delivery.
abstract contract PendleFaultyFlashLender {
    uint256 public mode;

    function setMode(uint256 value) external {
        mode = value;
    }

    /// @dev Mode 7 lends without calling back; 1-6, 9 and 10 corrupt one callback field and 8 replays the callback.
    function _deliverWithFaults(address receiver, address[] memory assets, uint256[] memory amounts, bytes memory data)
        internal
        returns (bool delivered)
    {
        if (mode == 7) return false;

        uint256[] memory premiums = new uint256[](1);
        address initiator = msg.sender;
        if (mode == 1) assets = new address[](0);
        if (mode == 2) amounts = new uint256[](0);
        if (mode == 3) premiums = new uint256[](0);
        if (mode == 4) assets[0] = address(this);
        if (mode == 5) premiums[0] = 1;
        if (mode == 6) initiator = address(this);
        if (mode == 9) amounts[0]++;
        if (mode == 10) data = abi.encode(uint256(10));
        IFlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, initiator, data);
        if (mode == 8) IFlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, initiator, data);

        return true;
    }
}

/// @title MaliciousPendleFlashPool
/// @author Neverland
/// @notice Eligible external pool that corrupts individual callback fields to exercise authentication.
contract MaliciousPendleFlashPool is PendleFaultyFlashLender {
    address public immutable DEBT;
    MockGatewayAToken public immutable A_TOKEN;
    MockAclManager public immutable ACL;
    address public immutable ADDRESSES_PROVIDER;
    address public hookTarget;
    bytes public hookData;

    constructor(address debt) {
        DEBT = debt;
        A_TOKEN = new MockGatewayAToken(address(this), debt);
        ACL = new MockAclManager();
        ADDRESSES_PROVIDER = address(new MockAddressesProvider(address(ACL)));
    }

    function seed(uint256 cash) external {
        MockGatewayToken(DEBT).mint(address(A_TOKEN), cash);
        A_TOKEN.mint(address(this), cash);
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory data) {
        if (asset == DEBT) {
            data.configuration.data = (1 << 56) | (1 << 63);
            data.aTokenAddress = address(A_TOKEN);
        }
    }
    function finalizeTransfer(address, address, uint256) external pure {}

    function flashLoan(
        address receiver,
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory,
        address,
        bytes memory data,
        uint16
    ) external {
        uint256 amount = amounts[0];
        A_TOKEN.transferUnderlyingTo(receiver, amount);
        if (hookTarget != address(0)) {
            (bool success, bytes memory reason) = hookTarget.call(hookData);
            if (!success) {
                assembly ("memory-safe") { revert(add(reason, 0x20), mload(reason)) }
            }
        }
        if (!_deliverWithFaults(receiver, assets, amounts, data)) return;

        IERC20(DEBT).transferFrom(receiver, address(A_TOKEN), amount);
    }
}

/// @notice Real position reads with a malformed mode-2 callback boundary; no production pool is modified.
contract MaliciousPendlePositionPool is PendleFaultyFlashLender {
    address public immutable REAL_POOL;

    constructor(address realPool) {
        REAL_POOL = realPool;
    }

    function supply(address asset, uint256 amount, address user, uint16 referral) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(REAL_POOL, amount);
        IPool(REAL_POOL).supply(asset, amount, user, referral);
    }

    function flashLoan(
        address receiver,
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory modes,
        address,
        bytes memory data,
        uint16
    ) external {
        require(modes[0] == 2, "position mode");
        IERC20(assets[0]).transfer(receiver, amounts[0]);
        _deliverWithFaults(receiver, assets, amounts, data);
    }

    fallback() external {
        (bool success, bytes memory result) = REAL_POOL.staticcall(msg.data);
        assembly ("memory-safe") {
            if iszero(success) { revert(add(result, 0x20), mload(result)) }
            return(add(result, 0x20), mload(result))
        }
    }
}

/// @notice Ignores the supplied purchase floor and lies about output to isolate measured-output protection.
contract DishonestPendlePurchaseRouter {
    uint256 public output;
    uint256 public unspent;

    function setOutput(uint256 amount) external {
        output = amount;
    }

    function setUnspent(uint256 amount) external {
        unspent = amount;
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256,
        IPendleRouterV4.ApproxParams calldata,
        IPendleRouterV4.TokenInput calldata input,
        IPendleRouterV4.LimitOrderData calldata
    ) external returns (uint256, uint256, uint256) {
        IERC20(input.tokenIn).transferFrom(msg.sender, address(this), input.netTokenIn - unspent);
        (, address pt,) = MockPendleMarket(market).readTokens();
        MockGatewayToken(pt).mint(receiver, output);

        return (type(uint256).max, 0, 0);
    }
}

/// @notice Pays a real position-pool PT flash premium inside another operation's callback.
contract PendleLeveragerNestedFlashReceiver {
    IPool public immutable POOL;

    constructor(IPool pool) {
        POOL = pool;
    }

    function takeLoan(address asset, uint256 amount) external {
        POOL.flashLoanSimple(address(this), asset, amount, bytes(""), 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == address(POOL) && initiator == address(this), "nested callback");
        require(premium != 0, "nonzero premium");
        IERC20(asset).approve(address(POOL), amount + premium);

        return true;
    }
}

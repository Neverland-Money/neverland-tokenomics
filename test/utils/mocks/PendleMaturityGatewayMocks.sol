// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFlashLoanReceiver} from "@neverland-money/lending-core/contracts/flashloan/interfaces/IFlashLoanReceiver.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {ERC20} from "@openzeppelin-v5/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-v5/contracts/utils/math/Math.sol";

import {IMorphoFlashLoanCallback} from "../../../src/interfaces/IMorphoFlashLoanCallback.sol";
import {IPendleRouterV4} from "../../../src/interfaces/IPendleRouterV4.sol";

/**
 * @title MockGatewayToken
 * @author Neverland
 * @notice Freely mintable 18-decimal ERC20 standing in for the debt asset, PTs, and SYs
 */
contract MockGatewayToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/**
 * @title NonPrincipalToken
 * @author Neverland
 * @notice Plain ERC20 without the PT views, listed as a reserve to exercise the PT reads
 */
contract NonPrincipalToken is MockGatewayToken {
    constructor() MockGatewayToken("Not A PT", "NPT") {}
}

/**
 * @title PartialPrincipalToken
 * @author Neverland
 * @notice Matured-PT lookalike whose `SY()` or `YT()` read can be made to revert
 */
contract PartialPrincipalToken is MockGatewayToken {
    bool public constant isExpired = true;

    bool public revertSy;
    bool public revertYt;

    constructor() MockGatewayToken("Partial PT", "PPT") {}

    function setRevertSy(bool value) external {
        revertSy = value;
    }

    function setRevertYt(bool value) external {
        revertYt = value;
    }

    function SY() external view returns (address) {
        require(!revertSy, "no SY");

        return address(this);
    }

    function YT() external view returns (address) {
        require(!revertYt, "no YT");

        return address(this);
    }
}

/**
 * @title MockPendlePt
 * @author Neverland
 * @notice PT with settable expiry, SY, and YT
 */
contract MockPendlePt is MockGatewayToken {
    bool public isExpired;
    address public SY;
    address public YT;

    constructor(string memory symbol_) MockGatewayToken(symbol_, symbol_) {}

    function setExpired(bool expired) external {
        isExpired = expired;
    }

    function setSy(address sy) external {
        SY = sy;
    }

    function setYt(address yt) external {
        YT = yt;
    }
}

/**
 * @title MockPendleSy
 * @author Neverland
 * @notice SY that redeems into the debt asset at `rateBps`
 * @dev `ignoreMinOut` skips the SY's own floor so the caller's shortfall check is the one that fires.
 */
contract MockPendleSy is MockGatewayToken {
    MockGatewayToken public immutable DEBT;

    uint256 public rateBps = 10_000;
    uint256 public exchangeRate = 1e18;
    bool public ignoreMinOut;

    mapping(address token => bool valid) public isValidTokenIn;
    mapping(address token => bool valid) public isValidTokenOut;

    constructor(MockGatewayToken debt_) MockGatewayToken("SY", "SY") {
        DEBT = debt_;
        isValidTokenIn[address(debt_)] = true;
        isValidTokenOut[address(debt_)] = true;
    }

    function setRateBps(uint256 rateBps_) external {
        rateBps = rateBps_;
    }

    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    function previewRedeem(address, uint256 shares) external view returns (uint256) {
        return shares * rateBps / 10_000;
    }

    function setIgnoreMinOut(bool ignore) external {
        ignoreMinOut = ignore;
    }

    function setValidTokenIn(address token, bool valid) external {
        isValidTokenIn[token] = valid;
    }

    function setValidTokenOut(address token, bool valid) external {
        isValidTokenOut[token] = valid;
    }

    function redeem(address receiver, uint256 shares, address tokenOut, uint256 minOut, bool)
        external
        returns (uint256 amountOut)
    {
        require(isValidTokenOut[tokenOut], "SY: invalid token out");

        _burn(msg.sender, shares);
        amountOut = shares * rateBps / 10_000;
        require(ignoreMinOut || amountOut >= minOut, "SY: insufficient out");
        DEBT.mint(receiver, amountOut);
    }
}

/**
 * @title MockPendleYt
 * @author Neverland
 * @notice YT whose `redeemPY` burns its whole PT balance and mints SY 1:1 to the receiver
 */
contract MockPendleYt {
    uint256 public pyIndexStored = 1e18;

    MockGatewayToken public immutable PT;
    MockGatewayToken public immutable SY;

    constructor(MockGatewayToken pt_, MockGatewayToken sy_) {
        PT = pt_;
        SY = sy_;
    }

    function setPyIndexStored(uint256 index) external {
        pyIndexStored = index;
    }

    function redeemPY(address receiver) external returns (uint256 amountSyOut) {
        amountSyOut = PT.balanceOf(address(this));
        PT.burn(address(this), amountSyOut);
        SY.mint(receiver, amountSyOut);
    }
}

/**
 * @title MockPendleMarket
 * @author Neverland
 * @notice Market exposing its tokens and a settable expiry
 */
contract MockPendleMarket {
    bool public isExpired;

    /// @dev Market SY returned by `readTokens`
    address internal immutable _sy;
    /// @dev Market PT returned by `readTokens`
    address internal immutable _pt;
    /// @dev Market YT returned by `readTokens`
    address internal immutable _yt;

    constructor(address sy_, address pt_, address yt_) {
        _sy = sy_;
        _pt = pt_;
        _yt = yt_;
    }

    function setExpired(bool expired) external {
        isExpired = expired;
    }

    function readTokens() external view returns (address sy, address pt, address yt) {
        return (_sy, _pt, _yt);
    }
}

/**
 * @title MockPendleRouter
 * @author Neverland
 * @notice Router that sells the market's PT for the input token at `priceWad` and records its inputs
 * @dev `PULL_EXTRA` pulls one wei more than `netTokenIn`; `REENTER_CLOSE` and `FLASH_POOL_SPOOF` call the
 *      configured hook (a re-entrant gateway call or a pool flash loan naming the gateway) before the swap.
 */
contract MockPendleRouter is IPendleRouterV4 {
    enum Mode {
        NORMAL,
        PULL_EXTRA,
        REENTER_CLOSE,
        FLASH_POOL_SPOOF
    }

    Mode public mode;
    uint256 public priceWad = 1e18;
    uint256 public swapCount;

    address public hookTarget;
    bytes public hookData;

    address public lastReceiver;
    address public lastMarket;
    uint256 public lastMinPtOut;
    address public lastTokenIn;
    uint256 public lastNetTokenIn;
    address public lastTokenMintSy;
    address public lastPendleSwap;
    SwapType public lastSwapType;
    /// @dev Last router search hint, exposed through `lastApprox`
    ApproxParams internal _lastApprox;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setPriceWad(uint256 priceWad_) external {
        priceWad = priceWad_;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) {
        _record(receiver, market, minPtOut, guessPtOut, input);
        if (mode == Mode.REENTER_CLOSE || mode == Mode.FLASH_POOL_SPOOF) _callHook();

        uint256 pull = mode == Mode.PULL_EXTRA ? input.netTokenIn + 1 : input.netTokenIn;
        IERC20(input.tokenIn).transferFrom(msg.sender, address(this), pull);
        (, address pt,) = MockPendleMarket(market).readTokens();
        netPtOut = input.netTokenIn * 1e18 / priceWad;
        require(netPtOut >= minPtOut, "router: min out");
        MockGatewayToken(pt).mint(receiver, netPtOut);

        return (netPtOut, netSyFee, netSyInterm);
    }

    function lastApprox() external view returns (ApproxParams memory) {
        return _lastApprox;
    }

    function _record(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input
    ) internal {
        ++swapCount;
        lastReceiver = receiver;
        lastMarket = market;
        lastMinPtOut = minPtOut;
        lastTokenIn = input.tokenIn;
        lastNetTokenIn = input.netTokenIn;
        lastTokenMintSy = input.tokenMintSy;
        lastPendleSwap = input.pendleSwap;
        lastSwapType = input.swapData.swapType;
        _lastApprox = guessPtOut;
    }

    function _callHook() internal {
        (bool success, bytes memory result) = hookTarget.call(hookData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/**
 * @title MockGatewayAToken
 * @author Neverland
 * @notice aToken holding its reserve's underlying, with a recording permit and the pool's transfer check
 * @dev Every transfer between two accounts calls back `finalizeTransfer(from, to, value)` on the pool after moving.
 */
contract MockGatewayAToken is ERC20 {
    address public immutable POOL;
    address public immutable UNDERLYING_ASSET_ADDRESS;

    bool public revertOnPermit;
    uint256 public permitCallCount;
    address public lastPermitOwner;
    address public lastPermitSpender;
    uint256 public lastPermitValue;
    uint256 public lastPermitDeadline;
    uint8 public lastPermitV;
    bytes32 public lastPermitR;
    bytes32 public lastPermitS;

    error PermitConsumed();

    constructor(address pool_, address underlying_) ERC20("aToken", "aTKN") {
        POOL = pool_;
        UNDERLYING_ASSET_ADDRESS = underlying_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function transferUnderlyingTo(address to, uint256 amount) external {
        require(msg.sender == POOL, "aToken: only pool");

        IERC20(UNDERLYING_ASSET_ADDRESS).transfer(to, amount);
    }

    /// @notice Stands in for a permit whose nonce another transaction already spent
    function setRevertOnPermit(bool value) external {
        revertOnPermit = value;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (revertOnPermit) revert PermitConsumed();

        ++permitCallCount;
        lastPermitOwner = owner;
        lastPermitSpender = spender;
        lastPermitValue = value;
        lastPermitDeadline = deadline;
        lastPermitV = v;
        lastPermitR = r;
        lastPermitS = s;
        _approve(owner, spender, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (from != address(0) && to != address(0)) MockIsolatedPool(POOL).finalizeTransfer(from, to, value);
    }
}

/**
 * @title MockVariableDebtToken
 * @author Neverland
 * @notice Variable-debt balance kept in scaled units against a settable index
 * @dev Lending-core rounding: balance rounds up, mint rounds the scaled amount up, burn rounds it down, and a burn
 *      of at least the balance clears the account. At the default `1e27` index everything is exact; at any other
 *      index partial repayments leave the debt a few wei higher, never lower.
 */
contract MockVariableDebtToken {
    /// @dev Lending-core ray unit and default index
    uint256 internal constant RAY = 1e27;

    address public immutable POOL;

    uint256 public index = RAY;
    uint256 public scaledTotalSupply;
    mapping(address account => uint256 scaled) public scaledBalanceOf;

    constructor(address pool_) {
        POOL = pool_;
    }

    modifier onlyPool() {
        require(msg.sender == POOL, "debt: only pool");
        _;
    }

    function setIndex(uint256 index_) external onlyPool {
        index = index_;
    }

    function mint(address account, uint256 amount) external onlyPool {
        uint256 scaled = _rayDivCeil(amount, index);
        scaledBalanceOf[account] += scaled;
        scaledTotalSupply += scaled;
    }

    function burn(address account, uint256 amount) external onlyPool {
        uint256 current = scaledBalanceOf[account];
        uint256 scaled = amount >= balanceOf(account) ? current : _rayDivFloor(amount, index);
        require(scaled != 0, "25");

        scaledBalanceOf[account] = current - scaled;
        scaledTotalSupply -= scaled;
    }

    function totalSupply() external view returns (uint256) {
        return _rayMulCeil(scaledTotalSupply, index);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _rayMulCeil(scaledBalanceOf[account], index);
    }

    function _rayMulCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, RAY, Math.Rounding.Ceil);
    }

    function _rayDivCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, RAY, b, Math.Rounding.Ceil);
    }

    function _rayDivFloor(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * RAY / b;
    }
}

/**
 * @title MockAclManager
 * @author Neverland
 * @notice Flash-borrower role registry
 */
contract MockAclManager {
    mapping(address account => bool granted) public isFlashBorrower;

    function setFlashBorrower(address account, bool granted) external {
        isFlashBorrower[account] = granted;
    }
}

/**
 * @title MockAddressesProvider
 * @author Neverland
 * @notice Addresses provider exposing the ACL manager and price oracle
 */
contract MockAddressesProvider {
    address public immutable getACLManager;
    address public getPriceOracle;

    constructor(address aclManager_) {
        getACLManager = aclManager_;
    }

    function setPriceOracle(address oracle) external {
        getPriceOracle = oracle;
    }
}

/**
 * @title MockIsolatedPool
 * @author Neverland
 * @notice Single-debt-asset pool with priced reserves, collateral flags, and a health-factor transfer check
 * @dev Account data follows lending-core: collateral value rounds down per reserve, debt value rounds up, and
 *      HF = Σ(collateral value × ltBps) / debt value / 1e4, in WAD with the WAD division rounded half-up; max with
 *      no debt. `ltBps` is both the LTV and the liquidation threshold in `getConfiguration`. Transfers and
 *      withdrawals revert `"35"` when they leave an indebted account below 1. A balance reaching zero clears its
 *      collateral flag; a first supply or receipt enables it when `collateralEnabledOnSupply` is set, `ltBps` is
 *      non-zero, and the reserve has no debt ceiling. Opening debt sets the borrowing flag and a repay to zero clears
 *      it. Repay checks follow lending-core order.
 */
contract MockIsolatedPool {
    enum RoundingMode {
        EXACT,
        LENDING_CORE
    }

    struct Reserve {
        MockGatewayAToken aToken;
        uint16 id;
        uint256 priceWad;
        uint256 ltBps;
    }

    /// @dev Lending-core ray unit, the `EXACT` debt index
    uint256 internal constant RAY = 1e27;
    /// @dev Non-unit debt index that exercises lending-core rounding in `LENDING_CORE` mode
    uint256 internal constant LENDING_CORE_INDEX = 1_123_456_789_123_456_789_123_456_789;
    /// @dev Reserve-configuration active flag
    uint256 internal constant ACTIVE_BIT = 1 << 56;
    /// @dev Reserve-configuration liquidation-threshold offset
    uint256 internal constant LIQUIDATION_THRESHOLD_OFFSET = 16;
    /// @dev Reserve-configuration decimals offset
    uint256 internal constant DECIMALS_OFFSET = 48;
    /// @dev Reserve-configuration debt-ceiling offset
    uint256 internal constant DEBT_CEILING_OFFSET = 212;

    address public immutable DEBT;
    MockVariableDebtToken public immutable DEBT_TOKEN;
    address public immutable ADDRESSES_PROVIDER;

    RoundingMode public roundingMode;
    bool public collateralEnabledOnSupply = true;

    address[] public reserveList;
    mapping(address asset => Reserve reserve) public reserves;
    mapping(address asset => uint8 decimals) public reserveDecimals;
    mapping(address asset => uint256 ceiling) public debtCeiling;
    /// @dev Per-reserve normalized income in ray (1e27 = 1)
    mapping(address asset => uint256 index) public reserveNormalizedIncome;
    /// @dev Per-user collateral and borrowing bitmap in lending-core layout
    mapping(address user => uint256 data) internal _userConfig;

    constructor(address debt_, address addressesProvider_) {
        DEBT = debt_;
        DEBT_TOKEN = new MockVariableDebtToken(address(this));
        ADDRESSES_PROVIDER = addressesProvider_;
        MockAddressesProvider(addressesProvider_).setPriceOracle(address(this));
    }

    function listReserve(address asset, uint256 priceWad, uint256 ltBps) external returns (MockGatewayAToken aToken) {
        require(address(reserves[asset].aToken) == address(0), "pool: listed");

        aToken = new MockGatewayAToken(address(this), asset);
        reserves[asset] = Reserve({aToken: aToken, id: uint16(reserveList.length), priceWad: priceWad, ltBps: ltBps});
        reserveList.push(asset);
        reserveDecimals[asset] = 18;
        reserveNormalizedIncome[asset] = RAY;
    }

    function setPrice(address asset, uint256 priceWad) external {
        reserves[asset].priceWad = priceWad;
    }

    function setReserveDecimals(address asset, uint8 decimals_) external {
        reserveDecimals[asset] = decimals_;
    }

    function setLtBps(address asset, uint256 ltBps) external {
        reserves[asset].ltBps = ltBps;
    }

    function setDebtCeiling(address asset, uint256 ceiling) external {
        debtCeiling[asset] = ceiling;
    }

    function setReserveNormalizedIncome(address asset, uint256 index) external {
        reserveNormalizedIncome[asset] = index;
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return reserveNormalizedIncome[asset];
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return reserves[asset].priceWad;
    }

    function getConfiguration(address asset) external view returns (DataTypes.ReserveConfigurationMap memory) {
        uint256 ltBps = reserves[asset].ltBps;

        return DataTypes.ReserveConfigurationMap({
            data: ltBps | (ltBps << LIQUIDATION_THRESHOLD_OFFSET) | (uint256(reserveDecimals[asset]) << DECIMALS_OFFSET)
                | ACTIVE_BIT | (debtCeiling[asset] << DEBT_CEILING_OFFSET)
        });
    }

    function setCollateralEnabledOnSupply(bool enabled) external {
        collateralEnabledOnSupply = enabled;
    }

    /// @notice Set before any debt exists; a later change acts as accrued interest
    function setRoundingMode(RoundingMode mode) external {
        roundingMode = mode;
        DEBT_TOKEN.setIndex(mode == RoundingMode.EXACT ? RAY : LENDING_CORE_INDEX);
    }

    /// @notice Sets `user`'s borrowing flag for `asset`, standing in for debt in another borrowable reserve
    function setBorrowing(address user, address asset, bool enabled) external {
        _setBorrowing(user, reserves[asset].id, enabled);
    }

    /// @notice Test fixture: opens `amount` of variable debt for `user` without paying anything out
    function mintDebt(address user, uint256 amount) external {
        DEBT_TOKEN.mint(user, amount);
        _setBorrowing(user, reserves[DEBT].id, true);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        Reserve storage reserve = _listed(asset);
        bool first = reserve.aToken.balanceOf(onBehalfOf) == 0;

        IERC20(asset).transferFrom(msg.sender, address(reserve.aToken), amount);
        reserve.aToken.mint(onBehalfOf, amount);
        if (first && _autoCollateral(reserve)) _setCollateral(onBehalfOf, reserve.id, true);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        Reserve storage reserve = _listed(asset);
        if (amount == type(uint256).max) amount = reserve.aToken.balanceOf(msg.sender);

        reserve.aToken.burn(msg.sender, amount);
        reserve.aToken.transferUnderlyingTo(to, amount);
        _validateHealth(msg.sender);
        if (reserve.aToken.balanceOf(msg.sender) == 0) _setCollateral(msg.sender, reserve.id, false);

        return amount;
    }

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256 paid)
    {
        require(amount != 0, "26");
        require(amount != type(uint256).max || onBehalfOf == msg.sender, "40");
        require(asset == DEBT && interestRateMode == 2, "pool: bad repay");
        uint256 debt = DEBT_TOKEN.balanceOf(onBehalfOf);
        require(debt != 0, "39");

        paid = Math.min(amount, debt);

        IERC20(DEBT).transferFrom(msg.sender, address(_listed(DEBT).aToken), paid);
        DEBT_TOKEN.burn(onBehalfOf, paid);
        if (DEBT_TOKEN.balanceOf(onBehalfOf) == 0) _setBorrowing(onBehalfOf, reserves[DEBT].id, false);
    }

    /// @notice aToken hook: checks the sender's health, then moves collateral flags as lending-core does
    function finalizeTransfer(address from, address to, uint256 value) external {
        address asset = MockGatewayAToken(msg.sender).UNDERLYING_ASSET_ADDRESS();
        Reserve storage reserve = _listed(asset);
        require(address(reserve.aToken) == msg.sender, "pool: not aToken");

        _validateHealth(from);
        if (value == 0 || from == to) return;

        if (reserve.aToken.balanceOf(from) == 0) _setCollateral(from, reserve.id, false);
        if (reserve.aToken.balanceOf(to) == value && _autoCollateral(reserve)) _setCollateral(to, reserve.id, true);
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory data) {
        Reserve storage reserve = reserves[asset];
        if (address(reserve.aToken) == address(0)) return data;

        data.configuration.data = ACTIVE_BIT;
        data.liquidityIndex = uint128(RAY);
        data.variableBorrowIndex = uint128(asset == DEBT ? DEBT_TOKEN.index() : RAY);
        data.id = reserve.id;
        data.aTokenAddress = address(reserve.aToken);
        if (asset == DEBT) data.variableDebtTokenAddress = address(DEBT_TOKEN);
    }

    function getUserConfiguration(address user) external view returns (DataTypes.UserConfigurationMap memory) {
        return DataTypes.UserConfigurationMap({data: _userConfig[user]});
    }

    function getUserAccountData(address user)
        public
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        uint256 weighted;
        for (uint256 i; i < reserveList.length; ++i) {
            Reserve storage reserve = reserves[reserveList[i]];
            if ((_userConfig[user] >> (uint256(reserve.id) * 2 + 1)) & 1 == 0) continue;

            uint256 value = reserve.aToken.balanceOf(user) * reserve.priceWad / _unit(reserveList[i]);
            totalCollateralBase += value;
            weighted += value * reserve.ltBps;
        }
        totalDebtBase =
            Math.mulDiv(DEBT_TOKEN.balanceOf(user), reserves[DEBT].priceWad, _unit(DEBT), Math.Rounding.Ceil);
        if (totalCollateralBase != 0) currentLiquidationThreshold = weighted / totalCollateralBase;
        healthFactor =
            totalDebtBase == 0 ? type(uint256).max : (weighted * 1e18 + totalDebtBase / 2) / totalDebtBase / 10_000;

        return
            (totalCollateralBase, totalDebtBase, availableBorrowsBase, currentLiquidationThreshold, ltv, healthFactor);
    }

    function _autoCollateral(Reserve storage reserve) internal view returns (bool) {
        return collateralEnabledOnSupply && reserve.ltBps != 0 && debtCeiling[reserveList[reserve.id]] == 0;
    }

    function _unit(address asset) internal view returns (uint256) {
        return 10 ** reserveDecimals[asset];
    }

    function _listed(address asset) internal view returns (Reserve storage reserve) {
        reserve = reserves[asset];
        require(address(reserve.aToken) != address(0), "pool: not listed");
    }

    function _setBorrowing(address user, uint16 id, bool enabled) internal {
        _setFlag(user, uint256(id) * 2, enabled);
    }

    function _setCollateral(address user, uint16 id, bool enabled) internal {
        _setFlag(user, uint256(id) * 2 + 1, enabled);
    }

    function _setFlag(address user, uint256 position, bool enabled) internal {
        uint256 bit = 2 ** position;
        _userConfig[user] = enabled ? _userConfig[user] | bit : _userConfig[user] & ~bit;
    }

    function _validateHealth(address user) internal view {
        if (DEBT_TOKEN.balanceOf(user) == 0) return;

        (,,,,, uint256 healthFactor) = getUserAccountData(user);
        require(healthFactor >= 1e18, "35");
    }
}

/**
 * @title MockFlashPool
 * @author Neverland
 * @notice Global-pool flash loans with lending-core semantics for the debt asset
 * @dev Premium is zero for flash borrowers, else 0.50% rounded up; amounts above the aToken supply
 *      revert `"26"`.
 */
contract MockFlashPool {
    /// @dev Premium charged to non-flash-borrowers, in basis points
    uint256 internal constant PREMIUM_BPS = 50;
    /// @dev Reserve-configuration active flag
    uint256 internal constant ACTIVE_BIT = 1 << 56;
    /// @dev Reserve-configuration paused flag
    uint256 internal constant PAUSED_BIT = 1 << 60;
    /// @dev Reserve-configuration flash-loan-enabled flag
    uint256 internal constant FLASH_ENABLED_BIT = 1 << 63;

    address public immutable DEBT;
    MockGatewayAToken public immutable A_TOKEN;
    MockAclManager public immutable ACL;
    address public immutable ADDRESSES_PROVIDER;

    bool public listed = true;
    bool public active = true;
    bool public paused;
    bool public flashEnabled = true;

    uint256 public flashLoanCount;
    uint256 public lastPremium;
    bytes public callbackData;

    constructor(address debt_) {
        DEBT = debt_;
        A_TOKEN = new MockGatewayAToken(address(this), debt_);
        ACL = new MockAclManager();
        ADDRESSES_PROVIDER = address(new MockAddressesProvider(address(ACL)));
    }

    /// @notice Replaces the callback payload to exercise the gateway's lender-data binding
    function setCallbackData(bytes calldata data) external {
        callbackData = data;
    }

    function setListed(bool listed_) external {
        listed = listed_;
    }

    function setActive(bool active_) external {
        active = active_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setFlashEnabled(bool enabled) external {
        flashEnabled = enabled;
    }

    /// @notice Test fixture: backs `amount` of new aToken supply with `amount` of cash
    function seed(address lender, uint256 amount) external {
        MockGatewayToken(DEBT).mint(address(A_TOKEN), amount);
        A_TOKEN.mint(lender, amount);
    }

    function flashLoan(
        address receiverAddress,
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory interestRateModes,
        address,
        bytes memory params,
        uint16
    ) external {
        bool feeFree = ACL.isFlashBorrower(msg.sender);
        uint256[] memory premiums = new uint256[](assets.length);

        for (uint256 i; i < assets.length; ++i) {
            require(assets[i] == DEBT && listed && active && !paused && flashEnabled, "91");
            require(amounts[i] <= A_TOKEN.totalSupply(), "26");
            premiums[i] = feeFree ? 0 : Math.mulDiv(amounts[i], PREMIUM_BPS, 10_000, Math.Rounding.Ceil);
            A_TOKEN.transferUnderlyingTo(receiverAddress, amounts[i]);
        }
        bytes memory echoed = callbackData.length == 0 ? params : callbackData;
        require(
            IFlashLoanReceiver(receiverAddress).executeOperation(assets, amounts, premiums, msg.sender, echoed),
            "P_INVALID_FLASH_LOAN_EXECUTOR_RETURN"
        );
        for (uint256 i; i < assets.length; ++i) {
            require(interestRateModes[i] == 0, "pool: debt mode");
            IERC20(assets[i]).transferFrom(receiverAddress, address(A_TOKEN), amounts[i] + premiums[i]);
        }

        ++flashLoanCount;
        lastPremium = premiums.length == 0 ? 0 : premiums[0];
    }

    function finalizeTransfer(address, address, uint256) external pure {}

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory data) {
        if (asset != DEBT || !listed) return data;

        uint256 configuration;
        if (active) configuration |= ACTIVE_BIT;
        if (paused) configuration |= PAUSED_BIT;
        if (flashEnabled) configuration |= FLASH_ENABLED_BIT;
        data.configuration.data = configuration;
        data.aTokenAddress = address(A_TOKEN);
    }
}

/**
 * @title MockMorpho
 * @author Neverland
 * @notice Morpho flash loans of any token it holds
 * @dev `skipCallback` lends and returns without calling back or pulling repayment.
 */
contract MockMorpho {
    bool public skipCallback;
    uint256 public flashLoanCount;
    bytes public callbackData;
    uint256 public callbackAmount;

    /// @notice Overrides the amount reported to the callback while preserving its encoded context
    function setCallbackAmount(uint256 amount) external {
        callbackAmount = amount;
    }

    function setCallbackData(bytes calldata data) external {
        callbackData = data;
    }

    function setSkipCallback(bool skip) external {
        skipCallback = skip;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, "morpho: zero assets");

        ++flashLoanCount;
        IERC20(token).transfer(msg.sender, assets);
        if (skipCallback) return;

        bytes memory echoed = data;
        if (callbackData.length != 0) echoed = callbackData;
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(callbackAmount == 0 ? assets : callbackAmount, echoed);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
    }
}

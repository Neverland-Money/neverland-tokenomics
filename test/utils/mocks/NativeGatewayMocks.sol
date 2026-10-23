// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";

import {INeverlandNativeGateway} from "../../../src/interfaces/INeverlandNativeGateway.sol";

/**
 * @title MockWrappedNative
 * @author Neverland
 * @notice WETH9-shaped wrapped native token for gateway tests
 * @dev Backs every wrapped unit with real ether, so unwrapping can only succeed while the contract
 *      actually holds the balance. Transfers check allowance and balance so a gateway that asks the
 *      pool to pull more than it wrapped reverts here rather than silently succeeding.
 */
contract MockWrappedNative {
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    error InsufficientAllowance();
    error InsufficientBalance();
    error UnwrapTransferFailed();

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        balanceOf[msg.sender] -= amount;

        (bool success,) = msg.sender.call{value: amount}(new bytes(0));
        if (!success) revert UnwrapTransferFailed();
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed < amount) revert InsufficientAllowance();

            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        }

        _transfer(from, to, amount);

        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/**
 * @title MockScaledToken
 * @author Neverland
 * @notice Balance holder standing in for an nToken or a debt token
 * @dev The nToken role also records permit arguments so tests can assert which value was signed over.
 */
contract MockScaledToken {
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    address public lastPermitOwner;
    address public lastPermitSpender;
    uint256 public lastPermitValue;
    uint256 public lastPermitDeadline;
    uint8 public lastPermitV;
    bytes32 public lastPermitR;
    bytes32 public lastPermitS;
    uint256 public permitCallCount;

    bool public revertOnPermit;

    error InsufficientAllowance();
    error InsufficientBalance();
    error PermitConsumed();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        if (balanceOf[from] < amount) revert InsufficientBalance();

        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (revertOnPermit) revert PermitConsumed();

        lastPermitOwner = owner;
        lastPermitSpender = spender;
        lastPermitValue = value;
        lastPermitDeadline = deadline;
        lastPermitV = v;
        lastPermitR = r;
        lastPermitS = s;
        permitCallCount += 1;

        allowance[owner][spender] = value;
    }

    /// @notice Stands in for a permit whose nonce another transaction already spent
    function setRevertOnPermit(bool value) external {
        revertOnPermit = value;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

/**
 * @title MockLendingPool
 * @author Neverland
 * @notice Minimal pool reproducing the reserve wiring and repayment capping the gateway relies on
 * @dev `repay` caps the pull at the outstanding debt exactly as the real pool does, which is what makes
 *      an over-asked repayment fail on the wrapped-token transfer rather than pass unnoticed.
 *
 *      Deliberately more permissive than the real pool in two respects. Stable mode is accepted here,
 *      while `BorrowLogic.executeRepay` rejects it outright. Zero amounts are accepted for supply,
 *      withdraw, borrow and repay, while `ValidationLogic` rejects them with `INVALID_AMOUNT`. Tests
 *      touching either therefore pin the gateway's own branch selection, not an end-to-end flow.
 */
contract MockLendingPool {
    MockWrappedNative public immutable WRAPPED;
    MockScaledToken public immutable N_TOKEN;
    MockScaledToken public immutable STABLE_DEBT;
    MockScaledToken public immutable VARIABLE_DEBT;

    address public lastAsset;
    uint256 public lastAmount;
    address public lastOnBehalfOf;
    address public lastTo;
    uint16 public lastReferralCode;
    uint256 public lastRateMode;
    uint256 public supplyCallCount;
    uint256 public depositCallCount;

    constructor(
        MockWrappedNative wrapped_,
        MockScaledToken nToken_,
        MockScaledToken stable_,
        MockScaledToken variable_
    ) {
        WRAPPED = wrapped_;
        N_TOKEN = nToken_;
        STABLE_DEBT = stable_;
        VARIABLE_DEBT = variable_;
    }

    function getReserveData(address) external view returns (DataTypes.ReserveData memory reserve) {
        reserve.aTokenAddress = address(N_TOKEN);
        reserve.stableDebtTokenAddress = address(STABLE_DEBT);
        reserve.variableDebtTokenAddress = address(VARIABLE_DEBT);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        supplyCallCount += 1;

        _recordSupply(asset, amount, onBehalfOf, referralCode);
    }

    /**
     * @notice Deprecated alias for `supply`
     * @dev Kept here only so the other gateway under differential test can be exercised.
     */
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        depositCallCount += 1;

        _recordSupply(asset, amount, onBehalfOf, referralCode);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        lastAsset = asset;
        lastAmount = amount;
        lastTo = to;

        N_TOKEN.burn(msg.sender, amount);
        WRAPPED.transfer(to, amount);

        return amount;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external
    {
        lastAsset = asset;
        lastAmount = amount;
        lastRateMode = interestRateMode;
        lastReferralCode = referralCode;
        lastOnBehalfOf = onBehalfOf;

        _debtToken(interestRateMode).mint(onBehalfOf, amount);
        WRAPPED.transfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256) {
        lastAsset = asset;
        lastAmount = amount;
        lastRateMode = rateMode;
        lastOnBehalfOf = onBehalfOf;

        MockScaledToken debt = _debtToken(rateMode);
        uint256 owed = debt.balanceOf(onBehalfOf);
        uint256 paid = amount < owed ? amount : owed;

        WRAPPED.transferFrom(msg.sender, address(this), paid);
        debt.burn(onBehalfOf, paid);

        return paid;
    }

    function _recordSupply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) internal {
        lastAsset = asset;
        lastAmount = amount;
        lastOnBehalfOf = onBehalfOf;
        lastReferralCode = referralCode;

        WRAPPED.transferFrom(msg.sender, address(this), amount);
        N_TOKEN.mint(onBehalfOf, amount);
    }

    function _debtToken(uint256 rateMode) internal view returns (MockScaledToken) {
        return DataTypes.InterestRateMode(rateMode) == DataTypes.InterestRateMode.STABLE ? STABLE_DEBT : VARIABLE_DEBT;
    }
}

/**
 * @title MockNativeRejector
 * @author Neverland
 * @notice Recipient that refuses every native transfer
 * @dev Used to reach the gateway's `NativeTransferFailed` branch.
 */
contract MockNativeRejector {
    error NativeNotAccepted();

    receive() external payable {
        revert NativeNotAccepted();
    }
}

/// @dev Which gateway entry point a reentrant recipient attempts on the way back in.
enum ReentryTarget {
    Withdraw,
    Borrow,
    Supply,
    Repay
}

/**
 * @title MockReentrantReceiver
 * @author Neverland
 * @notice Recipient that calls back into the gateway while receiving its native payout
 * @dev Catches the reentrant revert instead of bubbling it, so a test can assert the guard rejected
 *      the second entry while the outer call still completed. The target is selectable because the
 *      guard is shared across every entry point, not per-function.
 */
contract MockReentrantReceiver {
    INeverlandNativeGateway public immutable GATEWAY;

    bool public armed;
    bool public reentered;
    ReentryTarget public target;
    bytes public lastRevertReason;

    constructor(INeverlandNativeGateway gateway_) {
        GATEWAY = gateway_;
    }

    function arm(ReentryTarget target_) external {
        armed = true;
        target = target_;
    }

    receive() external payable {
        if (!armed) return;

        armed = false;

        try this.reenter(target) {
            reentered = true;
        } catch (bytes memory reason) {
            lastRevertReason = reason;
        }
    }

    /**
     * @notice Re-enters the gateway through the armed target
     * @dev External so the reentrant attempt can be caught without unwinding the payout itself.
     */
    function reenter(ReentryTarget target_) external {
        if (target_ == ReentryTarget.Borrow) {
            GATEWAY.borrow(1, 2, 0);
        } else if (target_ == ReentryTarget.Supply) {
            GATEWAY.supply(address(this), 0);
        } else if (target_ == ReentryTarget.Repay) {
            GATEWAY.repay(1, 2, address(this));
        } else {
            GATEWAY.withdraw(1, address(this));
        }
    }
}

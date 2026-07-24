// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {OracleLib} from "../../../src/libraries/OracleLib.sol";

contract CommonChecksHarness {
    function checkZeroAddress(address value) external pure {
        CommonChecksLibrary.revertIfZeroAddress(value);
    }

    function checkZeroAmount(uint256 value) external pure {
        CommonChecksLibrary.revertIfZeroAmount(value);
    }

    function checkInvalidRange(uint256 from, uint256 to) external pure {
        CommonChecksLibrary.revertIfInvalidRange(from, to);
    }

    function checkSameAddress(address first, address second) external pure {
        CommonChecksLibrary.revertIfSameAddress(first, second);
    }

    function checkZeroBalance(uint256 balance) external pure {
        CommonChecksLibrary.revertIfZeroBalance(balance);
    }

    function checkInvalidTokenId(address owner) external pure {
        CommonChecksLibrary.revertIfInvalidTokenId(owner);
    }

    function checkInvalidFromAddress(address from) external pure {
        CommonChecksLibrary.revertIfInvalidFromAddress(from);
    }

    function checkInvalidToAddress(address to) external pure {
        CommonChecksLibrary.revertIfInvalidToAddress(to);
    }

    function checkInvalidUserAddress(address user) external pure {
        CommonChecksLibrary.revertIfInvalidUserAddress(user);
    }

    function checkEpochFinalizationPending(uint256 epochDuration) external view {
        CommonChecksLibrary.revertIfEpochFinalizationPending(epochDuration);
    }
}

contract OracleLibHarness {
    function scale(int256 price, uint8 decimals) external pure returns (int256) {
        return OracleLib.scaleToTargetDecimals(price, decimals);
    }

    function tryScale(uint256 price, uint8 decimals) external pure returns (uint256, bool) {
        return OracleLib.tryScaleToTargetDecimals(price, decimals);
    }

    function tryMulDiv(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256, bool) {
        return OracleLib.tryMulDiv(x, y, denominator);
    }
}

contract LibraryCoverageTest is Test {
    CommonChecksHarness private checks;
    OracleLibHarness private oracleLib;

    function setUp() public {
        checks = new CommonChecksHarness();
        oracleLib = new OracleLibHarness();
    }

    function testRevertIfZeroAddress() public {
        checks.checkZeroAddress(address(1));
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        checks.checkZeroAddress(address(0));
    }

    function testRevertIfZeroAmount() public {
        checks.checkZeroAmount(1);
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        checks.checkZeroAmount(0);
    }

    function testRevertIfInvalidRange() public {
        checks.checkInvalidRange(1, 2);
        vm.expectRevert(CommonChecksLibrary.InvalidRange.selector);
        checks.checkInvalidRange(2, 1);
    }

    function testRevertIfSameAddress() public {
        checks.checkSameAddress(address(1), address(2));
        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        checks.checkSameAddress(address(1), address(1));
    }

    function testRevertIfZeroBalance() public {
        checks.checkZeroBalance(1);
        vm.expectRevert(CommonChecksLibrary.ZeroBalance.selector);
        checks.checkZeroBalance(0);
    }

    function testRevertIfInvalidTokenId() public {
        checks.checkInvalidTokenId(address(1));
        vm.expectRevert(CommonChecksLibrary.InvalidTokenId.selector);
        checks.checkInvalidTokenId(address(0));
    }

    function testRevertIfInvalidFromAddress() public {
        checks.checkInvalidFromAddress(address(1));
        vm.expectRevert(CommonChecksLibrary.InvalidFromAddress.selector);
        checks.checkInvalidFromAddress(address(0));
    }

    function testRevertIfInvalidToAddress() public {
        checks.checkInvalidToAddress(address(1));
        vm.expectRevert(CommonChecksLibrary.InvalidToAddress.selector);
        checks.checkInvalidToAddress(address(0));
    }

    function testRevertIfInvalidUserAddress() public {
        checks.checkInvalidUserAddress(address(1));
        vm.expectRevert(CommonChecksLibrary.InvalidUserAddress.selector);
        checks.checkInvalidUserAddress(address(0));
    }

    function testRevertIfEpochFinalizationPending() public {
        checks.checkEpochFinalizationPending(1 weeks);

        vm.warp(1 weeks);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        checks.checkEpochFinalizationPending(1 weeks);

        vm.warp(1 weeks + 1);
        checks.checkEpochFinalizationPending(1 weeks);
    }

    function testOracleLibScaling() public view {
        assertEq(oracleLib.scale(1e18, 18), 1e8);
        assertEq(oracleLib.scale(1e6, 6), 1e8);
        assertEq(oracleLib.scale(123e8, 8), 123e8);
    }

    function testOracleLibTryScaleToTargetDecimals() public view {
        (uint256 downscaled, bool okDown) = oracleLib.tryScale(1e18, 18);
        assertTrue(okDown);
        assertEq(downscaled, 1e8);

        (uint256 upscaled, bool okUp) = oracleLib.tryScale(1e6, 6);
        assertTrue(okUp);
        assertEq(upscaled, 1e8);

        (uint256 same, bool okSame) = oracleLib.tryScale(123e8, 8);
        assertTrue(okSame);
        assertEq(same, 123e8);
    }

    function testOracleLibTryScaleToTargetDecimalsOverflow() public view {
        (uint256 scaled, bool ok) = oracleLib.tryScale(type(uint256).max, 0);
        assertFalse(ok);
        assertEq(scaled, 0);
    }

    function testOracleLibTryMulDiv() public view {
        (uint256 result, bool ok) = oracleLib.tryMulDiv(6, 7, 3);
        assertTrue(ok);
        assertEq(result, 14);
    }

    function testOracleLibTryMulDivDenominatorZero() public view {
        (uint256 result, bool ok) = oracleLib.tryMulDiv(1, 1, 0);
        assertFalse(ok);
        assertEq(result, 0);
    }

    function testOracleLibTryMulDivOverflow() public view {
        (uint256 result, bool ok) = oracleLib.tryMulDiv(type(uint256).max, type(uint256).max, 1);
        assertFalse(ok);
        assertEq(result, 0);
    }

    function testOracleLibTryMulDivLargeValues() public view {
        uint256 x = uint256(1) << 200;
        uint256 y = uint256(1) << 100;
        (uint256 result, bool ok) = oracleLib.tryMulDiv(x, y, uint256(1) << 50);
        assertTrue(ok);
        assertEq(result, uint256(1) << 250);
    }
}

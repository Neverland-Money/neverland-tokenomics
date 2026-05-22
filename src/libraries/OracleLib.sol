// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title OracleLib
 * @author Neverland
 * @notice Shared utilities for oracle contracts
 */
library OracleLib {
    /// @notice Target decimals for all oracle prices (Chainlink standard)
    uint256 internal constant TARGET_DECIMALS = 8;

    /// @notice Base for decimal exponentiation
    uint256 internal constant DECIMAL_BASE = 10;

    /// @notice Minimum decimals supported for oracle inputs
    uint256 internal constant MIN_DECIMALS = 6;

    /// @notice Maximum decimals supported for oracle inputs
    uint256 internal constant MAX_DECIMALS = 18;

    /**
     * @notice Scales a price to target decimals
     * @param price The price to scale
     * @param decimals The current decimals of the price
     * @return scaledPrice The scaled price with TARGET_DECIMALS decimals
     */
    function scaleToTargetDecimals(int256 price, uint8 decimals) internal pure returns (int256 scaledPrice) {
        if (decimals > TARGET_DECIMALS) {
            uint256 factor = DECIMAL_BASE ** (uint256(decimals) - TARGET_DECIMALS);
            return price / int256(factor);
        } else if (decimals < TARGET_DECIMALS) {
            uint256 factor = DECIMAL_BASE ** (TARGET_DECIMALS - uint256(decimals));
            return price * int256(factor);
        }

        return price;
    }

    /**
     * @notice Safe variant of mulDiv that returns (0, false) on overflow or zero denominator
     * @dev Adapted from OpenZeppelin Math.mulDiv to avoid reverting
     * @param x The first multiplicand
     * @param y The second multiplicand
     * @param denominator The divisor
     * @return result The computed floor(x * y / denominator)
     * @return ok True if the computation succeeded without overflow
     */
    function tryMulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result, bool ok) {
        if (denominator == 0) return (0, false);
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                return (prod0 / denominator, true);
            }

            if (denominator <= prod1) {
                return (0, false);
            }

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            // Bitwise XOR seed from the standard mulDiv modular inverse initialization (not exponentiation).
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
            return (result, true);
        }
    }

    /**
     * @notice Scales a uint256 price to target decimals, returning false on overflow
     * @param price The price to scale
     * @param decimals The current decimals of the price
     * @return scaled The scaled price with TARGET_DECIMALS decimals
     * @return ok True if scaling did not overflow
     */
    function tryScaleToTargetDecimals(uint256 price, uint8 decimals) internal pure returns (uint256 scaled, bool ok) {
        if (decimals > TARGET_DECIMALS) {
            uint256 factor = DECIMAL_BASE ** (uint256(decimals) - TARGET_DECIMALS);
            return (price / factor, true);
        }
        if (decimals < TARGET_DECIMALS) {
            uint256 factor = DECIMAL_BASE ** (TARGET_DECIMALS - uint256(decimals));
            if (price > type(uint256).max / factor) return (0, false);
            return (price * factor, true);
        }
        return (price, true);
    }
}

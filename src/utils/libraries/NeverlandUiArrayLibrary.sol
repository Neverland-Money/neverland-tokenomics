// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title NeverlandUiArrayLibrary
 * @author Neverland
 * @notice Internal array helpers shared by Neverland UI aggregation code.
 * @dev Functions remain internal so callers inline the implementation without adding a deployment or
 *      linked-library dependency.
 */
library NeverlandUiArrayLibrary {
    /**
     * @notice Sorts and deduplicates an address array in ascending order.
     * @dev Mutates `arr` while sorting, then returns a compacted allocation.
     * @param arr Address array to sort and deduplicate.
     * @return sorted Sorted array containing each address once.
     */
    function sortAndDedupAddresses(address[] memory arr) internal pure returns (address[] memory sorted) {
        uint256 len = arr.length;

        if (len == 0) return new address[](0);

        for (uint256 i = 1; i < len; ++i) {
            address key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                unchecked {
                    --j;
                }
            }
            arr[j] = key;
        }

        sorted = new address[](len);
        uint256 n;
        for (uint256 i; i < len; ++i) {
            if (i == 0 || arr[i] != arr[i - 1]) {
                sorted[n] = arr[i];
                unchecked {
                    ++n;
                }
            }
        }

        assembly ("memory-safe") {
            mstore(sorted, n)
        }
    }

    /**
     * @notice Returns a fresh `len`-element address slice starting at `offset`.
     * @dev The caller must ensure `offset + len <= arr.length`.
     * @param arr Source address array.
     * @param offset Index of the first element to copy.
     * @param len Number of elements to copy.
     * @return slice Newly allocated address slice.
     */
    function copyAddressSlice(address[] memory arr, uint256 offset, uint256 len)
        internal
        pure
        returns (address[] memory slice)
    {
        slice = new address[](len);
        for (uint256 i; i < len;) {
            slice[i] = arr[offset + i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns a fresh `len`-element uint256 slice starting at `offset`.
     * @dev The caller must ensure `offset + len <= arr.length`.
     * @param arr Source uint256 array.
     * @param offset Index of the first element to copy.
     * @param len Number of elements to copy.
     * @return slice Newly allocated uint256 slice.
     */
    function copyUint256Slice(uint256[] memory arr, uint256 offset, uint256 len)
        internal
        pure
        returns (uint256[] memory slice)
    {
        slice = new uint256[](len);
        for (uint256 i; i < len;) {
            slice[i] = arr[offset + i];
            unchecked {
                ++i;
            }
        }
    }
}

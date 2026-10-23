// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustLock} from "../../interfaces/IDustLock.sol";
import {INeverlandUiRevenueReward} from "../../interfaces/INeverlandUiRevenueReward.sol";

import {NeverlandUiArrayLibrary} from "./NeverlandUiArrayLibrary.sol";

/**
 * @title NeverlandUiEnumerationLibrary
 * @author Neverland
 * @notice Linked read-only DustLock owned-token enumeration helpers for `NeverlandUiProvider`.
 * @dev Public library functions are intentionally used here so Solidity links the library instead of
 *      inlining this logic into the UI provider runtime (mirrors the other Neverland UI libraries,
 *      added when the plain + resolved surface together pushed the provider over EIP-170). The logic is
 *      behavior-equivalent to what previously lived directly on NeverlandUiProvider; moving where the
 *      bytecode lives does not change any returned value.
 */
library NeverlandUiEnumerationLibrary {
    /// @dev Minimum raw DustLock enumeration slots scanned by one paginated call.
    uint256 private constant MIN_RAW_TOKEN_SCAN_PER_CALL = 32;

    /// @dev Maximum raw DustLock enumeration slots scanned by one paginated call.
    uint256 private constant MAX_RAW_TOKEN_SCAN_PER_CALL = 1024;

    /// @dev Raw slots scanned per requested valid token before applying the maximum scan cap.
    uint256 private constant RAW_TOKEN_SCAN_MULTIPLIER = 32;

    /**
     * @notice Get all tokenIds that contribute rewards to `user`: owned tokens and tokens forwarding
     *         rewards to `user` (self-repay loan).
     * @param dustLock DustLock contract providing owned-token enumeration.
     * @param revenueReward RevenueReward contract providing self-repaying-loan token ids.
     * @param user Account whose related token ids are collected.
     * @return ids Array of tokenIds
     */
    function getUserRelatedTokenIds(IDustLock dustLock, INeverlandUiRevenueReward revenueReward, address user)
        public
        view
        returns (uint256[] memory ids)
    {
        uint256[] memory ownedTokenIds = getValidatedOwnedTokenIds(dustLock, user);
        uint256 owned = ownedTokenIds.length;
        uint256[] memory srl = revenueReward.getUserTokensWithSelfRepayingLoan(user);

        if (owned == 0 && srl.length == 0) return new uint256[](0);

        // Preallocate max size, then shrink
        uint256[] memory tmp = new uint256[](owned + srl.length);
        uint256 n = 0;

        // Add owned tokenIds (unique by ERC721 invariant)
        for (uint256 i; i < owned;) {
            n = _appendTokenId(tmp, n, ownedTokenIds[i]);
            unchecked {
                ++i;
            }
        }

        // Add current-owner or burned SRL tokenIds, dedup against owned ids (the SRL set itself is unique).
        if (srl.length > 0) {
            for (uint256 j; j < srl.length;) {
                uint256 tokenId = srl[j];
                bool duplicate = false;
                for (uint256 k; k < n;) {
                    if (tmp[k] == tokenId) {
                        duplicate = true;
                        break;
                    }
                    unchecked {
                        ++k;
                    }
                }
                if (!duplicate && _tokenIsOwnedByUser(dustLock, user, tokenId, true)) {
                    n = _appendTokenId(tmp, n, tokenId);
                }
                unchecked {
                    ++j;
                }
            }
        }

        // Resize to actual length
        ids = NeverlandUiArrayLibrary.copyUint256Slice(tmp, 0, n);
    }

    /**
     * @notice Get currently owned tokenIds from DustLock's enumerable list, skipping stale entries.
     * @param dustLock DustLock contract providing owned-token enumeration and ownership checks.
     * @param user The owner address to enumerate.
     * @return ids Array of tokenIds still owned by `user`.
     */
    function getValidatedOwnedTokenIds(IDustLock dustLock, address user) public view returns (uint256[] memory ids) {
        uint256 tokenCount = dustLock.balanceOf(user);
        uint256 upperBound = _ownedTokenIndexUpperBound(dustLock, tokenCount);

        (ids,) = _scanOwnedTokenPage(dustLock, user, 0, upperBound, tokenCount);
    }

    /**
     * @notice Returns a compacted page of owned token ids, skipping stale raw enumerable slots.
     * @param dustLock DustLock contract providing owned-token enumeration and ownership checks.
     * @param user The owner address to enumerate.
     * @param offset Raw enumerable index to start scanning from.
     * @param limit Maximum valid token ids to collect.
     * @return ids Valid token ids for this page.
     * @return tokenCount Current live balance reported by DustLock.
     * @return nextRawOffset Raw enumerable index for the next page.
     * @return hasMore Whether this page left expected live entries or sparse raw slots unscanned.
     */
    function getValidatedOwnedTokenPage(IDustLock dustLock, address user, uint256 offset, uint256 limit)
        public
        view
        returns (uint256[] memory ids, uint256 tokenCount, uint256 nextRawOffset, bool hasMore)
    {
        tokenCount = dustLock.balanceOf(user);
        uint256 upperBound = _ownedTokenIndexUpperBound(dustLock, tokenCount);
        nextRawOffset = offset > upperBound ? upperBound : offset;
        uint256 scanStart = nextRawOffset;
        uint256 liveSlotsRemaining = tokenCount;
        if (scanStart < tokenCount) liveSlotsRemaining = tokenCount - scanStart;
        uint256 pageLen = limit < liveSlotsRemaining ? limit : liveSlotsRemaining;

        if (pageLen == 0) return (new uint256[](0), tokenCount, nextRawOffset, false);

        uint256 scanEnd = rawTokenScanEnd(nextRawOffset, upperBound, limit);

        // Clamp the page buffer to the raw-scan budget so a large `limit` can't over-allocate `tmp`.
        if (scanEnd > nextRawOffset) {
            uint256 scanRange = scanEnd - nextRawOffset;
            if (scanRange < pageLen) pageLen = scanRange;
        } else {
            pageLen = 0;
        }

        (ids, nextRawOffset) = _scanOwnedTokenPage(dustLock, user, nextRawOffset, scanEnd, pageLen);

        bool returnedEveryCompactEntry =
            scanStart < tokenCount && nextRawOffset >= tokenCount && ids.length == liveSlotsRemaining;
        hasMore = nextRawOffset < upperBound && !returnedEveryCompactEntry;
    }

    /**
     * @notice Returns the exclusive raw index boundary for one paginated scan.
     * @dev Public specifically so tests can exercise the bounds arithmetic directly.
     * @param start Raw enumerable index where the scan starts.
     * @param upperBound Global exclusive raw index upper bound.
     * @param limit Requested valid-token page size.
     * @return scanEnd Exclusive raw index where this call must stop scanning.
     */
    function rawTokenScanEnd(uint256 start, uint256 upperBound, uint256 limit) public pure returns (uint256 scanEnd) {
        if (start >= upperBound || limit == 0) return start;

        uint256 scanBudget;
        unchecked {
            scanBudget = limit > type(uint256).max / RAW_TOKEN_SCAN_MULTIPLIER
                ? type(uint256).max
                : limit * RAW_TOKEN_SCAN_MULTIPLIER;
        }
        scanBudget = scanBudget < MIN_RAW_TOKEN_SCAN_PER_CALL ? MIN_RAW_TOKEN_SCAN_PER_CALL : scanBudget;
        if (scanBudget > MAX_RAW_TOKEN_SCAN_PER_CALL) {
            scanBudget = MAX_RAW_TOKEN_SCAN_PER_CALL;
        }

        uint256 remaining = upperBound - start;

        return start + (scanBudget < remaining ? scanBudget : remaining);
    }

    /**
     * @notice Runs the stale-slot-skipping scan loop for one page. Split out of
     *         `getValidatedOwnedTokenPage` purely to keep both functions' stack frames small under
     *         the legacy (non-viaIR) codegen this repo builds with.
     * @param dustLock DustLock contract providing owned-token enumeration and ownership checks.
     * @param user Expected owner of every returned token id.
     * @param startOffset Raw enumerable index to start scanning from.
     * @param scanEnd Exclusive raw index where this scan must stop.
     * @param pageLen Maximum valid token ids to collect.
     * @return ids Valid token ids collected in this scan.
     * @return nextRawOffset Raw enumerable index the scan stopped at.
     */
    function _scanOwnedTokenPage(
        IDustLock dustLock,
        address user,
        uint256 startOffset,
        uint256 scanEnd,
        uint256 pageLen
    ) private view returns (uint256[] memory ids, uint256 nextRawOffset) {
        uint256[] memory tmp = new uint256[](pageLen);
        uint256 n;
        nextRawOffset = startOffset;
        while (n < pageLen && nextRawOffset < scanEnd) {
            n = _tryAppendOwnedTokenAtRawIndex(dustLock, user, nextRawOffset, tmp, n);
            unchecked {
                ++nextRawOffset;
            }
        }

        ids = NeverlandUiArrayLibrary.copyUint256Slice(tmp, 0, n);
    }

    /**
     * @notice Appends the valid owned token found at one raw enumerable index, if any.
     * @dev Fails soft when the raw slot is stale or unreadable and preserves `length` in that case.
     * @param dustLock DustLock contract providing owned-token enumeration and ownership checks.
     * @param user Expected token owner.
     * @param rawIndex Raw enumerable index to inspect.
     * @param buffer Preallocated token-id buffer.
     * @param length Number of populated entries in `buffer`.
     * @return nextLength Updated populated length after the best-effort append.
     */
    function _tryAppendOwnedTokenAtRawIndex(
        IDustLock dustLock,
        address user,
        uint256 rawIndex,
        uint256[] memory buffer,
        uint256 length
    ) private view returns (uint256 nextLength) {
        nextLength = length;
        try dustLock.ownerToNFTokenIdList(user, rawIndex) returns (uint256 tokenId) {
            if (_tokenIsOwnedByUser(dustLock, user, tokenId, false)) {
                nextLength = _appendTokenId(buffer, length, tokenId);
            }
        } catch {
            // Skip stale or corrupt enumerable entries.
        }
    }

    /**
     * @notice Returns a bounded raw enumerable index limit for owned-token scans.
     * @dev `balanceOf` counts live tokens, not max raw index; use DustLock.tokenId() as the global bound, falling back to `tokenCount` if unreadable.
     * @param dustLock DustLock contract providing the global token id bound.
     * @param tokenCount Current live balance reported by DustLock.
     * @return upperBound Exclusive raw index upper bound.
     */
    function _ownedTokenIndexUpperBound(IDustLock dustLock, uint256 tokenCount)
        private
        view
        returns (uint256 upperBound)
    {
        if (tokenCount == 0) return 0;

        try dustLock.tokenId() returns (uint256 maxTokenId) {
            upperBound = maxTokenId;
        } catch {
            upperBound = tokenCount;
        }
        if (upperBound < tokenCount) upperBound = tokenCount;
    }

    /**
     * @notice Returns true when a nonzero token belongs to `user`, optionally retaining burned SRL ids.
     * @dev A successful ownership read for another owner always returns false. When `retainBurned` is
     *      true, a reverting ownership read is retained because RevenueReward deliberately preserves
     *      burned SRL rewards for salvage by the stored vault.
     * @param dustLock DustLock contract providing the ownership check.
     * @param user Expected owner address.
     * @param tokenId Token id to verify.
     * @param retainBurned Whether a reverting ownership read represents a retained burned SRL id.
     * @return ownedByUser True when the token currently belongs to `user` or is a retained burned SRL id.
     */
    function _tokenIsOwnedByUser(IDustLock dustLock, address user, uint256 tokenId, bool retainBurned)
        private
        view
        returns (bool ownedByUser)
    {
        if (tokenId == 0) return false;

        try dustLock.ownerOf(tokenId) returns (address owner) {
            return owner == user;
        } catch {
            return retainBurned;
        }
    }

    /**
     * @notice Appends one token id to a preallocated buffer.
     * @dev The caller must ensure `length < buffer.length`.
     * @param buffer Preallocated token-id buffer.
     * @param length Number of populated entries before the append.
     * @param tokenId Token id to append.
     * @return nextLength Populated length after the append.
     */
    function _appendTokenId(uint256[] memory buffer, uint256 length, uint256 tokenId)
        private
        pure
        returns (uint256 nextLength)
    {
        buffer[length] = tokenId;
        unchecked {
            nextLength = length + 1;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiveTipping {
    /**
     * @dev Returns the total amount of tips accumulated for a specific event.
     */
    function getTotalTips(uint256 eventId) external view returns (uint256);

    /**
     * @dev Returns the address of the user who has contributed the most tips.
     * Returns address(0) if there are no tippers.
     */
    function getHighestTipper(uint256 eventId) external view returns (address);
}
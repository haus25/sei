// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiveTipping {
    /**
     * @dev Register a new event for tipping (called by EventFactory)
     */
    function registerEvent(
        uint256 eventId,
        address creator,
        uint256 startDate,
        uint256 duration, // in minutes
        uint256 reservePrice
    ) external;

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
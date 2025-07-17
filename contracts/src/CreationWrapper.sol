// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IEventFactory.sol";
import "../interfaces/IEventManager.sol";

contract CreationWrapper {
    IEventFactory public immutable eventFactory;
    IEventManager public immutable eventManager;

    constructor(address _factory, address _manager) {
        eventFactory = IEventFactory(_factory);
        eventManager = IEventManager(_manager);
    }

    /**
     * @dev Bundles event creation and proxy deployment into a single transaction.
     * The user calls this function once.
     */
    function createEventAndDelegate(
        // Params for EventFactory.createEvent
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        string calldata metadataURI,
        string calldata artCategory,
        uint256 ticketsAmount,
        uint256 ticketPrice,
        // Param for EventManager.createDelegationProxyForUser
        address delegatee
    ) external {
        // 1. Call EventFactory to create the event for the user and get the new eventId
        uint256 newEventId = eventFactory.createEventForCreator(
            msg.sender, // The user who called this function
            startDate,
            eventDuration,
            reservePrice,
            metadataURI,
            artCategory,
            ticketsAmount,
            ticketPrice
        );

        // 2. Call EventManager to create the delegation proxy for the new event
        // Use the new function that allows the CreationWrapper to create proxies on behalf of users
        if (delegatee != address(0)) {
            eventManager.createDelegationProxyForUser(newEventId, msg.sender, delegatee);
        }
    }
}

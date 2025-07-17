// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEventManager {
    function createDelegationProxy(uint256 eventId, address delegatee) external;
    function createDelegationProxyForUser(uint256 eventId, address eventCreator, address delegatee) external;
    function updateMetadata(uint256 eventId, string memory newMetadataURI) external;
    function updateReservePrice(uint256 eventId, uint256 newReservePrice) external;
    function finalizeRTA(uint256 eventId) external;
    function setCreationWrapper(address _creationWrapper) external;
}
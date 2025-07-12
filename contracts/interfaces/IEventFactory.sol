// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IEventFactory
 * Defines all external functions, structs, and events that other contracts can interact with.
 */
interface IEventFactory {
    // --- Structs ---
    // The core data structure for an event, returned by getEvent().
    struct EventData {
        address creator;
        uint256 startDate;
        uint256 reservePrice;
        string metadataURI;
        address ticketFactoryAddress;
        bool finalized;
    }

    // --- Events ---
    event EventCreated(
        uint256 indexed eventId,
        address indexed creator,
        uint256 startDate,
        uint256 reservePrice,
        string metadataURI,
        address ticketFactoryAddress
    );
    event MetadataUpdated(uint256 indexed eventId, string newMetadataURI);
    event ReservePriceUpdated(uint256 indexed eventId, uint256 newReservePrice);
    event EventFinalizedAndTransferred(uint256 indexed eventId, address indexed highestTipper);

    // --- Core Functions ---

    /**
     * @dev Creates a new RTA NFT event.
     */
    function createEvent(
        uint256 startDate,
        uint256 reservePrice,
        string calldata metadataURI,
        uint256 ticketsAmount,
        uint256 ticketPrice
    ) external returns (uint256 eventId);

    // --- State-Changing Functions (Callable only by EventManager) ---

    /**
     * @dev Allows the authorized EventManager to update the metadata URI.
     */
    function setMetadataURI(uint256 eventId, string memory newMetadataURI) external;

    /**
     * @dev Allows the authorized EventManager to update the reserve price.
     */
    function setReservePrice(uint256 eventId, uint256 newReservePrice) external;

    /**
     * @dev Allows the authorized EventManager to finalize an event and transfer the NFT.
     */
    function finalizeAndTransfer(uint256 eventId) external;

    // --- View Functions ---

    /**
     * @dev Retrieves the complete data for a specific event.
     */
    function getEvent(uint256 eventId) external view returns (EventData memory);

    /**
     * @dev Returns the owner of the specified RTA NFT. From ERC721.
     */
    function ownerOf(uint256 eventId) external view returns (address);
}
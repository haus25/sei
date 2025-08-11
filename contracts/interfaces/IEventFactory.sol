// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC721.sol";

interface IEventFactory is IERC721 {
    struct EventData {
        address creator;        // 20 bytes
        address KioskAddress;   // 20 bytes (packed in slot 1)
        address curationAddress; // 20 bytes (packed in slot 2) 
        uint96 startDate;       // 12 bytes (packed with creator in slot 0)
        uint96 eventDuration;   // 12 bytes (packed with KioskAddress in slot 1)
        uint96 reservePrice;    // 12 bytes (packed with curationAddress in slot 2)
        bool finalized;         // 1 byte (packed with reservePrice)
        string metadataURI;     // separate slot
        string artCategory;     // separate slot
    }

    function createEvent(
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        string calldata metadataURI,
        string calldata artCategory,
        uint256 ticketsAmount,
        uint256 ticketPrice
    ) external returns (uint256 eventId);

    function createEventForCreator(
        address creator,
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        string calldata metadataURI,
        string calldata artCategory,
        uint256 ticketsAmount,
        uint256 ticketPrice
    ) external returns (uint256 eventId);

    function deployCurationForEvent(
        uint256 eventId,
        uint256 scope,
        string calldata description
    ) external returns (address curationAddress);

    function getCurationContract(uint256 eventId) external view returns (address);
    function getTicketKiosk(uint256 eventId) external view returns (address);
    function getEvent(uint256 eventId) external view returns (EventData memory);
    function totalEvents() external view returns (uint256);
    function getCreatorEvents(address creator) external view returns (uint256[] memory);
    function getAllTicketKiosks() external view returns (uint256[] memory eventIds, address[] memory kioskAddresses);
    
    // EventManager functions
    function setMetadataURI(uint256 eventId, string memory newMetadataURI) external;
    function setReservePrice(uint256 eventId, uint256 newReservePrice) external;
    function finalizeAndTransfer(uint256 eventId) external;

    event EventCreated(
        uint256 indexed eventId,
        address indexed creator,
        uint256 startDate,
        uint256 reservePrice,
        string metadataURI,
        string artCategory,
        address ticketKioskAddress
    );

    event CurationDeployed(
        uint256 indexed eventId,
        address indexed creator,
        address curationContract,
        uint256 scope
    );
}
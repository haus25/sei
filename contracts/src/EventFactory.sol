// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/EventFactoryLib.sol";
import "../interfaces/IDistributor.sol";
import "../interfaces/IEventManager.sol";
import "../interfaces/ILiveTipping.sol";

/**
 * @title EventFactory
 * @dev A lightweight, modular ERC721 NFT factory for RTA events.
 * Responsibilities:
 * 1. Mint Event NFTs (ERC721).
 * 2. Deploy a unique TicketKiosk for each event.
 * 3. Act as a central registry linking eventId to its data and associated contracts.
 * All other logic (Tipping, Curation, Event Management) is handled by standalone contracts.
 */
contract EventFactory is ERC721URIStorage, Ownable {
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

    // State variables
    mapping(uint256 => EventData) public events;
    mapping(address => uint256[]) public creatorEvents;
    
    uint256 public currentEventId;

    // Contract addresses
    address public eventManagerContract;
    address public distributorContract;
    address public liveTippingContract;
    address public treasuryReceiver;

    // Events
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
    event MetadataUpdated(uint256 indexed eventId, string newMetadataURI);
    event ReservePriceUpdated(uint256 indexed eventId, uint256 newPrice);
    event EventFinalizedAndTransferred(uint256 indexed eventId, address indexed highestTipper);
    event EventFinalized(uint256 indexed eventId);
    
    // Custom errors
    error InvalidInput();
    error DeploymentFailed();
    error OnlyEventManager();
    error EventAlreadyFinalized();
    error ReservePriceNotMet();
    error NoTippers();
    error StartDateHasPassed();
    error EventNotEndedYet();
    error AlreadyInitialized();
    error OnlyOwner();

    /**
     * @dev Constructor that initializes the contract
     */
    constructor() ERC721("Real-Time Asset", "RTA") Ownable(msg.sender) {
        // Initialize with deployer as owner initially
        // The actual owner will be set during deployment
    }

    /**
     * @dev Initializes the contract addresses after deployment
     */
    function initialize(
        address _owner,
        address _eventManager,
        address _distributor,
        address _liveTipping,
        address _treasuryReceiver
    ) external {
        if (eventManagerContract != address(0)) revert AlreadyInitialized();
        if (msg.sender != owner()) revert OnlyOwner();
        
        eventManagerContract = _eventManager;
        distributorContract = _distributor;
        liveTippingContract = _liveTipping;
        treasuryReceiver = _treasuryReceiver;
        
        // Transfer ownership to the intended owner if different
        if (_owner != owner()) {
            _transferOwnership(_owner);
        }
    }



    /**
     * @dev Creates a new RTA NFT event and deploys its associated TicketKiosk.
     */
    function createEvent(
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        string calldata metadataURI,
        string calldata artCategory,
        uint256 ticketsAmount,
        uint256 ticketPrice
    ) external returns (uint256 eventId) {
        return createEventForCreator(
            msg.sender,
            startDate,
            eventDuration,
            reservePrice,
            metadataURI,
            artCategory,
            ticketsAmount,
            ticketPrice
        );
    }

    /**
     * @dev Creates a new RTA NFT event for a specific creator and deploys its associated TicketKiosk.
     * This version allows specifying the creator address, useful for wrapper contracts.
     */
    function createEventForCreator(
        address creator,
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        string calldata metadataURI,
        string calldata artCategory,
        uint256 ticketsAmount,
        uint256 ticketPrice
    ) public returns (uint256 eventId) {
        // Validate inputs fit in optimized storage
        require(startDate <= type(uint96).max, "Start date too large");
        require(eventDuration <= type(uint96).max, "Duration too large");
        require(reservePrice <= type(uint96).max, "Reserve price too large");
        uint256 newEventId = currentEventId++;

        // 1. Mint RTA NFT to the creator
        _safeMint(creator, newEventId);
        _setTokenURI(newEventId, metadataURI);

        // 2. Deploy TicketKiosk for this event using CREATE2 for a deterministic address
        address ticketKioskAddress = EventFactoryLib.deployTicketKiosk(
            newEventId, address(this), creator, ticketsAmount, ticketPrice, artCategory, treasuryReceiver
        );
        if (ticketKioskAddress == address(0)) revert DeploymentFailed();

        // 3. Store event data (optimized storage packing)
        events[newEventId] = EventData({
            creator: creator,
            KioskAddress: ticketKioskAddress,
            curationAddress: address(0), // Will be set when curation is activated
            startDate: uint96(startDate),
            eventDuration: uint96(eventDuration),
            reservePrice: uint96(reservePrice),
            finalized: false,
            metadataURI: metadataURI,
            artCategory: artCategory
        });

        creatorEvents[creator].push(newEventId);

        // 4. Register with external contracts using library
        EventFactoryLib.registerWithExternalContracts(
            newEventId,
            creator,
            startDate,
            eventDuration,
            reservePrice,
            distributorContract,
            liveTippingContract
        );

        emit EventCreated(newEventId, creator, startDate, reservePrice, metadataURI, artCategory, ticketKioskAddress);
        
        return newEventId;
    }

    // --- Functions callable only by EventManager ---

    /**
     * @dev Allows the authorized EventManager contract to update the metadata URI.
     * The EventManager is responsible for handling all permission logic (e.g., only creator or delegate).
     */
    function setMetadataURI(uint256 eventId, string memory newMetadataURI) external {
        if (msg.sender != eventManagerContract) revert OnlyEventManager();
        if (events[eventId].finalized) revert EventAlreadyFinalized();
        
        events[eventId].metadataURI = newMetadataURI;
        _setTokenURI(eventId, newMetadataURI);
        
        emit MetadataUpdated(eventId, newMetadataURI);
    }

    /**
     * @dev Allows the authorized EventManager contract to update the reserve price.
     */
    function setReservePrice(uint256 eventId, uint256 newReservePrice) external {
        if (msg.sender != eventManagerContract) revert OnlyEventManager();
        if (events[eventId].finalized) revert EventAlreadyFinalized();
        if (block.timestamp >= events[eventId].startDate) revert StartDateHasPassed();
        require(newReservePrice <= type(uint96).max, "Reserve price too large");

        events[eventId].reservePrice = uint96(newReservePrice);
        emit ReservePriceUpdated(eventId, newReservePrice);
    }

    /**
     * @dev Allows the authorized EventManager contract to finalize an event.
     */
    function setFinalized(uint256 eventId) external {
        if (msg.sender != eventManagerContract) revert OnlyEventManager();
        if (events[eventId].finalized) revert EventAlreadyFinalized();

        events[eventId].finalized = true;
        emit EventFinalized(eventId);
    }

    /**
     * @dev Business logic function for finalization and transfer.
     * Called by the EventManager to check conditions and transfer the NFT.
     * Integrates with LiveTipping for complete finalization flow.
     */
    function finalizeAndTransfer(uint256 eventId) external {
        if (msg.sender != eventManagerContract) revert OnlyEventManager();
        if (events[eventId].finalized) revert EventAlreadyFinalized();

        // 1. Get current event data
        EventData storage eventData = events[eventId];
        
        // 2. Verify event has ended
        uint256 eventEndTime = eventData.startDate + (eventData.eventDuration * 60);
        if (block.timestamp <= eventEndTime) revert EventNotEndedYet();
        
        // 3. Get tipping data from LiveTipping contract
        ILiveTipping tippingContract = ILiveTipping(liveTippingContract);
        uint256 totalTips = tippingContract.getTotalTips(eventId);
        
        // 4. Check if reserve price is met
        if (totalTips < eventData.reservePrice) revert ReservePriceNotMet();

        // 5. Get highest tipper
        address highestTipper = tippingContract.getHighestTipper(eventId);
        if (highestTipper == address(0)) {
            revert NoTippers();
        }
        
        // 6. Mark event as finalized first
        eventData.finalized = true;

        // 7. Transfer NFT to the highest tipper
        _transfer(eventData.creator, highestTipper, eventId);
        
        // 8. Emit finalization event
        emit EventFinalizedAndTransferred(eventId, highestTipper);
        
        // 9. Note: Fund distribution is handled separately through the Distributor contract
        // The tips remain in the LiveTipping contract until explicitly distributed
    }
    
    /**
     * @dev Deploy curation contract for an event (only by event creator)
     */
    function deployCurationForEvent(
        uint256 eventId,
        uint256 scope,
        string calldata description
    ) external returns (address curationAddress) {
        require(events[eventId].creator == msg.sender, "Only event creator can deploy curation");
        require(events[eventId].curationAddress == address(0), "Curation already deployed");
        require(scope >= 1 && scope <= 3, "Invalid scope");

        // Deploy Curation contract using CREATE2 for deterministic address
        curationAddress = EventFactoryLib.deployCuration(
            eventId, address(this), msg.sender, scope, description, distributorContract
        );
        if (curationAddress == address(0)) revert DeploymentFailed();

        // Update event data
        events[eventId].curationAddress = curationAddress;

        // Register curation with Distributor using library
        EventFactoryLib.registerCurationWithDistributor(eventId, curationAddress, distributorContract);

        emit CurationDeployed(eventId, msg.sender, curationAddress, scope);
        
        return curationAddress;
    }

    /**
     * @dev Returns the TicketKiosk address for a specific event.
     */
    function getTicketKiosk(uint256 eventId) external view returns (address) {
        return events[eventId].KioskAddress;
    }

    /**
     * @dev Returns the Curation address for a specific event.
     */
    function getCurationContract(uint256 eventId) external view returns (address) {
        return events[eventId].curationAddress;
    }

    /**
     * @dev Returns all TicketKiosk addresses and their corresponding event IDs.
     */
    function getAllTicketKiosks() external view returns (uint256[] memory eventIds, address[] memory kioskAddresses) {
        uint256 totalEventsCount = currentEventId;
        eventIds = new uint256[](totalEventsCount);
        kioskAddresses = new address[](totalEventsCount);
        
        for (uint256 i = 0; i < totalEventsCount; i++) {
            eventIds[i] = i;
            kioskAddresses[i] = events[i].KioskAddress;
        }
        
        return (eventIds, kioskAddresses);
    }

    /**
     * @dev Returns the full data struct for a given event.
     * For other contracts to easily get event data.
     */
    function getEvent(uint256 eventId) external view returns (EventData memory) {
        return events[eventId];
    }

    /**
     * @dev Returns the total number of events created.
     */
    function totalEvents() external view returns (uint256) {
        return currentEventId;
    }

    /**
     * @dev Returns the events created by a specific creator.
     */
    function getCreatorEvents(address creator) external view returns (uint256[] memory) {
        return creatorEvents[creator];
    }

    /**
     * @dev Returns the addresses of the standalone contracts.
     */
    function getStandaloneContracts() external view returns (address, address, address, address) {
        return (liveTippingContract, address(0), address(0), distributorContract);
    }

    // Internal & View Functions

    function _baseURI() internal pure override returns (string memory) {
        return ""; // URIs are set individually
    }

    // Override required by Solidity for multiple inheritance
    function tokenURI(uint256 tokenId) public view override(ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
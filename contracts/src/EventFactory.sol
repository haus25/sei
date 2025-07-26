// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "./TicketKiosk.sol";
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
        address creator;
        uint256 startDate;
        uint256 eventDuration;
        uint256 reservePrice;
        string metadataURI;
        string artCategory;
        address KioskAddress;
        bool finalized;
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
        // Only allow initialization once and only by the current owner
        require(eventManagerContract == address(0), "Already initialized");
        require(msg.sender == owner(), "Only owner can initialize");
        
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
        uint256 newEventId = currentEventId++;

        // 1. Mint RTA NFT to the creator
        _safeMint(creator, newEventId);
        _setTokenURI(newEventId, metadataURI);

        // 2. Deploy TicketKiosk for this event using CREATE2 for a deterministic address
        address ticketKioskAddress = _deployTicketKiosk(newEventId, creator, ticketsAmount, ticketPrice, artCategory);
        if (ticketKioskAddress == address(0)) revert DeploymentFailed();

        // 3. Store event data
        events[newEventId] = EventData({
            creator: creator,
            startDate: startDate,
            eventDuration: eventDuration,
            reservePrice: reservePrice,
            metadataURI: metadataURI,
            artCategory: artCategory,
            KioskAddress: ticketKioskAddress,
            finalized: false
        });

        creatorEvents[creator].push(newEventId);

        // 4. Register the new event with the Distributor
        IDistributor(distributorContract).registerEvent(newEventId, creator);

        // 5. Register the new event with LiveTipping
        ILiveTipping(liveTippingContract).registerEvent(
            newEventId, 
            creator, 
            startDate, 
            eventDuration, // duration in minutes
            reservePrice
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
        if (msg.sender != eventManagerContract) revert("Only EventManager allowed");
        if (events[eventId].finalized) revert("Event already finalized");
        
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

        events[eventId].reservePrice = newReservePrice;
        emit ReservePriceUpdated(eventId, newReservePrice);
    }

    /**
     * @dev Allows the authorized EventManager contract to finalize an event.
     */
    function setFinalized(uint256 eventId) external {
        if (msg.sender != eventManagerContract) revert("Only EventManager allowed");
        if (events[eventId].finalized) revert("Event already finalized");

        events[eventId].finalized = true;
        emit EventFinalized(eventId);
    }

    /**
     * @dev Business logic function for transfer.
     * Called by the EventManager to check conditions and transfer the NFT.
     */
    function finalizeAndTransfer(uint256 eventId) external {
        if (msg.sender != eventManagerContract) revert("Only EventManager allowed");
        if (events[eventId].finalized) revert("Event already finalized");

        // 1. Business Logic Check: Call LiveTipping to get data
        ILiveTipping tippingContract = ILiveTipping(liveTippingContract);
        uint256 totalTips = tippingContract.getTotalTips(eventId);
        
        if (totalTips < events[eventId].reservePrice) {
            revert("Reserve Price not met");
        }

         // 2. Get Highest Tipper
        address highestTipper = tippingContract.getHighestTipper(eventId);
        if (highestTipper == address(0)) {
            revert NoTippers();
        }
        
        // 3. Finalize State
        events[eventId].finalized = true;

        // 4. Transfer NFT to the highest tipper
        _transfer(events[eventId].creator, highestTipper, eventId);
        
        emit EventFinalizedAndTransferred(eventId, highestTipper);
    }
    
    /**
     * @dev Returns the TicketKiosk address for a specific event.
     */
    function getTicketKiosk(uint256 eventId) external view returns (address) {
        return events[eventId].KioskAddress;
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
    function _deployTicketKiosk(
        uint256 eventId,
        address creator,
        uint256 ticketsAmount, 
        uint256 ticketPrice,
        string memory artCategory
    ) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(TicketKiosk).creationCode,
            abi.encode(eventId, address(this), creator, ticketsAmount, ticketPrice, artCategory, treasuryReceiver)
        );
        bytes32 salt = keccak256(abi.encodePacked(eventId, "ticketkiosk"));
        return Create2.deploy(0, salt, bytecode);
    }

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
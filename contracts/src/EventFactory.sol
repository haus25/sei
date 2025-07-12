// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "./TicketFactory.sol";
import "../interfaces/IDistributor.sol";
import "../interfaces/IEventManager.sol";
import "../interfaces/ILiveTipping.sol";

/**
 * @title EventFactory
 * @dev A lightweight, modular ERC721 NFT factory for RTA events.
 * Responsibilities:
 * 1. Mint Event NFTs (ERC721).
 * 2. Deploy a unique TicketFactory for each event.
 * 3. Act as a central registry linking eventId to its data and associated contracts.
 * All other logic (Tipping, Curation, Event Management) is handled by standalone contracts.
 */
contract EventFactory is Initializable, ERC721URIStorageUpgradeable, OwnableUpgradeable {
    struct EventData {
        address creator;
        uint256 startDate;
        uint256 eventDuration;
        uint256 reservePrice;
        string metadataURI;
        address ticketFactoryAddress;
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

    // Events
    event EventCreated(
        uint256 indexed eventId,
        address indexed creator,
        uint256 startDate,
        uint256 reservePrice,
        string metadataURI,
        address ticketFactoryAddress
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
     * @dev Initializes the contract, setting the owner and addresses of service contracts.
     */
    function initialize(
        address _owner,
        address _eventManager,
        address _distributor,
        address _liveTipping
    ) public initializer {
        __ERC721_init("Real-Time Asset", "RTA");
        __ERC721URIStorage_init();
        __Ownable_init(_owner);
        eventManagerContract = _eventManager;
        distributorContract = _distributor;
        liveTippingContract = _liveTipping;
    }

    /**
     * @dev Creates a new RTA NFT event and deploys its associated TicketFactory.
     */
    function createEvent(
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        string calldata metadataURI,
        uint256 ticketsAmount,
        uint256 ticketPrice
    ) external returns (uint256 eventId) {
        uint256 newEventId = currentEventId++;

        // 1. Mint RTA NFT to the creator
        _safeMint(msg.sender, newEventId);
        _setTokenURI(newEventId, metadataURI);

        // 2. Deploy TicketFactory for this event using CREATE2 for a deterministic address
        address ticketFactoryAddress = _deployTicketFactory(newEventId, ticketsAmount, ticketPrice);
        if (ticketFactoryAddress == address(0)) revert DeploymentFailed();

        // 3. Store event data
        events[newEventId] = EventData({
            creator: msg.sender,
            startDate: startDate,
            eventDuration: eventDuration,
            reservePrice: reservePrice,
            metadataURI: metadataURI,
            ticketFactoryAddress: ticketFactoryAddress,
            finalized: false
        });

        creatorEvents[msg.sender].push(newEventId);

        // 4. Register the new event with the Distributor
        IDistributor(distributorContract).registerEvent(newEventId, msg.sender);

        emit EventCreated(newEventId, msg.sender, startDate, reservePrice, metadataURI, ticketFactoryAddress);
        
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
    function _deployTicketFactory(
        uint256 eventId, 
        uint256 ticketsAmount, 
        uint256 ticketPrice
    ) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(TicketFactory).creationCode,
            abi.encode(eventId, address(this), msg.sender, ticketsAmount, ticketPrice)
        );
        bytes32 salt = keccak256(abi.encodePacked(eventId, "ticketfactory"));
        return Create2.deploy(0, salt, bytecode);
    }

    function _baseURI() internal pure override returns (string memory) {
        return ""; // URIs are set individually
    }

    // Override required by Solidity for multiple inheritance
    function tokenURI(uint256 tokenId) public view override(ERC721URIStorageUpgradeable) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721URIStorageUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
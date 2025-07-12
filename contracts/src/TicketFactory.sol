// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TicketFactory
 * @dev Creates and manages event tickets as NFTs per RTA event
 * Uses OpenZeppelin ERC721 standard for proper NFT implementation
 * Ticket naming: rta{eventId}_ticket{ticketId}
 */
contract TicketFactory is ERC721, ERC721URIStorage, ReentrancyGuard, Ownable {
    struct TicketData {
        uint256 eventId;
        uint256 ticketId;
        address originalOwner;
        uint256 purchasePrice;
        uint256 purchaseTimestamp;
        string name;         // e.g., "rta5_ticket34"
    }

    uint256 public eventId;
    address public eventFactoryAddress;
    address public creator;

    mapping(uint256 => TicketData) public tickets;           // ticketId => TicketData
    mapping(address => uint256[]) public userTickets;        // user => ticketIds[]
    mapping(address => bool) public hasTicket;               // user => has ticket for this event
    
    uint256 public currentTicketId;
    uint256 public ticketsAmount;    // max tickets from event
    uint256 public ticketPrice;      // price per ticket from event
    uint256 public ticketsSold;
    string public eventMetadataURI;

    event TicketMinted(
        uint256 indexed ticketId,
        address indexed buyer,
        string ticketName,
        uint256 price
    );

    modifier onlyEventFactory() {
        require(msg.sender == eventFactoryAddress, "Only EventFactory can call this");
        _;
    }

    /**
     * @dev Constructor for per-event TicketFactory instance
     */
    constructor(
        uint256 _eventId,
        address _eventFactoryAddress,
        address _creator,
        uint256 _ticketsAmount,
        uint256 _ticketPrice
    ) ERC721(
        string(abi.encodePacked("HAUS Event ", _toString(_eventId), " Tickets")),
        string(abi.encodePacked("HERT", _toString(_eventId)))
    ) Ownable(_creator) {
        eventId = _eventId;
        eventFactoryAddress = _eventFactoryAddress;
        creator = _creator;
        ticketsAmount = _ticketsAmount;
        ticketPrice = _ticketPrice;
        
        currentTicketId = 1;
        ticketsSold = 0;
        
        // Get initial metadata from EventFactory
        eventMetadataURI = _getEventMetadata();
    }

    /**
     * @dev Get metadata from the Event NFT
     */
    function _getEventMetadata() internal view returns (string memory) {
        // Simple interface call to EventFactory to get tokenURI
        (bool success, bytes memory data) = eventFactoryAddress.staticcall(
            abi.encodeWithSignature("tokenURI(uint256)", eventId)
        );
        
        if (success && data.length > 0) {
            return abi.decode(data, (string));
        }
        
        return "";
    }

    /**
     * @dev Purchase a ticket for the event
     */
    function purchaseTicket() external payable nonReentrant returns (uint256 ticketId) {
        require(ticketsSold < ticketsAmount, "All tickets sold");
        require(msg.value >= ticketPrice, "Insufficient payment");
        
        ticketId = currentTicketId++;
        
        // Generate ticket name: rta{eventId}_ticket{ticketId}
        string memory ticketName = string(abi.encodePacked(
            "rta",
            _toString(eventId),
            "_ticket",
            _toString(ticketId)
        ));
        
        // Mint NFT ticket
        _mint(msg.sender, ticketId);
        _setTokenURI(ticketId, eventMetadataURI);
        
        // Store ticket data
        tickets[ticketId] = TicketData({
            eventId: eventId,
            ticketId: ticketId,
            originalOwner: msg.sender,
            purchasePrice: ticketPrice,
            purchaseTimestamp: block.timestamp,
            name: ticketName
        });
        
        // Update user mappings
        userTickets[msg.sender].push(ticketId);
        hasTicket[msg.sender] = true;
        ticketsSold++;
        
        // Refund excess payment
        if (msg.value > ticketPrice) {
            payable(msg.sender).transfer(msg.value - ticketPrice);
        }
        
        emit TicketMinted(ticketId, msg.sender, ticketName, ticketPrice);
        
        return ticketId;
    }

    /**
     * @dev Get ticket information
     */
    function getTicketInfo(uint256 ticketId) external view returns (
        uint256 eventId_,
        address owner,
        address originalOwner,
        uint256 purchasePrice,
        uint256 purchaseTimestamp,
        string memory name,
        string memory metadataURI
    ) {
        require(_ownerOf(ticketId) != address(0), "Ticket does not exist");
        
        TicketData storage ticket = tickets[ticketId];
        return (
            ticket.eventId,
            ownerOf(ticketId),
            ticket.originalOwner,
            ticket.purchasePrice,
            ticket.purchaseTimestamp,
            ticket.name,
            tokenURI(ticketId)
        );
    }

    /**
     * @dev Get user's tickets for this event
     */
    function getUserTickets(address user) external view returns (uint256[] memory) {
        return userTickets[user];
    }

    /**
     * @dev Check if user has ticket for this event
     */
    function hasTicketForEvent(address user, uint256 _eventId) external view returns (bool) {
        require(_eventId == eventId, "Wrong event ID");
        return hasTicket[user];
    }

    /**
     * @dev Get event ticket sales info
     */
    function getSalesInfo() external view returns (
        uint256 totalTickets,
        uint256 soldTickets,
        uint256 remainingTickets,
        uint256 price
    ) {
        return (
            ticketsAmount,
            ticketsSold,
            ticketsAmount - ticketsSold,
            ticketPrice
        );
    }

    /**
     * @dev Get event metadata copied from Event NFT
     */
    function getEventMetadata() external view returns (string memory) {
        return eventMetadataURI;
    }

    /**
     * @dev Update metadata URI (only event factory or owner)
     */
    function updateMetadata(string memory newMetadataURI) external {
        require(
            msg.sender == eventFactoryAddress || msg.sender == owner(),
            "Only EventFactory or owner can update metadata"
        );
        
        eventMetadataURI = newMetadataURI;
        
        // Update all existing tickets with new metadata
        for (uint256 i = 1; i < currentTicketId; i++) {
            if (_ownerOf(i) != address(0)) {
                _setTokenURI(i, newMetadataURI);
            }
        }
    }

    /**
     * @dev Get total supply of tickets minted
     */
    function totalSupply() external view returns (uint256) {
        return ticketsSold;
    }

    /**
     * @dev Check if tickets are still available
     */
    function isAvailable() external view returns (bool) {
        return ticketsSold < ticketsAmount;
    }

    /**
     * @dev Helper function to convert uint to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // Override required by Solidity for multiple inheritance
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
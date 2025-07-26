// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/IEventFactory.sol";

/**
 * @title LiveTipping
 * @dev Standalone contract for managing live tipping across all events
 * References EventFactory to map event IDs to their tipping data
 */
contract LiveTipping is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    struct EventTippingData {
        address creator;
        uint256 startDate;
        uint256 endDate;
        uint256 reservePrice;
        uint256 totalTips;
        address highestTipper;
        uint256 highestTip;
        bool finalized;
        mapping(address => uint256) tips;
        mapping(address => uint256) tipCounts;
        address[] tippers;
    }

    struct TipData {
        address tipper;
        uint256 amount;
        uint256 timestamp;
        string message;
    }

    // State variables
    mapping(uint256 => EventTippingData) public eventTipping;
    mapping(uint256 => TipData[]) public eventTips;
    mapping(uint256 => mapping(address => uint256[])) public tipperTips; // eventId => tipper => tipIds
    
    address public eventFactoryAddress;
    address public distributorContract;
    address public treasury;

    // Custom errors for bytecode optimization
    error EventNotRegistered();
    error EventAlreadyFinalized();
    error EventNotStarted();
    error EventEnded();
    error EventNotEnded();
    error OnlyEventFactory();
    error OnlyEventCreator();
    error InvalidTipAmount();
    error InvalidInput();
    error TransferFailed();
    error ReservePriceNotMet();

    // Events
    event EventRegistered(
        uint256 indexed eventId,
        address indexed creator,
        uint256 startDate,
        uint256 endDate,
        uint256 reservePrice
    );
    
    event TipReceived(
        uint256 indexed eventId,
        address indexed tipper,
        uint256 amount,
        string message,
        uint256 tipId
    );
    
    event NewHighestTipper(
        uint256 indexed eventId,
        address indexed previousHighest,
        address indexed newHighest,
        uint256 amount
    );
    
    event EventFinalized(
        uint256 indexed eventId,
        address indexed highestTipper,
        uint256 totalTips,
        bool reservePriceMet
    );
    
    event TipsDistributed(uint256 indexed eventId, address indexed distributor, uint256 amount);

    modifier onlyEventFactory() {
        if (msg.sender != eventFactoryAddress) revert OnlyEventFactory();
        _;
    }

    modifier onlyEventCreator(uint256 eventId) {
        if (eventTipping[eventId].creator != msg.sender) revert OnlyEventCreator();
        _;
    }

    modifier eventExists(uint256 eventId) {
        if (eventTipping[eventId].creator == address(0)) revert EventNotRegistered();
        _;
    }

    modifier eventInProgress(uint256 eventId) {
        uint256 currentTime = block.timestamp;
        if (currentTime < eventTipping[eventId].startDate) revert EventNotStarted();
        if (currentTime > eventTipping[eventId].endDate) revert EventEnded();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _creator,
        address _eventFactoryAddress,
        address _distributorContract,
        address _treasury
    ) public initializer {
        __Ownable_init(_creator);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_eventFactoryAddress == address(0)) revert InvalidInput();
        if (_treasury == address(0)) revert InvalidInput();

        eventFactoryAddress = _eventFactoryAddress;
        distributorContract = _distributorContract;
        treasury = _treasury;
    }

    /**
     * @dev Register a new event for tipping (called by EventFactory)
     */
    function registerEvent(
        uint256 eventId,
        address creator,
        uint256 startDate,
        uint256 duration, // in minutes
        uint256 reservePrice
    ) external onlyEventFactory {
        if (eventTipping[eventId].creator != address(0)) revert InvalidInput();
        if (startDate <= block.timestamp) revert InvalidInput();
        if (duration == 0) revert InvalidInput();
        if (reservePrice == 0) revert InvalidInput();

        uint256 endDate = startDate + (duration * 60); // Convert minutes to seconds

        EventTippingData storage eventData = eventTipping[eventId];
        eventData.creator = creator;
        eventData.startDate = startDate;
        eventData.endDate = endDate;
        eventData.reservePrice = reservePrice;
        eventData.totalTips = 0;
        eventData.highestTipper = address(0);
        eventData.highestTip = 0;
        eventData.finalized = false;

        emit EventRegistered(eventId, creator, startDate, endDate, reservePrice);
    }

    /**
     * @dev Send a tip to an event
     */
    function sendTip(
        uint256 eventId,
        string memory message
    ) 
        external 
        payable 
        eventExists(eventId) 
        eventInProgress(eventId) 
        nonReentrant 
        whenNotPaused 
    {
        if (msg.value == 0) revert InvalidTipAmount();
        if (eventTipping[eventId].finalized) revert EventAlreadyFinalized();

        EventTippingData storage eventData = eventTipping[eventId];

        // Record tip
        uint256 tipId = eventTips[eventId].length;
        eventTips[eventId].push(TipData({
            tipper: msg.sender,
            amount: msg.value,
            timestamp: block.timestamp,
            message: message
        }));

        // Update tipper's data
        if (eventData.tips[msg.sender] == 0) {
            eventData.tippers.push(msg.sender);
        }
        eventData.tips[msg.sender] += msg.value;
        eventData.tipCounts[msg.sender]++;
        tipperTips[eventId][msg.sender].push(tipId);

        // Update event totals
        eventData.totalTips += msg.value;

        // Check if this is the new highest tipper
        if (eventData.tips[msg.sender] > eventData.highestTip) {
            address previousHighest = eventData.highestTipper;
            eventData.highestTipper = msg.sender;
            eventData.highestTip = eventData.tips[msg.sender];
            
            emit NewHighestTipper(eventId, previousHighest, msg.sender, eventData.tips[msg.sender]);
        }

        emit TipReceived(eventId, msg.sender, msg.value, message, tipId);
    }

    /**
     * @dev Finalize an event and distribute tips
     */
    function finalizeEvent(uint256 eventId) 
        external 
        eventExists(eventId) 
        onlyEventCreator(eventId) 
        nonReentrant 
        returns (address highestTipper, uint256 totalTips, bool reservePriceMet) 
    {
        EventTippingData storage eventData = eventTipping[eventId];
        
        if (eventData.finalized) revert EventAlreadyFinalized();
        if (block.timestamp < eventData.endDate) revert EventNotEnded();

        eventData.finalized = true;

        totalTips = eventData.totalTips;
        reservePriceMet = totalTips >= eventData.reservePrice;
        highestTipper = reservePriceMet ? eventData.highestTipper : eventData.creator;

        emit EventFinalized(eventId, highestTipper, totalTips, reservePriceMet);
        
        return (highestTipper, totalTips, reservePriceMet);
    }
    
    /**
     * @dev Get event tipping data
     */
    function getEventTippingData(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (
            address creator,
            uint256 startDate,
            uint256 endDate,
            uint256 reservePrice,
            uint256 totalTips,
            address highestTipper,
            uint256 highestTip,
            bool active,
            bool finalized
        ) 
    {
        EventTippingData storage eventData = eventTipping[eventId];
        
        // Calculate if event is currently active (within time bounds and not finalized)
        uint256 currentTime = block.timestamp;
        bool isActive = currentTime >= eventData.startDate && 
                       currentTime <= eventData.endDate && 
                       !eventData.finalized;
        
        return (
            eventData.creator,
            eventData.startDate,
            eventData.endDate,
            eventData.reservePrice,
            eventData.totalTips,
            eventData.highestTipper,
            eventData.highestTip,
            isActive,
            eventData.finalized
        );
    }

    /**
     * @dev Get tipper's total tips for an event
     */
    function getTipperTotal(uint256 eventId, address tipper) 
        external 
        view 
        eventExists(eventId) 
        returns (uint256 totalTips, uint256 tipCount) 
    {
        EventTippingData storage eventData = eventTipping[eventId];
        return (eventData.tips[tipper], eventData.tipCounts[tipper]);
    }

    /**
     * @dev Get all tips for an event
     */
    function getEventTips(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (TipData[] memory) 
    {
        return eventTips[eventId];
    }

    /**
     * @dev Get tips for a specific tipper in an event
     */
    function getTipperTips(uint256 eventId, address tipper) 
        external 
        view 
        eventExists(eventId) 
        returns (TipData[] memory) 
    {
        uint256[] memory tipIds = tipperTips[eventId][tipper];
        TipData[] memory tips = new TipData[](tipIds.length);
        
        for (uint256 i = 0; i < tipIds.length; i++) {
            tips[i] = eventTips[eventId][tipIds[i]];
        }
        
        return tips;
    }

    /**
     * @dev Get all tippers for an event
     */
    function getEventTippers(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (address[] memory) 
    {
        return eventTipping[eventId].tippers;
    }

    /**
     * @dev Check if event is currently in tippable period
     */
    function isEventTippable(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (bool) 
    {
        EventTippingData storage eventData = eventTipping[eventId];
        
        if (eventData.finalized) return false;
        
        uint256 currentTime = block.timestamp;
        return currentTime >= eventData.startDate && currentTime <= eventData.endDate;
    }

    /**
     * @dev Update treasury address (only owner)
     */
    function updateTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidInput();
        treasury = _treasury;
    }

    /**
     * @dev Update event factory address (only owner)
     */
    function updateEventFactory(address _eventFactoryAddress) external onlyOwner {
        if (_eventFactoryAddress == address(0)) revert InvalidInput();
        eventFactoryAddress = _eventFactoryAddress;
    }

    /**
     * @dev Update distributor contract address (only owner)
     */
    function updateDistributorContract(address _distributorContract) external onlyOwner {
        distributorContract = _distributorContract;
    }

    /**
     * @dev Update contracts (only owner)
     */
    function updateContracts(
        address _eventFactoryAddress,
        address _distributorContract
    ) external onlyOwner {
        if (_eventFactoryAddress != address(0)) eventFactoryAddress = _eventFactoryAddress;
        if (_distributorContract != address(0)) distributorContract = _distributorContract;
    }

    /**
     * @dev Emergency pause (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency withdrawal (only owner)
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = treasury.call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}

    // Receive function to accept SEI
    receive() external payable {}
}
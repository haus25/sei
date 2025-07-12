// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IEventFactory.sol";

/**
 * @title Curation
 * @dev Standalone curation contract for managing curation across all events
 * References EventFactory to validate events and manage curation services
 */
contract Curation is 
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    struct CurationData {
        address curator;
        uint256 curatorFee;      // Percentage fee (1-10)
        uint256 scope;           // Curation scope (1-3)
        string description;
        bool active;
        uint256 totalEarnings;
        uint256 totalWithdrawn;
        uint256 startDate;       // When curation starts
        uint256 endDate;         // When curation ends
    }

    // Event ID => CurationData
    mapping(uint256 => CurationData) public eventCuration;
    // Curator => Event IDs
    mapping(address => uint256[]) public curatorEvents;
    // Event ID => Curator => pending balance
    mapping(uint256 => mapping(address => uint256)) public pendingBalances;
    
    address public eventFactoryAddress;
    address public distributorContract;
    
    // Constants for gas optimization
    uint256 private constant MAX_CURATOR_FEE = 10; // 10% max
    uint256 private constant MAX_SCOPE = 3;
    
    // Custom errors for bytecode optimization
    error InvalidCuratorAddress();
    error InvalidCuratorFee();
    error InvalidScope();
    error CurationAlreadyActive();
    error CurationNotActive();
    error EventNotRegistered();
    error OnlyEventFactory();
    error OnlyEventCreator();
    error OnlyCurator();
    error NoBalanceToWithdraw();
    error TransferFailed();
    error InvalidInput();
    error CurationExpired();
    
    // Events
    event CurationActivated(
        uint256 indexed eventId,
        address indexed curator,
        uint256 fee,
        uint256 scope,
        uint256 startDate,
        uint256 endDate
    );
    
    event CurationDeactivated(uint256 indexed eventId, address indexed curator);
    event FundsReceived(uint256 indexed eventId, address indexed curator, uint256 amount);
    event FundsWithdrawn(uint256 indexed eventId, address indexed curator, uint256 amount);
    event CurationUpdated(uint256 indexed eventId, uint256 newFee, uint256 newScope);

    modifier onlyEventFactory() {
        if (msg.sender != eventFactoryAddress) revert OnlyEventFactory();
        _;
    }

    modifier onlyEventCreator(uint256 eventId) {
        // Get event creator from EventFactory
        IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
        address creator = eventData.creator;
        if (msg.sender != creator) revert OnlyEventCreator();
        _;
    }

    modifier onlyCurator(uint256 eventId) {
        if (msg.sender != eventCuration[eventId].curator) revert OnlyCurator();
        _;
    }

    modifier curationActive(uint256 eventId) {
        if (!eventCuration[eventId].active) revert CurationNotActive();
        _;
    }

    modifier curationNotExpired(uint256 eventId) {
        if (block.timestamp > eventCuration[eventId].endDate) revert CurationExpired();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _eventFactoryAddress,
        address _distributorContract
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (_eventFactoryAddress == address(0)) revert InvalidInput();
        
        eventFactoryAddress = _eventFactoryAddress;
        distributorContract = _distributorContract;
    }

    /**
     * @dev Initialize curation service for an event
     */
    function initializeCuration(
        uint256 eventId,
        address _curator,
        uint256 _curatorFee,
        uint256 _scope,
        string memory _description,
        uint256 _startDate,
        uint256 _endDate
    ) external onlyEventCreator(eventId) {
        if (_curator == address(0)) revert InvalidCuratorAddress();
        if (_curatorFee < 1 || _curatorFee > MAX_CURATOR_FEE) revert InvalidCuratorFee();
        if (_scope < 1 || _scope > MAX_SCOPE) revert InvalidScope();
        if (eventCuration[eventId].active) revert CurationAlreadyActive();
        if (_startDate >= _endDate) revert InvalidInput();
        if (_startDate <= block.timestamp) revert InvalidInput();

        eventCuration[eventId] = CurationData({
            curator: _curator,
            curatorFee: _curatorFee,
            scope: _scope,
            description: _description,
            active: true,
            totalEarnings: 0,
            totalWithdrawn: 0,
            startDate: _startDate,
            endDate: _endDate
        });

        // Add event to curator's list
        curatorEvents[_curator].push(eventId);

        emit CurationActivated(eventId, _curator, _curatorFee, _scope, _startDate, _endDate);
    }

    /**
     * @dev Update curation parameters (only before start date)
     */
    function updateCuration(
        uint256 eventId,
        uint256 _curatorFee,
        uint256 _scope
    ) external onlyEventCreator(eventId) curationActive(eventId) {
        if (block.timestamp >= eventCuration[eventId].startDate) revert InvalidInput();
        if (_curatorFee < 1 || _curatorFee > MAX_CURATOR_FEE) revert InvalidCuratorFee();
        if (_scope < 1 || _scope > MAX_SCOPE) revert InvalidScope();

        eventCuration[eventId].curatorFee = _curatorFee;
        eventCuration[eventId].scope = _scope;

        emit CurationUpdated(eventId, _curatorFee, _scope);
    }

    /**
     * @dev Deactivate curation service
     */
    function deactivateCuration(uint256 eventId) external onlyEventCreator(eventId) {
        if (!eventCuration[eventId].active) revert CurationNotActive();
        
        eventCuration[eventId].active = false;
        emit CurationDeactivated(eventId, eventCuration[eventId].curator);
    }

    /**
     * @dev Receive funds from distribution (called by Distributor)
     */
    function receiveFunds(uint256 eventId, address curator) external payable {
        if (msg.sender != distributorContract) revert OnlyEventFactory();
        if (!eventCuration[eventId].active) revert CurationNotActive();
        if (msg.value == 0) revert InvalidInput();

        eventCuration[eventId].totalEarnings += msg.value;
        pendingBalances[eventId][curator] += msg.value;

        emit FundsReceived(eventId, curator, msg.value);
    }

    /**
     * @dev Withdraw pending balance for a specific event
     */
    function withdrawBalance(uint256 eventId) external nonReentrant onlyCurator(eventId) {
        uint256 amount = pendingBalances[eventId][msg.sender];
        if (amount == 0) revert NoBalanceToWithdraw();

        pendingBalances[eventId][msg.sender] = 0;
        eventCuration[eventId].totalWithdrawn += amount;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FundsWithdrawn(eventId, msg.sender, amount);
    }

    /**
     * @dev Withdraw all pending balances for curator
     */
    function withdrawAllBalances() external nonReentrant {
        uint256[] memory events = curatorEvents[msg.sender];
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < events.length; i++) {
            uint256 eventId = events[i];
            uint256 amount = pendingBalances[eventId][msg.sender];
            
            if (amount > 0) {
                pendingBalances[eventId][msg.sender] = 0;
                eventCuration[eventId].totalWithdrawn += amount;
                totalAmount += amount;
                
                emit FundsWithdrawn(eventId, msg.sender, amount);
            }
        }

        if (totalAmount == 0) revert NoBalanceToWithdraw();

        (bool success, ) = msg.sender.call{value: totalAmount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @dev Get curation status for an event
     */
    function getCurationStatus(uint256 eventId) external view returns (bool active, bool expired) {
        CurationData storage curation = eventCuration[eventId];
        active = curation.active;
        expired = block.timestamp > curation.endDate;
        return (active, expired);
    }

    /**
     * @dev Get curator address for an event
     */
    function getCurator(uint256 eventId) external view returns (address) {
        return eventCuration[eventId].curator;
    }

    /**
     * @dev Get curator fee for an event
     */
    function getCuratorFee(uint256 eventId) external view returns (uint256) {
        return eventCuration[eventId].curatorFee;
    }

    /**
     * @dev Get curation scope for an event
     */
    function getCurationScope(uint256 eventId) external view returns (uint256) {
        return eventCuration[eventId].scope;
    }

    /**
     * @dev Get complete curation data for an event
     */
    function getCurationData(uint256 eventId) external view returns (
        address curator,
        uint256 curatorFee,
        uint256 scope,
        string memory description,
        bool active,
        uint256 totalEarnings,
        uint256 totalWithdrawn,
        uint256 startDate,
        uint256 endDate
    ) {
        CurationData storage curation = eventCuration[eventId];
        return (
            curation.curator,
            curation.curatorFee,
            curation.scope,
            curation.description,
            curation.active,
            curation.totalEarnings,
            curation.totalWithdrawn,
            curation.startDate,
            curation.endDate
        );
    }

    /**
     * @dev Get pending balance for curator in specific event
     */
    function getPendingBalance(uint256 eventId, address curator) external view returns (uint256) {
        return pendingBalances[eventId][curator];
    }

    /**
     * @dev Get total pending balance for curator across all events
     */
    function getTotalPendingBalance(address curator) external view returns (uint256) {
        uint256[] memory events = curatorEvents[curator];
        uint256 totalBalance = 0;

        for (uint256 i = 0; i < events.length; i++) {
            totalBalance += pendingBalances[events[i]][curator];
        }

        return totalBalance;
    }

    /**
     * @dev Get events curated by a specific curator
     */
    function getCuratorEvents(address curator) external view returns (uint256[] memory) {
        return curatorEvents[curator];
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
     * @dev Get contract balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}

    // Receive function to accept ETH
    receive() external payable {}
}

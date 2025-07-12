// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IEventFactory.sol";

/**
 * @title EventStation
 * @dev Standalone event station contract for managing infrastructure services across all events
 * References EventFactory to validate events and manage infrastructure operations
 */
contract EventStation is 
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    struct StationData {
        address operator;
        bool active;
        uint256 totalFundsReceived;
        uint256 totalFundsWithdrawn;
        uint256 operatorFee;  // Percentage fee (1-20)
        string description;
        uint256 startDate;   // When station service starts
        uint256 endDate;     // When station service ends
    }

    // Event ID => StationData
    mapping(uint256 => StationData) public eventStations;
    // Operator => Event IDs
    mapping(address => uint256[]) public operatorEvents;
    // Event ID => Operator => pending balance
    mapping(uint256 => mapping(address => uint256)) public pendingBalances;
    
    address public eventFactoryAddress;
    address public distributorContract;
    
    // Constants for gas optimization
    uint256 private constant MAX_OPERATOR_FEE = 20; // 20% max
    
    // Custom errors for bytecode optimization
    error InvalidOperatorAddress();
    error InvalidOperatorFee();
    error StationAlreadyActive();
    error StationNotActive();
    error EventNotRegistered();
    error OnlyEventFactory();
    error OnlyEventCreator();
    error OnlyOperator();
    error NoBalanceToWithdraw();
    error TransferFailed();
    error InvalidInput();
    error StationExpired();
    
    // Events
    event StationActivated(
        uint256 indexed eventId,
        address indexed operator,
        uint256 fee,
        uint256 startDate,
        uint256 endDate
    );
    
    event StationDeactivated(uint256 indexed eventId, address indexed operator);
    event FundsReceived(uint256 indexed eventId, address indexed operator, uint256 amount);
    event FundsWithdrawn(uint256 indexed eventId, address indexed operator, uint256 amount);
    event StationUpdated(uint256 indexed eventId, uint256 newFee);

    modifier onlyEventFactory() {
        if (msg.sender != eventFactoryAddress) revert OnlyEventFactory();
        _;
    }

    modifier onlyEventCreator(uint256 eventId) {
        // Get event creator from EventFactory
        IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
        if (msg.sender != eventData.creator) revert OnlyEventCreator();
        _;
    }

    modifier onlyOperator(uint256 eventId) {
        if (msg.sender != eventStations[eventId].operator) revert OnlyOperator();
        _;
    }

    modifier stationActive(uint256 eventId) {
        if (!eventStations[eventId].active) revert StationNotActive();
        _;
    }

    modifier stationNotExpired(uint256 eventId) {
        if (block.timestamp > eventStations[eventId].endDate) revert StationExpired();
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
     * @dev Initialize station service for an event
     */
    function initializeStation(
        uint256 eventId,
        address _operator,
        uint256 _operatorFee,
        string memory _description,
        uint256 _startDate,
        uint256 _endDate
    ) external onlyEventCreator(eventId) {
        if (_operator == address(0)) revert InvalidOperatorAddress();
        if (_operatorFee < 1 || _operatorFee > MAX_OPERATOR_FEE) revert InvalidOperatorFee();
        if (eventStations[eventId].active) revert StationAlreadyActive();
        if (_startDate >= _endDate) revert InvalidInput();
        if (_startDate <= block.timestamp) revert InvalidInput();

        eventStations[eventId] = StationData({
            operator: _operator,
            active: true,
            totalFundsReceived: 0,
            totalFundsWithdrawn: 0,
            operatorFee: _operatorFee,
            description: _description,
            startDate: _startDate,
            endDate: _endDate
        });

        // Add event to operator's list
        operatorEvents[_operator].push(eventId);

        emit StationActivated(eventId, _operator, _operatorFee, _startDate, _endDate);
    }

    /**
     * @dev Update station parameters (only before start date)
     */
    function updateStation(
        uint256 eventId,
        uint256 _operatorFee
    ) external onlyEventCreator(eventId) stationActive(eventId) {
        if (block.timestamp >= eventStations[eventId].startDate) revert InvalidInput();
        if (_operatorFee < 1 || _operatorFee > MAX_OPERATOR_FEE) revert InvalidOperatorFee();

        eventStations[eventId].operatorFee = _operatorFee;

        emit StationUpdated(eventId, _operatorFee);
    }

    /**
     * @dev Deactivate station service
     */
    function deactivateStation(uint256 eventId) external onlyEventCreator(eventId) {
        if (!eventStations[eventId].active) revert StationNotActive();
        
        eventStations[eventId].active = false;
        emit StationDeactivated(eventId, eventStations[eventId].operator);
    }

    /**
     * @dev Receive funds from external sources (called by Distributor or direct payments)
     */
    function receiveFunds(uint256 eventId, address operator) external payable {
        if (!eventStations[eventId].active) revert StationNotActive();
        if (msg.value == 0) revert InvalidInput();

        eventStations[eventId].totalFundsReceived += msg.value;
        
        // Calculate operator fee
        uint256 operatorAmount = (msg.value * eventStations[eventId].operatorFee) / 100;
        uint256 remainingAmount = msg.value - operatorAmount;

        // Distribute funds
        if (operatorAmount > 0) {
            pendingBalances[eventId][operator] += operatorAmount;
        }
        if (remainingAmount > 0) {
            // Get event creator from EventFactory
            IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
            pendingBalances[eventId][eventData.creator] += remainingAmount;
        }

        emit FundsReceived(eventId, operator, msg.value);
    }

    /**
     * @dev Dedicated function to receive funds (for external calls)
     */
    function receiveFundsForEvent(uint256 eventId) external payable stationActive(eventId) {
        if (msg.value == 0) revert InvalidInput();

        address operator = eventStations[eventId].operator;
        eventStations[eventId].totalFundsReceived += msg.value;
        
        // Calculate operator fee
        uint256 operatorAmount = (msg.value * eventStations[eventId].operatorFee) / 100;
        uint256 remainingAmount = msg.value - operatorAmount;

        // Distribute funds
        if (operatorAmount > 0) {
            pendingBalances[eventId][operator] += operatorAmount;
        }
        if (remainingAmount > 0) {
            // Get event creator from EventFactory
            IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
            pendingBalances[eventId][eventData.creator] += remainingAmount;
        }

        emit FundsReceived(eventId, operator, msg.value);
    }

    /**
     * @dev Withdraw pending balance for a specific event
     */
    function withdrawBalance(uint256 eventId) external nonReentrant {
        uint256 amount = pendingBalances[eventId][msg.sender];
        if (amount == 0) revert NoBalanceToWithdraw();

        pendingBalances[eventId][msg.sender] = 0;
        eventStations[eventId].totalFundsWithdrawn += amount;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FundsWithdrawn(eventId, msg.sender, amount);
    }

    /**
     * @dev Withdraw all pending balances for operator
     */
    function withdrawAllBalances() external nonReentrant {
        uint256[] memory events = operatorEvents[msg.sender];
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < events.length; i++) {
            uint256 eventId = events[i];
            uint256 amount = pendingBalances[eventId][msg.sender];
            
            if (amount > 0) {
                pendingBalances[eventId][msg.sender] = 0;
                eventStations[eventId].totalFundsWithdrawn += amount;
                totalAmount += amount;
                
                emit FundsWithdrawn(eventId, msg.sender, amount);
            }
        }

        if (totalAmount == 0) revert NoBalanceToWithdraw();

        (bool success, ) = msg.sender.call{value: totalAmount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @dev Get station status for an event
     */
    function getStationStatus(uint256 eventId) external view returns (bool active, bool expired) {
        StationData storage station = eventStations[eventId];
        active = station.active;
        expired = block.timestamp > station.endDate;
        return (active, expired);
    }

    /**
     * @dev Get operator address for an event
     */
    function getOperator(uint256 eventId) external view returns (address) {
        return eventStations[eventId].operator;
    }

    /**
     * @dev Get operator fee for an event
     */
    function getOperatorFee(uint256 eventId) external view returns (uint256) {
        return eventStations[eventId].operatorFee;
    }

    /**
     * @dev Get complete station data for an event
     */
    function getStationData(uint256 eventId) external view returns (
        address operator,
        bool active,
        uint256 totalFundsReceived,
        uint256 totalFundsWithdrawn,
        uint256 operatorFee,
        string memory description,
        uint256 startDate,
        uint256 endDate
    ) {
        StationData storage station = eventStations[eventId];
        return (
            station.operator,
            station.active,
            station.totalFundsReceived,
            station.totalFundsWithdrawn,
            station.operatorFee,
            station.description,
            station.startDate,
            station.endDate
        );
    }

    /**
     * @dev Get pending balance for address in specific event
     */
    function getPendingBalance(uint256 eventId, address account) external view returns (uint256) {
        return pendingBalances[eventId][account];
    }

    /**
     * @dev Get total pending balance for operator across all events
     */
    function getTotalPendingBalance(address operator) external view returns (uint256) {
        uint256[] memory events = operatorEvents[operator];
        uint256 totalBalance = 0;

        for (uint256 i = 0; i < events.length; i++) {
            totalBalance += pendingBalances[events[i]][operator];
        }

        return totalBalance;
    }

    /**
     * @dev Get events operated by a specific operator
     */
    function getOperatorEvents(address operator) external view returns (uint256[] memory) {
        return operatorEvents[operator];
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
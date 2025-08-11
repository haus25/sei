// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IEventFactory.sol";

/**
 * @title Curation
 * @dev Per-event curation contract for managing curation services
 * References EventFactory to validate events and manage curation services
 */
contract Curation is 
    Ownable,
    ReentrancyGuard
{
    // Per-event curation data - no mapping needed since this is a per-event contract
    uint256 public eventId;
    address public curator;
    uint256 public curatorFee;      // Percentage fee (1-10)
    uint256 public scope;           // Curation scope (1-3)
    string public description;
    bool public active;
    uint256 public totalEarnings;
    uint256 public totalWithdrawn;
    uint256 public startDate;       // When curation starts
    uint256 public endDate;         // When curation ends
    uint256 public pendingBalance;  // Pending balance for the curator
    
    address public eventFactoryAddress;
    address public distributorContract;
    address public eventCreator;
    
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

    modifier onlyEventCreator() {
        if (msg.sender != eventCreator) revert OnlyEventCreator();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    modifier curationActive() {
        if (!active) revert CurationNotActive();
        _;
    }

    modifier curationNotExpired() {
        if (block.timestamp > endDate) revert CurationExpired();
        _;
    }

    /**
     * @dev Constructor for per-event Curation instance
     */
    constructor(
        uint256 _eventId,
        address _eventFactoryAddress,
        address _eventCreator,
        address _curator,
        uint256 _curatorFee,
        uint256 _scope,
        string memory _description,
        address _distributorContract
    ) Ownable(_eventCreator) {
        if (_eventFactoryAddress == address(0)) revert InvalidInput();
        if (_eventCreator == address(0)) revert InvalidInput();
        if (_curator == address(0)) revert InvalidCuratorAddress();
        if (_curatorFee < 1 || _curatorFee > MAX_CURATOR_FEE) revert InvalidCuratorFee();
        if (_scope < 1 || _scope > MAX_SCOPE) revert InvalidScope();
        
        eventId = _eventId;
        eventFactoryAddress = _eventFactoryAddress;
        eventCreator = _eventCreator;
        curator = _curator;
        curatorFee = _curatorFee;
        scope = _scope;
        description = _description;
        distributorContract = _distributorContract;
        active = true;
        totalEarnings = 0;
        totalWithdrawn = 0;
        pendingBalance = 0;
        
        // Set default dates - can be updated later
        startDate = block.timestamp;
        endDate = block.timestamp + 365 days; // Default 1 year
    }

    /**
     * @dev Update curation dates (only by event creator before start)
     */
    function updateDates(
        uint256 _startDate,
        uint256 _endDate
    ) external onlyEventCreator {
        if (block.timestamp >= startDate) revert InvalidInput();
        if (_startDate >= _endDate) revert InvalidInput();
        if (_startDate <= block.timestamp) revert InvalidInput();

        startDate = _startDate;
        endDate = _endDate;

        emit CurationActivated(eventId, curator, curatorFee, scope, _startDate, _endDate);
    }

    /**
     * @dev Update curation parameters (only before start date)
     */
    function updateCuration(
        uint256 _curatorFee,
        uint256 _scope
    ) external onlyEventCreator curationActive {
        if (block.timestamp >= startDate) revert InvalidInput();
        if (_curatorFee < 1 || _curatorFee > MAX_CURATOR_FEE) revert InvalidCuratorFee();
        if (_scope < 1 || _scope > MAX_SCOPE) revert InvalidScope();

        curatorFee = _curatorFee;
        scope = _scope;

        emit CurationUpdated(eventId, _curatorFee, _scope);
    }

    /**
     * @dev Deactivate curation service
     */
    function deactivateCuration() external onlyEventCreator {
        if (!active) revert CurationNotActive();
        
        active = false;
        emit CurationDeactivated(eventId, curator);
    }

    /**
     * @dev Receive funds from distribution (called by Distributor)
     */
    function receiveFunds() external payable {
        if (msg.sender != distributorContract) revert OnlyEventFactory();
        if (!active) revert CurationNotActive();
        if (msg.value == 0) revert InvalidInput();

        totalEarnings += msg.value;
        pendingBalance += msg.value;

        emit FundsReceived(eventId, curator, msg.value);
    }

    /**
     * @dev Withdraw pending balance
     */
    function withdrawBalance() external nonReentrant onlyCurator {
        uint256 amount = pendingBalance;
        if (amount == 0) revert NoBalanceToWithdraw();

        pendingBalance = 0;
        totalWithdrawn += amount;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FundsWithdrawn(eventId, msg.sender, amount);
    }



    /**
     * @dev Get curation status
     */
    function getCurationStatus() external view returns (bool, bool) {
        bool expired = block.timestamp > endDate;
        return (active, expired);
    }

    /**
     * @dev Get curator address
     */
    function getCurator() external view returns (address) {
        return curator;
    }

    /**
     * @dev Helper for Distributor to compute enforced fee by scope
     */
    function getScopeFee(uint256 _scope) external pure returns (uint256 feeBasisPoints) {
        if (_scope == 1) return 300;   // 3%
        if (_scope == 2) return 700;   // 7%
        if (_scope == 3) return 1000;  // 10%
        return 0;
    }

    /**
     * @dev Get curator fee
     */
    function getCuratorFee() external view returns (uint256) {
        return curatorFee;
    }

    /**
     * @dev Get curation scope
     */
    function getCurationScope() external view returns (uint256) {
        return scope;
    }

    /**
     * @dev Get complete curation data
     */
    function getCurationData() external view returns (
        address,
        uint256,
        uint256,
        string memory,
        bool,
        uint256,
        uint256,
        uint256,
        uint256
    ) {
        return (
            curator,
            curatorFee,
            scope,
            description,
            active,
            totalEarnings,
            totalWithdrawn,
            startDate,
            endDate
        );
    }

    /**
     * @dev Get pending balance for curator
     */
    function getPendingBalance() external view returns (uint256) {
        return pendingBalance;
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

    // Receive function to accept ETH
    receive() external payable {}
}

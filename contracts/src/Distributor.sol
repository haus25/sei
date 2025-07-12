// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/IEventFactory.sol";

/**
 * @title Distributor
 * @dev Standalone contract for managing tip distribution and revenue sharing across all events
 * Fee structure: 80% creator, 20% treasury (max), curation 0-10% (comes from treasury portion)
 * Curation Scopes: Scope 1 (<3%), Scope 2 (3-6%), Scope 3 (6%+)
 * Only whitelisted addresses can curate through proxy
 */
contract Distributor is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    enum CurationScope {
        NONE,       // 0% - No curation
        SCOPE_1,    // <3% - Basic curation
        SCOPE_2,    // 3-6% - Advanced curation  
        SCOPE_3     // 6%+ - Premium curation
    }

    struct EventDistributionConfig {
        uint256 creatorShare;   // Always 8000 (80%)
        uint256 treasuryShare;  // Always 2000 (20%) - base treasury share
        uint256 curationFee;    // 0-1000 (0-10%) - comes from treasury portion
        CurationScope curationScope;
        address curator;        // Whitelisted curator address
        bool curationEnabled;
    }

    struct DistributionEvent {
        uint256 eventId;
        address recipient;
        uint256 amount;
        uint256 timestamp;
        string distributionType; // "creator", "treasury", "curation"
    }

    // State variables
    mapping(uint256 => EventDistributionConfig) public eventConfigs;
    mapping(uint256 => DistributionEvent[]) public distributionHistory;
    mapping(uint256 => uint256) public eventTotalDistributed;
    mapping(address => bool) public whitelistedCurators;
    mapping(address => CurationScope) public curatorMaxScope;
    
    address public eventFactoryAddress;
    address public liveTippingContract;
    address public curationContract;
    address public eventStationContract;
    address public treasury;
    
    uint256 public totalDistributed;
    uint256 public totalEvents;

    // Constants for gas optimization
    uint256 private constant BASIS_POINTS = 10000; // 100%
    uint256 private constant CREATOR_SHARE = 8000; // 80%
    uint256 private constant TREASURY_BASE_SHARE = 2000; // 20%
    uint256 private constant MAX_CURATION_FEE = 1000; // 10%
    uint256 private constant SCOPE_1_MAX = 299; // <3%
    uint256 private constant SCOPE_2_MIN = 300; // 3%
    uint256 private constant SCOPE_2_MAX = 599; // <6%
    uint256 private constant SCOPE_3_MIN = 600; // 6%+

    // Custom errors for bytecode optimization
    error EventNotRegistered();
    error InvalidCurationFee();
    error CuratorNotWhitelisted();
    error InvalidCurationScope();
    error CurationNotEnabled();
    error OnlyEventFactory();
    error OnlyEventOwner();
    error OnlyWhitelistedCurator();
    error TransferFailed();
    error InvalidAddress();
    error InvalidInput();

    // Events
    event EventRegistered(
        uint256 indexed eventId,
        address indexed creator,
        uint256 creatorShare,
        uint256 treasuryShare
    );
    
    event TipDistributed(
        uint256 indexed eventId,
        address indexed recipient,
        uint256 amount,
        string distributionType
    );
    
    event CurationEnabled(
        uint256 indexed eventId,
        address indexed curator,
        uint256 curationFee,
        CurationScope scope
    );
    
    event CurationDisabled(uint256 indexed eventId);
    
    event CuratorWhitelisted(address indexed curator, CurationScope maxScope);
    event CuratorRemoved(address indexed curator);

    modifier onlyEventFactory() {
        if (msg.sender != eventFactoryAddress) revert OnlyEventFactory();
        _;
    }

    modifier onlyEventOwner(uint256 eventId) {
        IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
        if (msg.sender != eventData.creator) revert OnlyEventOwner();
        _;
    }

    modifier onlyWhitelistedCurator() {
        if (!whitelistedCurators[msg.sender]) revert OnlyWhitelistedCurator();
        _;
    }

    modifier eventExists(uint256 eventId) {
        IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
        if (eventData.creator == address(0)) revert EventNotRegistered();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _eventFactoryAddress,
        address _liveTippingContract,
        address _curationContract,
        address _eventStationContract,
        address _treasury
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_eventFactoryAddress == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        eventFactoryAddress = _eventFactoryAddress;
        liveTippingContract = _liveTippingContract;
        curationContract = _curationContract;
        eventStationContract = _eventStationContract;
        treasury = _treasury;
    }

    /**
     * @dev Register a new event for distribution (called by EventFactory)
     * Sets default 80% creator, 20% treasury, no curation
     */
    function registerEvent(
        uint256 eventId,
        address creator
    ) external onlyEventFactory {
        if (eventConfigs[eventId].creatorShare > 0) revert InvalidInput();

        eventConfigs[eventId] = EventDistributionConfig({
            creatorShare: CREATOR_SHARE,
            treasuryShare: TREASURY_BASE_SHARE,
            curationFee: 0,
            curationScope: CurationScope.NONE,
            curator: address(0),
            curationEnabled: false
        });

        totalEvents++;

        emit EventRegistered(eventId, creator, CREATOR_SHARE, TREASURY_BASE_SHARE);
    }

    /**
     * @dev Enable curation for an event by whitelisted curator
     * @param eventId The event ID
     * @param curationFee Fee in basis points (0-1000 = 0-10%)
     * @param scope Curation scope (1, 2, or 3)
     */
    function enableCuration(
        uint256 eventId,
        uint256 curationFee,
        CurationScope scope
    ) external eventExists(eventId) onlyWhitelistedCurator {
        if (curationFee > MAX_CURATION_FEE) revert InvalidCurationFee();
        if (scope == CurationScope.NONE) revert InvalidCurationScope();
        
        // Validate curation fee matches scope
        if (scope == CurationScope.SCOPE_1 && curationFee > SCOPE_1_MAX) revert InvalidCurationScope();
        if (scope == CurationScope.SCOPE_2 && (curationFee < SCOPE_2_MIN || curationFee > SCOPE_2_MAX)) revert InvalidCurationScope();
        if (scope == CurationScope.SCOPE_3 && curationFee < SCOPE_3_MIN) revert InvalidCurationScope();
        
        // Check if curator is allowed to use this scope
        if (scope > curatorMaxScope[msg.sender]) revert InvalidCurationScope();
        
        EventDistributionConfig storage config = eventConfigs[eventId];
        config.curationFee = curationFee;
        config.curationScope = scope;
        config.curator = msg.sender;
        config.curationEnabled = true;
        
        emit CurationEnabled(eventId, msg.sender, curationFee, scope);
    }

    /**
     * @dev Disable curation for an event
     */
    function disableCuration(uint256 eventId) 
        external 
        eventExists(eventId) 
        onlyEventOwner(eventId) 
    {
        EventDistributionConfig storage config = eventConfigs[eventId];
        config.curationFee = 0;
        config.curationScope = CurationScope.NONE;
        config.curator = address(0);
        config.curationEnabled = false;
        
        emit CurationDisabled(eventId);
    }

    /**
     * @dev Distribute tips for an event
     * 80% to creator, remaining to treasury (minus curation fee if enabled)
     */
    function distributeTips(uint256 eventId) 
        external 
        payable 
        eventExists(eventId) 
        nonReentrant 
        whenNotPaused 
    {
        if (msg.value == 0) revert InvalidInput();
        
        EventDistributionConfig storage config = eventConfigs[eventId];
        uint256 amountToDistribute = msg.value;
        
        // Get event data
        IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
        address eventOwner = eventData.creator;
        
        // Calculate distribution amounts
        uint256 creatorAmount = (amountToDistribute * CREATOR_SHARE) / BASIS_POINTS;
        uint256 treasuryAmount = amountToDistribute - creatorAmount;
        uint256 curationAmount = 0;
        
        // Handle curation if enabled
        if (config.curationEnabled && config.curationFee > 0) {
            curationAmount = (amountToDistribute * config.curationFee) / BASIS_POINTS;
            treasuryAmount -= curationAmount;
        }
        
        // Distribute to creator/current owner
        if (creatorAmount > 0) {
            _distributeFunds(eventId, eventOwner, creatorAmount, "creator");
        }
        
        // Distribute to treasury
        if (treasuryAmount > 0) {
            _distributeFunds(eventId, treasury, treasuryAmount, "treasury");
        }
        
        // Distribute to curator if enabled
        if (curationAmount > 0 && config.curationEnabled) {
            _distributeFunds(eventId, config.curator, curationAmount, "curation");
        }
        
        eventTotalDistributed[eventId] += amountToDistribute;
        totalDistributed += amountToDistribute;
    }

    /**
     * @dev Internal function to distribute funds directly
     */
    function _distributeFunds(
        uint256 eventId,
        address recipient,
        uint256 amount,
        string memory distributionType
    ) internal {
        if (recipient == address(0) || amount == 0) return;
        
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        // Record distribution event
        distributionHistory[eventId].push(DistributionEvent({
            eventId: eventId,
            recipient: recipient,
            amount: amount,
            timestamp: block.timestamp,
            distributionType: distributionType
        }));
        
        emit TipDistributed(eventId, recipient, amount, distributionType);
    }

    /**
     * @dev Add curator to whitelist with maximum scope
     * @param curator Address to whitelist
     * @param maxScope Maximum curation scope this curator can use
     */
    function whitelistCurator(address curator, CurationScope maxScope) external onlyOwner {
        if (curator == address(0)) revert InvalidAddress();
        if (maxScope == CurationScope.NONE) revert InvalidCurationScope();
        
        whitelistedCurators[curator] = true;
        curatorMaxScope[curator] = maxScope;
        
        emit CuratorWhitelisted(curator, maxScope);
    }

    /**
     * @dev Remove curator from whitelist
     */
    function removeCurator(address curator) external onlyOwner {
        whitelistedCurators[curator] = false;
        curatorMaxScope[curator] = CurationScope.NONE;
        
        emit CuratorRemoved(curator);
    }

    /**
     * @dev Get event distribution configuration
     */
    function getEventDistributionConfig(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (
            uint256 creatorShare,
            uint256 treasuryShare,
            uint256 curationFee,
            CurationScope curationScope,
            address curator,
            bool curationEnabled
        ) 
    {
        EventDistributionConfig storage config = eventConfigs[eventId];
        
        return (
            config.creatorShare,
            config.treasuryShare,
            config.curationFee,
            config.curationScope,
            config.curator,
            config.curationEnabled
        );
    }

    /**
     * @dev Get distribution history for an event
     */
    function getDistributionHistory(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (DistributionEvent[] memory) 
    {
        return distributionHistory[eventId];
    }

    /**
     * @dev Get total distributed amount for an event
     */
    function getEventTotalDistributed(uint256 eventId) 
        external 
        view 
        eventExists(eventId) 
        returns (uint256) 
    {
        return eventTotalDistributed[eventId];
    }

    /**
     * @dev Check if curator is whitelisted and their max scope
     */
    function getCuratorInfo(address curator) external view returns (bool isWhitelisted, CurationScope maxScope) {
        return (whitelistedCurators[curator], curatorMaxScope[curator]);
    }

    /**
     * @dev Get curation scope details
     */
    function getCurationScopeRanges() external pure returns (
        uint256 scope1Max,
        uint256 scope2Min,
        uint256 scope2Max,
        uint256 scope3Min,
        uint256 maxCurationFee
    ) {
        return (SCOPE_1_MAX, SCOPE_2_MIN, SCOPE_2_MAX, SCOPE_3_MIN, MAX_CURATION_FEE);
    }

    /**
     * @dev Update contract addresses (only owner)
     */
    function updateContracts(
        address _eventFactoryAddress,
        address _liveTippingContract,
        address _curationContract,
        address _eventStationContract
    ) external onlyOwner {
        if (_eventFactoryAddress != address(0)) eventFactoryAddress = _eventFactoryAddress;
        if (_liveTippingContract != address(0)) liveTippingContract = _liveTippingContract;
        if (_curationContract != address(0)) curationContract = _curationContract;
        if (_eventStationContract != address(0)) eventStationContract = _eventStationContract;
    }

    /**
     * @dev Update treasury address (only owner)
     */
    function updateTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    /**
     * @dev Pause contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Get contract balance
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Get total statistics
     */
    function getTotalStatistics() external view returns (
        uint256 totalEventsRegistered,
        uint256 totalAmountDistributed
    ) {
        return (totalEvents, totalDistributed);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}

    // Receive function to accept ETH
    receive() external payable {
        // Accept ETH for distribution
    }
}
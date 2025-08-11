// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/IEventFactory.sol";

/// @dev Minimal interface for per-event Curation contract integration
interface ICurationMinimal {
    function getCurator() external view returns (address);
    function getCurationScope() external view returns (uint256);
    function getCuratorFee() external view returns (uint256);
}

/**
 * @title Distributor
 * @dev Standalone contract for managing tip distribution and revenue sharing across all events
 * Fee structure: 85% creator (max), 15% treasury, curation 0-10% (comes from creator portion)
 * Curation Scopes: Scope 1 (3%), Scope 2 (7%), Scope 3 (10%)
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
        SCOPE_1,    // 3% - Planner
        SCOPE_2,    // 7% - Promoter
        SCOPE_3     // 10% - Producer
    }

    struct EventDistributionConfig {
        uint256 creatorShare;   // 8500 (85%) - base creator share
        uint256 treasuryShare;  // Always 2000 (15%)
        uint256 curationFee;    // 0-1000 (0-10%) - comes from creator portion
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
    uint256 private constant CREATOR_BASE_SHARE = 8500; // 85%
    uint256 private constant TREASURY_SHARE = 1500; // 15%
    uint256 private constant MAX_CURATION_FEE = 1000; // 10%
    uint256 private constant SCOPE_1 = 300;
    uint256 private constant SCOPE_2 = 700;
    uint256 private constant SCOPE_3 = 1000;

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
            creatorShare: CREATOR_BASE_SHARE,
            treasuryShare: TREASURY_SHARE,
            curationFee: 0,
            curationScope: CurationScope.NONE,
            curator: address(0),
            curationEnabled: false
        });

        totalEvents++;

        emit EventRegistered(eventId, creator, CREATOR_BASE_SHARE, TREASURY_SHARE);
    }

    /**
     * @dev Enable curation automatically when curation contract is deployed (called by EventFactory)
     * Gets curation details directly from the deployed curation contract
     */
    function enableCurationFromContract(
        uint256 eventId,
        address _curationContract
    ) external onlyEventFactory {
        if (_curationContract == address(0)) revert InvalidInput();
        
        // Get curation details from the deployed contract
        ICurationMinimal curation = ICurationMinimal(_curationContract);
        uint256 scope = curation.getCurationScope();
        uint256 fee = curation.getCuratorFee();
        address curator = curation.getCurator();
        
        // Validate scope and convert to enum
        CurationScope curationScope;
        if (scope == 1) curationScope = CurationScope.SCOPE_1;
        else if (scope == 2) curationScope = CurationScope.SCOPE_2;
        else if (scope == 3) curationScope = CurationScope.SCOPE_3;
        else revert InvalidCurationScope();
        
        // Update event configuration
        EventDistributionConfig storage config = eventConfigs[eventId];
        config.curationFee = fee;
        config.curationScope = curationScope;
        config.curator = curator;
        config.curationEnabled = true;
        
        emit CurationEnabled(eventId, curator, fee, curationScope);
    }

    /**
     * @dev Enable curation for an event by whitelisted curator or curation contract
     * @param eventId The event ID
     * @param curationFee Fee in basis points (0-1000 = 0-10%)
     * @param scope Curation scope (1, 2, or 3)
     */
    function enableCuration(
        uint256 eventId,
        uint256 curationFee,
        CurationScope scope
    ) external eventExists(eventId) {
        if (curationFee > MAX_CURATION_FEE) revert InvalidCurationFee();
        if (scope == CurationScope.NONE) revert InvalidCurationScope();
        
        // Validate curation fee matches scope
        if (scope == CurationScope.SCOPE_1 && curationFee > SCOPE_1) revert InvalidCurationScope();
        if (scope == CurationScope.SCOPE_2 && (curationFee < SCOPE_2 || curationFee > SCOPE_2)) revert InvalidCurationScope();
        if (scope == CurationScope.SCOPE_3 && curationFee < SCOPE_3) revert InvalidCurationScope();
        
        // Get event data to check if this is from the curation contract
        IEventFactory.EventData memory eventData = IEventFactory(eventFactoryAddress).getEvent(eventId);
        address eventCurationContract = eventData.curationAddress;
        
        // Check authorization: either whitelisted curator or the event's curation contract
        bool isAuthorized = false;
        if (eventCurationContract != address(0) && msg.sender == eventCurationContract) {
            // Called from curation contract - authorize
            isAuthorized = true;
        } else if (whitelistedCurators[msg.sender] && scope <= curatorMaxScope[msg.sender]) {
            // Called by whitelisted curator with proper scope
            isAuthorized = true;
        }
        
        if (!isAuthorized) revert OnlyWhitelistedCurator();
        
        EventDistributionConfig storage config = eventConfigs[eventId];
        // If invoked by the event's Curation contract, enforce platform fee mapping by scope
        if (eventCurationContract != address(0) && msg.sender == eventCurationContract) {
            uint256 enforcedFee = curationFee;
            if (scope == CurationScope.SCOPE_1) {
                enforcedFee = 300; // 3%
            } else if (scope == CurationScope.SCOPE_2) {
                enforcedFee = 700; // 7%
            } else if (scope == CurationScope.SCOPE_3) {
                enforcedFee = 1000; // 10%
            }
            config.curationFee = enforcedFee;
        } else {
            // External whitelisted curators must supply a valid fee matching scope validation above
            config.curationFee = curationFee;
        }
        config.curationScope = scope;
        
        // Set curator: if called from curation contract, get curator from that contract
        if (eventCurationContract != address(0) && msg.sender == eventCurationContract) {
            // Resolve actual curator address from per-event Curation contract
            address curatorAddr = ICurationMinimal(eventCurationContract).getCurator();
            config.curator = curatorAddr;
        } else {
            config.curator = msg.sender;
        }
        
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
        uint256 creatorAmount = (amountToDistribute * CREATOR_BASE_SHARE) / BASIS_POINTS;
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
        uint256 scope1,
        uint256 scope2,
        uint256 scope3,
        uint256 maxCurationFee
    ) {
        return (SCOPE_1, SCOPE_2, SCOPE_3, MAX_CURATION_FEE);
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

    // Receive function to accept SEI
    receive() external payable {
        // Accept SEI for distribution
    }
}
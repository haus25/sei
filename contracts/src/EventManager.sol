// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IEventFactory.sol";
import "./Delegation.sol";

/**
 * @title EventManager
 * @dev Manages post-creation operations for RTA events, including delegation via proxies.
 * This contract is upgradeable and is the single point of contact for permissioned actions.
 */
contract EventManager is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // Address of the main EventFactory
    IEventFactory public eventFactory;
    
    // Address of the master implementation for our delegation proxies
    address public delegationContract;
    
    // Address of the CreationWrapper contract that can create delegation proxies on behalf of users
    address public creationWrapper;

    // Mapping from eventId to its dedicated delegation proxy contract
    mapping(uint256 => address) public eventDelegationProxy;
    
    // Mapping to store who is the authorized delegate for an event's proxy
    mapping(uint256 => address) public eventDelegates;

    // --- Events ---
    event DelegationProxyCreated(uint256 indexed eventId, address proxyAddress, address indexed delegatee);
    event DelegateUpdated(uint256 indexed eventId, address indexed newDelegatee);
    event CreationWrapperUpdated(address indexed newCreationWrapper);

    // --- Errors ---
    error OnlyEventCreator();
    error ProxyAlreadyExists();
    error NotAuthorized();
    error InvalidAddress();
    error OnlyCreationWrapper();

    /**
     * @dev Initializes the EventManager.
     */
    function initialize(address _owner, address _eventFactoryAddress) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        eventFactory = IEventFactory(_eventFactoryAddress);
        
        // Deploy the master implementation for our delegation contract
        // This is a one-time deployment. All proxies will point to this logic.
        delegationContract = address(new Delegation());
    }

    /**
     * @dev Sets the CreationWrapper contract address. Only owner can call this.
     */
    function setCreationWrapper(address _creationWrapper) external onlyOwner {
        if (_creationWrapper == address(0)) {
            revert InvalidAddress();
        }
        creationWrapper = _creationWrapper;
        emit CreationWrapperUpdated(_creationWrapper);
    }

    /**
     * @dev Deploys a lightweight, clonable proxy for an event to handle delegation.
     * Only the creator of the event can initiate this.
     * @param eventId The ID of the event to create a delegation proxy for.
     * @param delegatee The address that will be granted delegation powers.
     */
    function createDelegationProxy(uint256 eventId, address delegatee) external {
        // 1. Authorization Check: Only the original creator of the NFT can set up delegation.
        if (eventFactory.ownerOf(eventId) != msg.sender) {
            revert OnlyEventCreator();
        }
        if (eventDelegationProxy[eventId] != address(0)) {
            revert ProxyAlreadyExists();
        }
        if (delegatee == address(0)) {
            revert InvalidAddress();
        }

        // 2. Deploy Proxy: Use the cheaper Clones library to deploy a minimal proxy.
        // This proxy points to 'delegationContract'.
        address proxy = Clones.clone(delegationContract);
        
        // 3. Initialize Proxy: Set the initial state of the new proxy contract.
        Delegation(proxy).initialize(eventId, address(eventFactory), delegatee);

        // 4. Store State
        eventDelegationProxy[eventId] = proxy;
        eventDelegates[eventId] = delegatee;

        emit DelegationProxyCreated(eventId, proxy, delegatee);
    }

    /**
     * @dev Deploys a delegation proxy on behalf of a user. Only the CreationWrapper can call this.
     * This allows the CreationWrapper to create events and set up delegation in a single transaction.
     * @param eventId The ID of the event to create a delegation proxy for.
     * @param eventCreator The address of the event creator (who owns the NFT).
     * @param delegatee The address that will be granted delegation powers.
     */
    function createDelegationProxyForUser(
        uint256 eventId, 
        address eventCreator, 
        address delegatee
    ) external {
        // 1. Authorization Check: Only the CreationWrapper contract can call this
        if (msg.sender != creationWrapper) {
            revert OnlyCreationWrapper();
        }
        
        // 2. Verify the eventCreator actually owns the NFT
        if (eventFactory.ownerOf(eventId) != eventCreator) {
            revert OnlyEventCreator();
        }
        
        if (eventDelegationProxy[eventId] != address(0)) {
            revert ProxyAlreadyExists();
        }
        if (delegatee == address(0)) {
            revert InvalidAddress();
        }

        // 3. Deploy Proxy: Use the cheaper Clones library to deploy a minimal proxy.
        // This proxy points to 'delegationContract'.
        address proxy = Clones.clone(delegationContract);
        
        // 4. Initialize Proxy: Set the initial state of the new proxy contract.
        Delegation(proxy).initialize(eventId, address(eventFactory), delegatee);

        // 5. Store State
        eventDelegationProxy[eventId] = proxy;
        eventDelegates[eventId] = delegatee;

        emit DelegationProxyCreated(eventId, proxy, delegatee);
    }

    /**
     * @dev Main function to update an event's metadata.
     * Checks if the caller is the creator OR the authorized delegate via the proxy.
     */
    function updateMetadata(uint256 eventId, string memory newMetadataURI) external {
        // Authorization: Caller must be the original creator or the registered delegate for this event.
        if (eventFactory.ownerOf(eventId) != msg.sender && eventDelegates[eventId] != msg.sender) {
            revert NotAuthorized();
        }
        
        // If authorized, this contract calls the EventFactory to perform the state change.
        _authorize(eventId);
        eventFactory.setMetadataURI(eventId, newMetadataURI);
    }
    
    function updateReservePrice(uint256 eventId, uint256 newReservePrice) external {
        _authorize(eventId);
        eventFactory.setReservePrice(eventId, newReservePrice);
    }

    function finalizeRTA(uint256 eventId) external {
        if (eventFactory.ownerOf(eventId) != msg.sender && eventDelegates[eventId] != msg.sender) {
            revert NotAuthorized();
        }
        _authorize(eventId);
        eventFactory.finalizeAndTransfer(eventId);
    }

    // --- Internal Functions ---
    
    /**
     * @dev Internal function to authorize access to event operations.
     * Checks if the caller is the event owner or authorized delegate.
     */
    function _authorize(uint256 eventId) internal view {
        if (eventFactory.ownerOf(eventId) != msg.sender && eventDelegates[eventId] != msg.sender) {
            revert NotAuthorized();
        }
    }

    // --- Other Management Functions ---
    
    function updateDelegate(uint256 eventId, address newDelegatee) external {
        if (eventFactory.ownerOf(eventId) != msg.sender) {
            revert OnlyEventCreator();
        }
        if (newDelegatee == address(0)) {
            revert InvalidAddress();
        }
        eventDelegates[eventId] = newDelegatee;
        emit DelegateUpdated(eventId, newDelegatee);
    }

    // This contract itself is upgradeable.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
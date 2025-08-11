// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Create2.sol";
import "../TicketKiosk.sol";
import "../Curation.sol";
import "../../interfaces/IDistributor.sol";
import "../../interfaces/ILiveTipping.sol";

/**
 * @title EventFactoryLib
 * @dev Library containing deployment logic for EventFactory
 * Reduces main contract size while maintaining exact functionality
 */
library EventFactoryLib {
    /**
     * @dev Deploy TicketKiosk for an event using CREATE2
     */
    function deployTicketKiosk(
        uint256 eventId,
        address factoryAddress,
        address creator,
        uint256 ticketsAmount,
        uint256 ticketPrice,
        string memory artCategory,
        address treasuryReceiver
    ) external returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(TicketKiosk).creationCode,
            abi.encode(eventId, factoryAddress, creator, ticketsAmount, ticketPrice, artCategory, treasuryReceiver)
        );
        bytes32 salt = keccak256(abi.encodePacked(eventId, "ticketkiosk"));
        return Create2.deploy(0, salt, bytecode);
    }

    /**
     * @dev Deploy Curation contract for an event using CREATE2
     */
    function deployCuration(
        uint256 eventId,
        address factoryAddress,
        address creator,
        uint256 scope,
        string memory description,
        address distributorContract
    ) external returns (address) {
        // Use creator as curator with default 3% fee
        uint256 defaultFee = 3;
        
        bytes memory bytecode = abi.encodePacked(
            type(Curation).creationCode,
            abi.encode(
                eventId,
                factoryAddress,
                creator,
                creator, // curator = creator
                defaultFee,
                scope,
                description,
                distributorContract
            )
        );
        bytes32 salt = keccak256(abi.encodePacked(eventId, "curation"));
        return Create2.deploy(0, salt, bytecode);
    }

    /**
     * @dev Register event with external contracts
     */
    function registerWithExternalContracts(
        uint256 eventId,
        address creator,
        uint256 startDate,
        uint256 eventDuration,
        uint256 reservePrice,
        address distributorContract,
        address liveTippingContract
    ) external {
        // Register with Distributor
        IDistributor(distributorContract).registerEvent(eventId, creator);

        // Register with LiveTipping
        ILiveTipping(liveTippingContract).registerEvent(
            eventId, 
            creator, 
            startDate, 
            eventDuration,
            reservePrice
        );
    }

    /**
     * @dev Register curation with Distributor
     */
    function registerCurationWithDistributor(
        uint256 eventId,
        address curationAddress,
        address distributorContract
    ) external {
        IDistributor(distributorContract).enableCurationFromContract(eventId, curationAddress);
    }
}

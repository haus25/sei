// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDelegation {
    /**
     * @dev Initializes the delegation contract with immutable data.
     * @param eventId The event this delegation contract is for.
     * @param factory The address of the main EventFactory.
     * @param delegatee The address being granted delegation permissions.
     */
    function initialize(uint256 eventId, address factory, address delegatee) external;
}
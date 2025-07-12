// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IDelegation.sol";

/**
 * @title Delegation
 * @dev Master implementation for a simple, stateful delegation record.
 * This contract is intended to be deployed as a minimal proxy (clone).
 * Its purpose is to be a cheap, on-chain record of a delegation relationship,
 * set once and then left immutable.
 */
contract Delegation is IDelegation {
    uint256 public eventId;
    address public eventFactory;
    address public delegatee;
    address public initializer;

    error AlreadyInitialized();

    /**
     * @dev See {IDelegation-initialize}.
     * A simple re-entrancy guard is included by checking if the initializer has been set.
     */
    function initialize(uint256 _eventId, address _factory, address _delegatee) external override {
        if (initializer != address(0)) revert AlreadyInitialized();

        eventId = _eventId;
        eventFactory = _factory;
        delegatee = _delegatee;
        initializer = msg.sender; // The EventManager that deployed this clone
    }
}
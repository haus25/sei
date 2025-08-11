// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDistributor {
    function registerEvent(uint256 eventId, address creator) external;
    function enableCurationFromContract(uint256 eventId, address curationContract) external;
}
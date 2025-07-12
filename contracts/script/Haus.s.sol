// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

// --- Import contract interfaces and implementations ---
// Note: Adjust paths if your project structure is different.
import {EventFactory} from "../src/EventFactory.sol";
import {EventManager} from "../src/EventManager.sol";
import {Delegation} from "../src/Delegation.sol";
import {LiveTipping} from "../src/LiveTipping.sol";
import {Distributor} from "../src/Distributor.sol";
import {CreationWrapper} from "../src/CreationWrapper.sol";

contract HausDeploymentScript is Script {
    // --- Configuration ---
    // Load from your .env file: forge script HausDeploymentScript --rpc-url <your_rpc> --broadcast
    address treasuryReceiver = vm.envAddress("TREASURY_RECEIVER");

    // --- Deployment artifacts ---
    ProxyAdmin public proxyAdmin;

    // Implementation contracts
    EventFactory public eventFactoryImpl;
    EventManager public eventManagerImpl;
    LiveTipping public liveTippingImpl;
    Distributor public distributorImpl;

    // Final contract instances (proxies or direct addresses)
    EventFactory public eventFactory;
    EventManager public eventManager;
    LiveTipping public liveTipping;
    Distributor public distributor;
    CreationWrapper public creationWrapper;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        
        console2.log("Deploying contracts with address:", deployerAddress);
        console2.log("Treasury receiver:", treasuryReceiver);
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ProxyAdmin: Manages all proxy upgrades
        proxyAdmin = new ProxyAdmin(deployerAddress);
        
        // 2. Deploy all implementation contracts first
        _deployImplementations();
        
        // 3. Deploy proxies and final contracts, wiring them up
        _deployAndInitializeContracts(deployerAddress);

        // 4. Deploy the utility CreationWrapper
        creationWrapper = new CreationWrapper(address(eventFactory), address(eventManager));
        
        vm.stopBroadcast();
        _logDeploymentAddresses();
    }
    
    function _deployImplementations() internal {
        console2.log("\nDeploying implementations...");
        eventFactoryImpl = new EventFactory();
        eventManagerImpl = new EventManager();
        liveTippingImpl = new LiveTipping();
        distributorImpl = new Distributor();
        
        console2.log("  EventFactory Impl:", address(eventFactoryImpl));
        console2.log("  EventManager Impl:", address(eventManagerImpl));
        console2.log("  LiveTipping Impl:", address(liveTippingImpl));
        console2.log("  Distributor Impl:", address(distributorImpl));
    }
    
    function _deployAndInitializeContracts(address owner) internal {
        console2.log("\nDeploying proxies and initializing contracts...");

        // Deploy EventFactory (non-upgradeable) FIRST to resolve circular dependencies
        // It's non-upgradeable by design to be a stable anchor for the system.
        eventFactory = new EventFactory();
        console2.log("EventFactory deployed at:", address(eventFactory));

        // Deploy EventManager Proxy
        bytes memory eventManagerInitData = abi.encodeWithSelector(EventManager.initialize.selector, owner, address(eventFactory));
        TransparentUpgradeableProxy eventManagerProxy = new TransparentUpgradeableProxy(address(eventManagerImpl), address(proxyAdmin), eventManagerInitData);
        eventManager = EventManager(payable(address(eventManagerProxy)));
        
        // Deploy LiveTipping Proxy with EventFactory address
        bytes memory liveTippingInitData = abi.encodeWithSelector(LiveTipping.initialize.selector, owner, address(eventFactory), address(0), treasuryReceiver);
        TransparentUpgradeableProxy liveTippingProxy = new TransparentUpgradeableProxy(address(liveTippingImpl), address(proxyAdmin), liveTippingInitData);
        liveTipping = LiveTipping(payable(address(liveTippingProxy)));

        // Deploy Distributor Proxy with EventFactory address
        bytes memory distributorInitData = abi.encodeWithSelector(Distributor.initialize.selector, owner, address(eventFactory), address(liveTipping), address(0), address(0), treasuryReceiver);
        TransparentUpgradeableProxy distributorProxy = new TransparentUpgradeableProxy(address(distributorImpl), address(proxyAdmin), distributorInitData);
        distributor = Distributor(payable(address(distributorProxy)));

        // Initialize EventFactory with all the deployed contract addresses
        eventFactory.initialize(owner, address(eventManager), address(distributor), address(liveTipping));
        
        console2.log("All contracts deployed and initialized successfully.");
    }
    
    function _logDeploymentAddresses() internal view {
        console2.log("\n=== DEPLOYMENT SUMMARY ===");
        console2.log("ProxyAdmin:      ", address(proxyAdmin));
        console2.log("----------------------------------");
        console2.log("EventFactory:    ", address(eventFactory));
        console2.log("EventManager:    ", address(eventManager));
        console2.log("LiveTipping:     ", address(liveTipping));
        console2.log("Distributor:     ", address(distributor));
        console2.log("Delegation Impl: ", eventManager.delegationContract());
        console2.log("CreationWrapper: ", address(creationWrapper));
        console2.log("----------------------------------");
        console2.log("Treasury:        ", treasuryReceiver);
        console2.log("=========================\n");
    }
}

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

contract Deploy is Script {
    // --- Configuration ---
    // forge script Deploy --rpc-url <rpc> --broadcast
    address treasuryReceiver = vm.envAddress("TREASURY_RECEIVER");
    
    // Scope Agent Proxy Addresses - These will be automatically whitelisted
    address constant PLANNER_PROXY_ADDRESS = 0xF2aC15F3db8Fd24c83494fc7B2131A74DFCAA07b;
    address constant PROMOTER_PROXY_ADDRESS = 0x27B8c4E2E6AaF49527b62278D834497BA344b90D;
    address constant PRODUCER_PROXY_ADDRESS = 0xEb215ba313c12D58417674c810bAcd6C6badAD61;

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
    // Note: No global curation instance - deployed per-event via EventFactory
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
        
        // 5. Configure EventManager with CreationWrapper address
        eventManager.setCreationWrapper(address(creationWrapper));
        
        // 6. Whitelist scope agent proxy addresses for global authorization
        _whitelistScopeAgents();
        
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
        console2.log("  Note: Curation contracts deployed per-event (no global impl needed)");
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

        // Deploy Distributor Proxy with EventFactory address and placeholders (curation wired below)
        bytes memory distributorInitData = abi.encodeWithSelector(Distributor.initialize.selector, owner, address(eventFactory), address(liveTipping), address(0), address(0), treasuryReceiver);
        TransparentUpgradeableProxy distributorProxy = new TransparentUpgradeableProxy(address(distributorImpl), address(proxyAdmin), distributorInitData);
        distributor = Distributor(payable(address(distributorProxy)));

        // Note: Individual Curation contracts are deployed per-event ONLY when creators request curation
        // via EventFactory.deployCurationForEvent() - same pattern as TicketKiosk deployment
        
        // Back-reference curation implementation into Distributor (no global instance)
        distributor.updateContracts(address(0), address(0), address(0), address(0));

        // Initialize EventFactory with deployed addresses
        eventFactory.initialize(owner, address(eventManager), address(distributor), address(liveTipping), treasuryReceiver);
        
        // Update LiveTipping with the distributor contract address
        liveTipping.updateDistributorContract(address(distributor));
        
        console2.log("All contracts deployed and initialized successfully.");
    }
    
    function _whitelistScopeAgents() internal {
        console2.log("\nWhitelisting scope agent proxy addresses...");
        
        // Create array of scope agent addresses
        address[] memory agents = new address[](3);
        agents[0] = PLANNER_PROXY_ADDRESS;
        agents[1] = PROMOTER_PROXY_ADDRESS;
        agents[2] = PRODUCER_PROXY_ADDRESS;
        
        // Batch whitelist all scope agents
        eventManager.batchSetGlobalWhitelist(agents, true);
        
        console2.log("  Planner Agent:  ", PLANNER_PROXY_ADDRESS, "- WHITELISTED");
        console2.log("  Promoter Agent: ", PROMOTER_PROXY_ADDRESS, "- WHITELISTED");
        console2.log("  Producer Agent: ", PRODUCER_PROXY_ADDRESS, "- WHITELISTED");
        console2.log("Scope agents whitelisted successfully.");
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
        console2.log("WHITELISTED SCOPE AGENTS:");
        console2.log("  Planner:       ", PLANNER_PROXY_ADDRESS);
        console2.log("  Promoter:      ", PROMOTER_PROXY_ADDRESS);
        console2.log("  Producer:      ", PRODUCER_PROXY_ADDRESS);
        console2.log("----------------------------------");
        console2.log("Treasury:        ", treasuryReceiver);
        console2.log("=========================\n");
    }
}
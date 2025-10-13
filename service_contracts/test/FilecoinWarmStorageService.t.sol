// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console, Vm} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Cids} from "@pdp/Cids.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";

import {CHALLENGES_PER_PROOF, FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {FilecoinWarmStorageServiceStateLibrary} from "../src/lib/FilecoinWarmStorageServiceStateLibrary.sol";
import {Payments} from "@fws-payments/Payments.sol";
import {MockERC20, MockPDPVerifier} from "./mocks/SharedMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "../src/Errors.sol";

import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";

contract FilecoinWarmStorageServiceTest is Test {
    using SafeERC20 for MockERC20;
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    // Testing Constants

    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // r
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // s
        uint8(27) // v
    );

    // Contracts
    FilecoinWarmStorageService public pdpServiceWithPayments;
    FilecoinWarmStorageServiceStateView public viewContract;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public serviceProviderRegistry;
    SessionKeyRegistry public sessionKeyRegistry = new SessionKeyRegistry();

    // Test accounts
    address public deployer;
    address public client;
    address public serviceProvider;
    address public filBeamController;
    address public filBeamBeneficiary;
    address public session;

    address public sp1;
    address public sp2;
    address public sp3;

    address public sessionKey1;
    address public sessionKey2;

    // Test parameters
    bytes public extraData;

    // Metadata size and count limits
    uint256 private constant MAX_KEY_LENGTH = 32;
    uint256 private constant MAX_VALUE_LENGTH = 128;
    uint256 private constant MAX_KEYS_PER_DATASET = 10;
    uint256 private constant MAX_KEYS_PER_PIECE = 5;

    bytes32 private constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)"
        "MetadataEntry(string key,string value)"
    );
    bytes32 private constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 firstAdded,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );
    bytes32 private constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    bytes32 private constant DELETE_DATA_SET_TYPEHASH = keccak256("DeleteDataSet(uint256 clientDataSetId)");

    // Expected lockup amounts for CDN rails
    uint256 defaultCDNLockup;
    uint256 defaultCacheMissLockup;
    uint256 defaultTotalCDNLockup;

    // Structs
    struct PieceMetadataSetup {
        uint256 dataSetId;
        uint256 pieceId;
        Cids.Cid[] pieceData;
        bytes extraData;
    }

    function setUp() public {
        // Setup test accounts
        deployer = address(this);
        client = address(0xf1);
        serviceProvider = address(0xf2);
        filBeamController = address(0xf3);
        filBeamBeneficiary = address(0xf4);

        // Additional accounts for serviceProviderRegistry tests
        sp1 = address(0xf5);
        sp2 = address(0xf6);
        sp3 = address(0xf7);

        // Session keys
        sessionKey1 = address(0xa1);
        sessionKey2 = address(0xa2);

        // Fund test accounts
        vm.deal(deployer, 100 ether);
        vm.deal(client, 100 ether);
        vm.deal(serviceProvider, 100 ether);
        vm.deal(sp1, 100 ether);
        vm.deal(sp2, 100 ether);
        vm.deal(sp3, 100 ether);
        vm.deal(address(0xf10), 100 ether);
        vm.deal(address(0xf11), 100 ether);
        vm.deal(address(0xf12), 100 ether);
        vm.deal(address(0xf13), 100 ether);
        vm.deal(address(0xf14), 100 ether);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        serviceProviderRegistry = ServiceProviderRegistry(address(registryProxy));

        // Register service providers in the serviceProviderRegistry
        vm.prank(serviceProvider);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            serviceProvider, // payee
            "Service Provider",
            "Service Provider Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-Central",
                    paymentTokenAddress: IERC20(address(0)) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        vm.prank(sp1);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp1, // payee
            "SP1",
            "Storage Provider 1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://sp1.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-Central",
                    paymentTokenAddress: IERC20(address(0)) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        vm.prank(sp2);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp2, // payee
            "SP2",
            "Storage Provider 2",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://sp2.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-Central",
                    paymentTokenAddress: IERC20(address(0)) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        vm.prank(sp3);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp3, // payee
            "SP3",
            "Storage Provider 3",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://sp3.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-Central",
                    paymentTokenAddress: IERC20(address(0)) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        // Deploy Payments contract (no longer upgradeable)
        payments = new Payments();

        // Transfer tokens to client for payment
        mockUSDFC.safeTransfer(client, 10000 * 10 ** mockUSDFC.decimals());

        // Initialize expected lockup amounts
        defaultCDNLockup = (7 * 10 ** mockUSDFC.decimals()) / 10; // 0.7 USDFC
        defaultCacheMissLockup = (3 * 10 ** mockUSDFC.decimals()) / 10; // 0.3 USDFC
        defaultTotalCDNLockup = defaultCacheMissLockup + defaultCDNLockup;

        // Deploy FilecoinWarmStorageService with proxy
        FilecoinWarmStorageService pdpServiceImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );
        bytes memory initializeData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60), // challengeWindowSize
            filBeamController, // filBeamControllerAddress
            "Filecoin Warm Storage Service", // service name
            "A decentralized storage service with proof-of-data-possession and payment integration" // service description
        );

        MyERC1967Proxy pdpServiceProxy = new MyERC1967Proxy(address(pdpServiceImpl), initializeData);
        pdpServiceWithPayments = FilecoinWarmStorageService(address(pdpServiceProxy));

        // Add providers to approved list
        pdpServiceWithPayments.addApprovedProvider(1); // serviceProvider
        pdpServiceWithPayments.addApprovedProvider(2); // sp1
        pdpServiceWithPayments.addApprovedProvider(3); // sp2
        pdpServiceWithPayments.addApprovedProvider(4); // sp3

        viewContract = new FilecoinWarmStorageServiceStateView(pdpServiceWithPayments);
        pdpServiceWithPayments.setViewContract(address(viewContract));
    }

    function makeSignaturePass(address signer) public {
        vm.mockCall(
            address(0x01), // ecrecover precompile address
            bytes(hex""), // wildcard matching of all inputs requires precisely no bytes
            abi.encode(signer)
        );
    }

    function testInitialState() public view {
        assertEq(
            pdpServiceWithPayments.pdpVerifierAddress(),
            address(mockPDPVerifier),
            "PDP verifier address should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.paymentsContractAddress(),
            address(payments),
            "Payments contract address should be set correctly"
        );
        assertEq(
            address(pdpServiceWithPayments.usdfcTokenAddress()),
            address(mockUSDFC),
            "USDFC token address should be set correctly"
        );
        assertEq(viewContract.filBeamControllerAddress(), filBeamController, "FilBeam address should be set correctly");
        assertEq(
            viewContract.serviceCommissionBps(),
            0, // 0%
            "Service commission should be set correctly"
        );
        (uint64 maxProvingPeriod, uint256 challengeWindow, uint256 challengesPerProof,) = viewContract.getPDPConfig();
        assertEq(maxProvingPeriod, 2880, "Max proving period should be set correctly");
        assertEq(challengeWindow, 60, "Challenge window size should be set correctly");
        assertEq(challengesPerProof, 5, "Challenges per proof should be 5");
    }

    function testFilecoinServiceDeployedEvent() public {
        // Deploy a new service instance to test the event
        FilecoinWarmStorageService newServiceImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        // Expected event parameters
        string memory expectedName = "Test Event Service";
        string memory expectedDescription = "Service for testing events";

        bytes memory initData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            expectedName,
            expectedDescription
        );

        // Expect the FilecoinServiceDeployed event
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.FilecoinServiceDeployed(expectedName, expectedDescription);

        // Deploy the proxy which triggers the initialize function
        new MyERC1967Proxy(address(newServiceImpl), initData);
    }

    function testServiceNameAndDescriptionValidation() public {
        // Test empty name validation
        FilecoinWarmStorageService serviceImpl1 = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        bytes memory initDataEmptyName = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            "", // empty name
            "Valid description"
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidServiceNameLength.selector, 0));
        new MyERC1967Proxy(address(serviceImpl1), initDataEmptyName);

        // Test empty description validation
        FilecoinWarmStorageService serviceImpl2 = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        bytes memory initDataEmptyDesc = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            "Valid name",
            "" // empty description
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidServiceDescriptionLength.selector, 0));
        new MyERC1967Proxy(address(serviceImpl2), initDataEmptyDesc);

        // Test name exceeding 256 characters
        FilecoinWarmStorageService serviceImpl3 = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        string memory longName = string(
            abi.encodePacked(
                "This is a very long name that exceeds the maximum allowed length of 256 characters. ",
                "It needs to be long enough to trigger the validation error in the contract. ",
                "Adding more text here to ensure we go past the limit. ",
                "Still need more characters to exceed 256 total length for this test case to work properly. ",
                "Almost there, just a bit more text needed to push us over the limit."
            )
        );

        bytes memory initDataLongName = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            longName,
            "Valid description"
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidServiceNameLength.selector, bytes(longName).length));
        new MyERC1967Proxy(address(serviceImpl3), initDataLongName);

        // Test description exceeding 256 characters
        FilecoinWarmStorageService serviceImpl4 = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        string memory longDesc = string(
            abi.encodePacked(
                "This is a very long description that exceeds the maximum allowed length of 256 characters. ",
                "It needs to be long enough to trigger the validation error in the contract. ",
                "Adding more text here to ensure we go past the limit. ",
                "Still need more characters to exceed 256 total length for this test case to work properly. ",
                "Almost there, just a bit more text needed to push us over the limit."
            )
        );

        bytes memory initDataLongDesc = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            "Valid name",
            longDesc
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidServiceDescriptionLength.selector, bytes(longDesc).length));
        new MyERC1967Proxy(address(serviceImpl4), initDataLongDesc);
    }

    function testUpgrade() public {
        FilecoinWarmStorageService firstServiceImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        // Expected event parameters
        string memory name = "FWSS";
        string memory description = "FilecoinWarmStorageService";

        bytes memory initData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            name,
            description
        );

        // Deploy the proxy which triggers the initialize function
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(firstServiceImpl), initData);
        FilecoinWarmStorageService service = FilecoinWarmStorageService(address(proxy));
        viewContract = new FilecoinWarmStorageServiceStateView(service);

        bytes memory migrateData = abi.encodeWithSelector(FilecoinWarmStorageService.migrate.selector, viewContract);

        (address nextImplementation, uint96 afterEpoch) = viewContract.nextUpgrade();
        assertEq(nextImplementation, address(0));
        assertEq(afterEpoch, uint96(0));

        // Do not allow upgrade to zero address even if it's the nextImplementation
        vm.expectRevert();
        service.upgradeToAndCall(nextImplementation, migrateData);

        FilecoinWarmStorageService newServiceImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );

        FilecoinWarmStorageService.PlannedUpgrade memory plan;
        plan.nextImplementation = address(newServiceImpl);
        plan.afterEpoch = uint96(vm.getBlockNumber()) + 2000;
        service.announcePlannedUpgrade(plan);

        (nextImplementation, afterEpoch) = viewContract.nextUpgrade();
        assertEq(nextImplementation, plan.nextImplementation);
        assertEq(afterEpoch, plan.afterEpoch);

        // Do not allow upgrade until afterEpoch
        vm.expectRevert();
        service.upgradeToAndCall(nextImplementation, migrateData);
        vm.roll(plan.afterEpoch - 1);
        vm.expectRevert();
        service.upgradeToAndCall(plan.nextImplementation, migrateData);

        vm.roll(plan.afterEpoch);
        vm.expectEmit(false, false, false, true, address(service));
        emit FilecoinWarmStorageService.ContractUpgraded(newServiceImpl.VERSION(), plan.nextImplementation);
        service.upgradeToAndCall(plan.nextImplementation, migrateData);
    }

    function _getSingleMetadataKV(string memory key, string memory value)
        internal
        pure
        returns (string[] memory, string[] memory)
    {
        string[] memory keys = new string[](1);
        string[] memory values = new string[](1);
        keys[0] = key;
        values[0] = value;
        return (keys, values);
    }

    function testCreateDataSetCreatesRail() public {
        // Prepare ExtraData - withCDN key presence means CDN is enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");

        // Prepare ExtraData
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            payer: client,
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        // Encode the extra data
        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the Payments contract for future payments
        uint256 depositAmount = 10e6; // Sufficient funds for initial lockup and future operations
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect CDNPaymentRailsToppedUp event when creating the data set with CDN enabled
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(1, defaultCDNLockup, defaultCacheMissLockup);

        // Expect DataSetCreated event when creating the data set (with CDN rails)
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetCreated(
            1, 1, 1, 2, 3, client, serviceProvider, serviceProvider, createData.metadataKeys, createData.metadataValues
        );

        // Create a data set as the service provider
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Get data set info
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        uint256 pdpRailId = dataSet.pdpRailId;
        uint256 cacheMissRailId = dataSet.cacheMissRailId;
        uint256 cdnRailId = dataSet.cdnRailId;

        // Verify valid rail IDs were created
        assertTrue(pdpRailId > 0, "PDP Rail ID should be non-zero");
        assertTrue(cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(cdnRailId > 0, "CDN Rail ID should be non-zero");

        // Verify data set info was stored correctly
        assertEq(dataSet.payer, client, "Payer should be set to client");
        assertEq(dataSet.payee, serviceProvider, "Payee should be set to service provider");

        // Verify metadata was stored correctly
        (bool exists, string memory metadata) = viewContract.getDataSetMetadata(newDataSetId, metadataKeys[0]);
        assertTrue(exists, "Metadata key should exist");
        assertEq(metadata, "true", "Metadata should be stored correctly");

        // Verify client data set ids
        uint256[] memory clientDataSetIds = viewContract.clientDataSets(client);
        assertEq(clientDataSetIds.length, 1);
        assertEq(clientDataSetIds[0], newDataSetId);

        assertEq(viewContract.railToDataSet(pdpRailId), newDataSetId);

        // Verify data set info
        FilecoinWarmStorageService.DataSetInfoView memory dataSetInfo = viewContract.getDataSet(newDataSetId);
        assertEq(dataSetInfo.pdpRailId, pdpRailId, "PDP rail ID should match");
        assertNotEq(dataSetInfo.cacheMissRailId, 0, "Cache miss rail ID should be set");
        assertNotEq(dataSetInfo.cdnRailId, 0, "CDN rail ID should be set");
        assertEq(dataSetInfo.payer, client, "Payer should match");
        assertEq(dataSetInfo.payee, serviceProvider, "Payee should match");

        // Verify the rails in the actual Payments contract
        Payments.RailView memory pdpRail = payments.getRail(pdpRailId);
        assertEq(address(pdpRail.token), address(mockUSDFC), "Token should be USDFC");
        assertEq(pdpRail.from, client, "From address should be client");
        assertEq(pdpRail.to, serviceProvider, "To address should be service provider");
        assertEq(pdpRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(pdpRail.validator, address(pdpServiceWithPayments), "Validator should be the PDP service");
        assertEq(pdpRail.commissionRateBps, 0, "No commission");
        assertEq(pdpRail.lockupFixed, 0, "Lockup fixed should be 0 after one-time payment");
        assertEq(pdpRail.paymentRate, 0, "Initial payment rate should be 0");

        Payments.RailView memory cacheMissRail = payments.getRail(cacheMissRailId);
        assertEq(address(cacheMissRail.token), address(mockUSDFC), "Token should be USDFC");
        assertEq(cacheMissRail.from, client, "From address should be client");
        assertEq(cacheMissRail.to, serviceProvider, "To address should be service provider");
        assertEq(cacheMissRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(cacheMissRail.validator, address(0), "Validator should be empty");
        assertEq(cacheMissRail.commissionRateBps, 0, "No commission");
        assertEq(cacheMissRail.lockupFixed, defaultCacheMissLockup, "Cache miss lockup should be 0.3 USDFC");
        assertEq(cacheMissRail.paymentRate, 0, "Initial payment rate should be 0");

        Payments.RailView memory cdnRail = payments.getRail(cdnRailId);
        assertEq(address(cdnRail.token), address(mockUSDFC), "Token should be USDFC");
        assertEq(cdnRail.from, client, "From address should be client");
        assertEq(cdnRail.to, filBeamBeneficiary, "To address should be FilBeamBeneficiary");
        assertEq(cdnRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(cdnRail.validator, address(0), "Validator should be empty");
        assertEq(cdnRail.commissionRateBps, 0, "No commission");
        assertEq(cdnRail.lockupFixed, defaultCDNLockup, "CDN lockup should be 0.7 USDFC");
        assertEq(cdnRail.paymentRate, 0, "Initial payment rate should be 0");
    }

    function testCreateDataSetNoCDN() public {
        // Prepare ExtraData - no withCDN key means CDN is disabled
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);

        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            payer: client,
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        // Encode the extra data
        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the Payments contract for future payments
        uint256 depositAmount = 10e6; // Sufficient funds for initial lockup and future operations
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect DataSetCreated event when creating the data set (no CDN rails)
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetCreated(
            1, 1, 1, 0, 0, client, serviceProvider, serviceProvider, createData.metadataKeys, createData.metadataValues
        );

        // Create a data set as the service provider
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Get data set info
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertEq(dataSet.payer, client);
        assertEq(dataSet.payee, serviceProvider);
        // Verify the commission rate was set correctly for basic service (no CDN)
        Payments.RailView memory pdpRail = payments.getRail(dataSet.pdpRailId);
        assertEq(pdpRail.commissionRateBps, 0, "Commission rate should be 0% for basic service (no CDN)");

        assertEq(dataSet.cacheMissRailId, 0, "Cache miss rail ID should be 0 for basic service (no CDN)");
        assertEq(dataSet.cdnRailId, 0, "CDN rail ID should be 0 for basic service (no CDN)");

        // now with session key
        vm.prank(client);
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = CREATE_DATA_SET_TYPEHASH;
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "FilecoinWarmStorageServiceTest");
        makeSignaturePass(sessionKey1);

        extraData =
            abi.encode(createData.payer, 1, createData.metadataKeys, createData.metadataValues, createData.signature);
        vm.prank(serviceProvider);
        uint256 newDataSetId2 = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);

        FilecoinWarmStorageService.DataSetInfoView memory dataSet2 = viewContract.getDataSet(newDataSetId2);
        assertEq(dataSet2.payer, client);
        assertEq(dataSet2.payee, serviceProvider);

        extraData =
            abi.encode(createData.payer, 2, createData.metadataKeys, createData.metadataValues, createData.signature);
        // ensure another session key would be denied
        makeSignaturePass(sessionKey2);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey2));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);

        // session key expires
        vm.warp(block.timestamp + 1);
        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);

        // cannot recreate dataset
        extraData =
            abi.encode(createData.payer, 1, createData.metadataKeys, createData.metadataValues, createData.signature);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 1));
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(newDataSetId2);
        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(newDataSetId2);
        assertTrue(terminatedInfo.pdpEndEpoch > 0, "Dataset 2 should be terminated");
        // Advance block number to be greater than the end epoch to allow deletion
        vm.roll(terminatedInfo.pdpEndEpoch + 1);
        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(pdpServiceWithPayments, newDataSetId2, "");

        // cannot recreate deleted dataset
        extraData =
            abi.encode(createData.payer, 1, createData.metadataKeys, createData.metadataValues, createData.signature);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 1));
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    function testCreateDataSetAddPieces() public {
        // Create dataset with metadataKeys/metadataValues
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Test Data Set");
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            payer: client,
            clientDataSetId: 0,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });
        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Approvals and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );
        uint256 depositAmount = 10e6; // Sufficient funds for initial lockup and future operations
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Create dataset
        makeSignaturePass(client);
        vm.prank(serviceProvider); // Create dataset as service provider
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedCreateData);

        // Prepare piece batches
        uint256 firstAdded = 0;
        string memory metadataShort = "metadata";
        string memory metadataLong = "metadatAmetadaTametadAtametaDatametAdatameTadatamEtadataMetadata";

        // First batch (3 pieces) with key "meta" => metadataShort
        Cids.Cid[] memory pieceData1 = new Cids.Cid[](3);
        pieceData1[0].data = bytes("1_0:1111");
        pieceData1[1].data = bytes("1_1:111100000");
        pieceData1[2].data = bytes("1_2:11110000000000");
        string[] memory keys1 = new string[](1);
        string[] memory values1 = new string[](1);
        keys1[0] = "meta";
        values1[0] = metadataShort;
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData1, FAKE_SIGNATURE, keys1, values1
        );
        firstAdded += pieceData1.length;

        // Second batch (2 pieces) with key "meta" => metadataLong
        Cids.Cid[] memory pieceData2 = new Cids.Cid[](2);
        pieceData2[0].data = bytes("2_0:22222222222222222222");
        pieceData2[1].data = bytes("2_1:222222222222222222220000000000000000000000000000000000000000");
        string[] memory keys2 = new string[](1);
        string[] memory values2 = new string[](1);
        keys2[0] = "meta";
        values2[0] = metadataLong;
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData2, FAKE_SIGNATURE, keys2, values2
        );
        firstAdded += pieceData2.length;

        // Assert per-piece metadata
        (bool e0, string memory v0) = viewContract.getPieceMetadata(dataSetId, 0, "meta");
        assertTrue(e0);
        assertEq(v0, metadataShort);
        (bool e1, string memory v1) = viewContract.getPieceMetadata(dataSetId, 1, "meta");
        assertTrue(e1);
        assertEq(v1, metadataShort);
        (bool e2, string memory v2) = viewContract.getPieceMetadata(dataSetId, 2, "meta");
        assertTrue(e2);
        assertEq(v2, metadataShort);
        (bool e3, string memory v3) = viewContract.getPieceMetadata(dataSetId, 3, "meta");
        assertTrue(e3);
        assertEq(v3, metadataLong);
        (bool e4, string memory v4) = viewContract.getPieceMetadata(dataSetId, 4, "meta");
        assertTrue(e4);
        assertEq(v4, metadataLong);

        // now with session keys
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = ADD_PIECES_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "FilecoinWarmStorageServiceTest");

        makeSignaturePass(sessionKey1);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData2, FAKE_SIGNATURE, keys2, values2
        );
        firstAdded += pieceData2.length;

        // unauthorized session key reverts
        makeSignaturePass(sessionKey2);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey2));
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData2, FAKE_SIGNATURE, keys2, values2
        );

        // expired session key reverts
        vm.warp(block.timestamp + 1);
        makeSignaturePass(sessionKey1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData2, FAKE_SIGNATURE, keys2, values2
        );
    }

    // Helper function to get account info from the Payments contract
    function getAccountInfo(IERC20 token, address owner) internal view returns (uint256 funds, uint256 lockupCurrent) {
        (funds, lockupCurrent,,) = payments.accounts(token, owner);
        return (funds, lockupCurrent);
    }

    // Constants for calculations
    uint256 constant COMMISSION_MAX_BPS = 10000;

    function testGlobalParameters() public view {
        // These parameters should be the same as in SimplePDPService
        (uint64 maxProvingPeriod, uint256 challengeWindow, uint256 challengesPerProof,) = viewContract.getPDPConfig();
        assertEq(maxProvingPeriod, 2880, "Max proving period should be 2880 epochs");
        assertEq(challengeWindow, 60, "Challenge window should be 60 epochs");
        assertEq(challengesPerProof, 5, "Challenges per proof should be 5");
    }

    // Pricing Tests

    function testGetServicePriceValues() public view {
        // Test the values returned by getServicePrice
        FilecoinWarmStorageService.ServicePricing memory pricing = pdpServiceWithPayments.getServicePrice();

        uint256 decimals = 6; // MockUSDFC uses 6 decimals in tests
        //
        // FORK: price change
        //
        uint256 expectedNoCDN = (9 * 10 ** decimals) / 10;
        // 0.9 USDFC with 6 decimals
        uint256 expectedWithCDN = 14 * 10 ** (decimals - 1); // 1.4 USDFC with 6 decimals
        //
        // FORK: end price change
        //
        assertEq(pricing.pricePerTiBPerMonthNoCDN, expectedNoCDN, "No CDN price should be 5 * 10^decimals");
        assertEq(pricing.pricePerTiBPerMonthWithCDN, expectedWithCDN, "With CDN price should be 5.5 * 10^decimals");
        assertEq(address(pricing.tokenAddress), address(mockUSDFC), "Token address should match USDFC");
        assertEq(pricing.epochsPerMonth, 86400, "Epochs per month should be 86400");

        // Verify the values are in expected range
        assert(pricing.pricePerTiBPerMonthNoCDN < 10 ** 8); // Less than 10^8
        assert(pricing.pricePerTiBPerMonthWithCDN < 10 ** 8); // Less than 10^8
    }

    function testGetEffectiveRatesValues() public view {
        // Test the values returned by getEffectiveRates
        (uint256 serviceFee, uint256 spPayment) = pdpServiceWithPayments.getEffectiveRates();

        uint256 decimals = 6; // MockUSDFC uses 6 decimals in tests
        //
        // FORK: price change
        //
        // Total is 0.9 USDFC with 6 decimals
        uint256 expectedTotal = (9 * 10 ** decimals) / 10;
        //
        // FORK: end price change
        //

        // Test setup uses 0% commission
        uint256 expectedServiceFee = 0; // 0% commission
        uint256 expectedSpPayment = expectedTotal; // 100% goes to SP

        assertEq(serviceFee, expectedServiceFee, "Service fee should be 0 with 0% commission");
        assertEq(spPayment, expectedSpPayment, "SP payment should be 5 * 10^6");
        assertEq(serviceFee + spPayment, expectedTotal, "Total should equal 5 * 10^6");

        // Verify the values are in expected range
        assert(serviceFee + spPayment < 10 ** 8); // Less than 10^8
    }

    uint256 nextClientDataSetId = 0;

    // Client-Data Set Tracking Tests
    function prepareDataSetForClient(
        address, /*provider*/
        address clientAddress,
        string[] memory metadataKeys,
        string[] memory metadataValues
    ) internal returns (bytes memory) {
        // Prepare extra data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadataKeys: metadataKeys,
            clientDataSetId: nextClientDataSetId++,
            metadataValues: metadataValues,
            payer: clientAddress,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days);
        mockUSDFC.approve(address(payments), 100e6);
        payments.deposit(mockUSDFC, clientAddress, 100e6);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);

        return encodedData;
    }

    function createDataSetForClient(
        address provider,
        address clientAddress,
        string[] memory metadataKeys,
        string[] memory metadataValues
    ) internal returns (uint256) {
        bytes memory encodedData = prepareDataSetForClient(provider, clientAddress, metadataKeys, metadataValues);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
    }

    /**
     * @notice Helper function to delete a data set for a client
     * @dev This function creates the necessary delete signature and calls the PDP verifier
     * @param provider The service provider address who owns the data set
     * @param clientAddress The client address who should sign the deletion
     * @param dataSetId The ID of the data set to delete
     */
    function deleteDataSetForClient(address provider, address clientAddress, uint256 dataSetId) internal {
        // Delete the data set as the provider
        vm.prank(provider);
        mockPDPVerifier.deleteDataSet(pdpServiceWithPayments, dataSetId, bytes(""));
    }

    function testGetClientDataSets_EmptyClient() public view {
        // Test with a client that has no data sets
        FilecoinWarmStorageService.DataSetInfoView[] memory dataSets = viewContract.getClientDataSets(client);

        assertEq(dataSets.length, 0, "Should return empty array for client with no data sets");
    }

    function testGetClientDataSets_SingleDataSet() public {
        // Create a single data set for the client
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("label", "Test Data Set");

        createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Get data sets
        FilecoinWarmStorageService.DataSetInfoView[] memory dataSets = viewContract.getClientDataSets(client);

        // Verify results
        assertEq(dataSets.length, 1, "Should return one data set");
        assertEq(dataSets[0].payer, client, "Payer should match");
        assertEq(dataSets[0].payee, sp1, "Payee should match");
        assertEq(dataSets[0].clientDataSetId, 0, "First data set ID should be 0");
        assertGt(dataSets[0].pdpRailId, 0, "Rail ID should be set");
    }

    function testGetClientDataSets_MultipleDataSets() public {
        // Create multiple data sets for the client
        (string[] memory metadataKeys1, string[] memory metadataValues1) = _getSingleMetadataKV("label", "Metadata 1");
        (string[] memory metadataKeys2, string[] memory metadataValues2) = _getSingleMetadataKV("label", "Metadata 2");

        createDataSetForClient(sp1, client, metadataKeys1, metadataValues1);
        createDataSetForClient(sp2, client, metadataKeys2, metadataValues2);

        // Get data sets
        FilecoinWarmStorageService.DataSetInfoView[] memory dataSets = viewContract.getClientDataSets(client);

        // Verify results
        assertEq(dataSets.length, 2, "Should return two data sets");

        // Check first data set
        assertEq(dataSets[0].payer, client, "First data set payer should match");
        assertEq(dataSets[0].payee, sp1, "First data set payee should match");
        assertEq(dataSets[0].clientDataSetId, 0, "First data set ID should be 0");

        // Check second data set
        assertEq(dataSets[1].payer, client, "Second data set payer should match");
        assertEq(dataSets[1].payee, sp2, "Second data set payee should match");
        assertEq(dataSets[1].clientDataSetId, 1, "Second data set ID should be 1");
    }

    function testGetClientDataSets_TerminatedDataSets() public {
        (string[] memory metadataKeys1, string[] memory metadataValues1) = _getSingleMetadataKV("label", "Metadata 1");
        (string[] memory metadataKeys2, string[] memory metadataValues2) = _getSingleMetadataKV("label", "Metadata 2");
        (string[] memory metadataKeys3, string[] memory metadataValues3) = _getSingleMetadataKV("label", "Metadata 3");

        // Create multiple data sets for the client
        createDataSetForClient(sp1, client, metadataKeys1, metadataValues1);
        uint256 dataSet2 = createDataSetForClient(sp2, client, metadataKeys2, metadataValues2);
        createDataSetForClient(sp1, client, metadataKeys3, metadataValues3);

        // Verify we have 3 datasets initially
        FilecoinWarmStorageService.DataSetInfoView[] memory dataSets = viewContract.getClientDataSets(client);
        assertEq(dataSets.length, 3, "Should return three data sets initially");

        // Terminate the second dataset (dataSet2) - client terminates
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSet2);

        // Verify the dataset is now terminated (paymentEndEpoch > 0)
        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(dataSet2);
        assertTrue(terminatedInfo.pdpEndEpoch > 0, "Dataset 2 should have paymentEndEpoch set after termination");

        // Verify getClientDataSets still returns all 3 datasets (termination doesn't exclude from list)
        dataSets = viewContract.getClientDataSets(client);
        assertEq(dataSets.length, 3, "Should return all three data sets after termination");

        // Verify the terminated dataset has correct status
        assertTrue(dataSets[1].pdpEndEpoch > 0, "Dataset 2 should have paymentEndEpoch > 0");
    }

    function testGetClientDataSets_ExcludesDeletedDataSets() public {
        // Create multiple data sets for the client
        (string[] memory metadataKeys1, string[] memory metadataValues1) = _getSingleMetadataKV("label", "Metadata 1");
        (string[] memory metadataKeys2, string[] memory metadataValues2) = _getSingleMetadataKV("label", "Metadata 2");
        (string[] memory metadataKeys3, string[] memory metadataValues3) = _getSingleMetadataKV("label", "Metadata 3");

        createDataSetForClient(sp1, client, metadataKeys1, metadataValues1);
        uint256 dataSet2 = createDataSetForClient(sp2, client, metadataKeys2, metadataValues2);
        createDataSetForClient(sp1, client, metadataKeys3, metadataValues3);

        // Verify we have 3 datasets initially
        FilecoinWarmStorageService.DataSetInfoView[] memory dataSets = viewContract.getClientDataSets(client);
        assertEq(dataSets.length, 3, "Should return three data sets initially");

        // Terminate the second dataset (dataSet2)
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSet2);

        // Verify termination status
        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(dataSet2);
        assertTrue(terminatedInfo.pdpEndEpoch > 0, "Dataset 2 should be terminated");

        // Advance block number to be greater than the end epoch to allow deletion
        vm.roll(terminatedInfo.pdpEndEpoch + 1);

        // Delete the second dataset (dataSet2) - this should completely remove it
        deleteDataSetForClient(sp2, client, dataSet2);

        // Verify getClientDataSets now only returns 2 datasets (the deleted one is completely gone)
        dataSets = viewContract.getClientDataSets(client);
        assertEq(dataSets.length, 2, "Should return only 2 data sets after deletion");

        // Verify the deleted dataset is completely gone
        for (uint256 i = 0; i < dataSets.length; i++) {
            assertTrue(dataSets[i].clientDataSetId != 1, "Deleted dataset should not be in returned array");
        }
    }

    // ===== Data Set Service Provider Change Tests =====

    /**
     * @notice Helper function to create a data set and return its ID
     * @dev This function sets up the necessary state for service provider change testing
     * @param provider The service provider address
     * @param clientAddress The client address
     * @return The created data set ID
     */
    function createDataSetForServiceProviderTest(address provider, address clientAddress, string memory /*metadata*/ )
        internal
        returns (uint256)
    {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("label", "Test Data Set");

        // Prepare extra data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            payer: clientAddress,
            clientDataSetId: nextClientDataSetId++,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days);
        mockUSDFC.approve(address(payments), 100e6);
        payments.deposit(mockUSDFC, clientAddress, 100e6);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
    }

    /**
     * @notice Test successful service provider change between two approved providers
     * @dev Verifies only the data set's payee is updated, event is emitted, and serviceProviderRegistry state is unchanged.
     */
    function testServiceProviderChangedSuccessDecoupled() public {
        // Create a data set with sp1 as the service provider
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");

        // Change service provider from sp1 to sp2
        bytes memory testExtraData = new bytes(0);
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetServiceProviderChanged(testDataSetId, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetServiceProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);

        // Only the data set's service provider is updated
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(testDataSetId);
        assertEq(dataSet.serviceProvider, sp2, "Service provider should be updated to new service provider");
        // Payee should remain unchanged (still sp1's beneficiary)
        assertEq(dataSet.payee, sp1, "Payee should remain unchanged");
    }

    /**
     * @notice Test service provider change reverts if new service provider is not an approved provider
     */
    function testServiceProviderChangedNoLongerChecksApproval() public {
        // Create a data set with sp1 as the service provider
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        address newProvider = address(0x9999);
        bytes memory testExtraData = new bytes(0);

        // The change should now fail because the new provider is not registered
        vm.prank(newProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotRegistered.selector, newProvider));
        mockPDPVerifier.changeDataSetServiceProvider(
            testDataSetId, newProvider, address(pdpServiceWithPayments), testExtraData
        );
    }

    /**
     * @notice Test service provider change reverts if new service provider is zero address
     */
    function testServiceProviderChangedRevertsIfNewServiceProviderZeroAddress() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        vm.prank(sp1);
        vm.expectRevert("New service provider cannot be zero address");
        mockPDPVerifier.changeDataSetServiceProvider(
            testDataSetId, address(0), address(pdpServiceWithPayments), testExtraData
        );
    }

    /**
     * @notice Test service provider change reverts if old service provider mismatch
     */
    function testServiceProviderChangedRevertsIfOldServiceProviderMismatch() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as PDPVerifier with wrong old service provider
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.OldServiceProviderMismatch.selector, 1, sp1, sp2));
        pdpServiceWithPayments.storageProviderChanged(testDataSetId, sp2, sp2, testExtraData);
    }

    /**
     * @notice Test service provider change reverts if called by unauthorized address
     */
    function testServiceProviderChangedRevertsIfUnauthorizedCaller() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as sp2 (not PDPVerifier)
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), sp2));
        pdpServiceWithPayments.storageProviderChanged(testDataSetId, sp1, sp2, testExtraData);
    }

    /**
     * @notice Test multiple data sets per provider: only the targeted data set's payee is updated
     */
    function testMultipleDataSetsPerProviderServiceProviderChange() public {
        // Create two data sets for sp1
        uint256 ps1 = createDataSetForServiceProviderTest(sp1, client, "Data Set 1");
        uint256 ps2 = createDataSetForServiceProviderTest(sp1, client, "Data Set 2");
        // Change service provider of ps1 to sp2
        bytes memory testExtraData = new bytes(0);
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetServiceProviderChanged(ps1, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetServiceProvider(ps1, sp2, address(pdpServiceWithPayments), testExtraData);
        // ps1 service provider updated, ps2 service provider unchanged
        FilecoinWarmStorageService.DataSetInfoView memory dataSet1 = viewContract.getDataSet(ps1);
        FilecoinWarmStorageService.DataSetInfoView memory dataSet2 = viewContract.getDataSet(ps2);
        assertEq(dataSet1.serviceProvider, sp2, "ps1 service provider should be sp2");
        assertEq(dataSet1.payee, sp1, "ps1 payee should remain sp1");
        assertEq(dataSet2.serviceProvider, sp1, "ps2 service provider should remain sp1");
        assertEq(dataSet2.payee, sp1, "ps2 payee should remain sp1");
    }

    /**
     * @notice Test service provider change works with arbitrary extra data
     */
    function testServiceProviderChangedWithArbitraryExtraData() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        // Use arbitrary extra data
        bytes memory testExtraData = abi.encode("arbitrary", 123, address(this));
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetServiceProviderChanged(testDataSetId, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetServiceProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(testDataSetId);
        assertEq(dataSet.serviceProvider, sp2, "Service provider should be updated to new service provider");
        assertEq(dataSet.payee, sp1, "Payee should remain unchanged");
    }

    function testProvenPeriods() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        for (uint256 i = 0; i < 2049; i++) {
            assertFalse(viewContract.provenPeriods(testDataSetId, i));
        }
        (uint64 maxProvingPeriod, uint256 challengeWindowSize,,) = viewContract.getPDPConfig();
        vm.startPrank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(testDataSetId, vm.getBlockNumber() + maxProvingPeriod, 100, "");
        vm.roll(vm.getBlockNumber() + maxProvingPeriod - challengeWindowSize);
        for (uint256 i = 0; i < 2049; i++) {
            assertFalse(viewContract.provenPeriods(testDataSetId, i));
            pdpServiceWithPayments.possessionProven(testDataSetId, 100, 12345, CHALLENGES_PER_PROOF);
            assertTrue(viewContract.provenPeriods(testDataSetId, i));

            vm.roll(vm.getBlockNumber() + challengeWindowSize);
            pdpServiceWithPayments.nextProvingPeriod(testDataSetId, vm.getBlockNumber() + maxProvingPeriod, 100, "");
            vm.roll(vm.getBlockNumber() + maxProvingPeriod - challengeWindowSize);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < 2049; i++) {
            assertTrue(viewContract.provenPeriods(testDataSetId, i));
        }
    }

    // Data Set Payment Termination Tests

    function testTerminateServiceLifecycle() public {
        console.log("=== Test: Data Set Payment Termination Lifecycle ===");

        // 0. Verify that DataSet with ID 1 is not found
        FilecoinWarmStorageService.DataSetStatus status = viewContract.getDataSetStatus(1);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.NotFound), "expected NotFound");

        // 1. Setup: Create a dataset with CDN enabled.
        console.log("1. Setting up: Creating dataset with service provider");

        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");

        // Prepare data set creation data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            payer: client,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true,
            1000e6, // rate allowance
            1000e6, // lockup allowance
            365 days // max lockup period
        );
        uint256 depositAmount = 100e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Create data set
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
        console.log("Created data set with ID:", dataSetId);

        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Active), "expected Active");

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, challengeEpoch, 100, "");

        assertEq(viewContract.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Active), "expected Active");

        // 3. Terminate payment
        console.log("\n3. Terminating payment rails");
        console.log("Current block:", block.number);
        vm.prank(client); // client terminates
        pdpServiceWithPayments.terminateService(dataSetId);

        // 4. Assertions
        // Check pdpEndEpoch is set
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertTrue(info.pdpEndEpoch > 0, "pdpEndEpoch should be set after termination");
        console.log("PDP termination successful. PDP end epoch:", info.pdpEndEpoch);
        // Check withCDN metadata is cleared
        (bool exists, string memory withCDN) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should not exist after termination");
        assertEq(withCDN, "", "withCDN value should be cleared for dataset");

        // check status is terminating
        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Terminating), "expected Terminating");

        // Ensure piecesAdded reverts
        console.log("\n4. Testing operations after termination");
        console.log("Testing piecesAdded - should revert (payment terminated)");
        vm.prank(address(mockPDPVerifier));
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        bytes32 pieceData = hex"010203";
        pieces[0] = Cids.CommPv2FromDigest(0, 4, pieceData);

        bytes memory addPiecesExtraData = abi.encode(FAKE_SIGNATURE, metadataKeys, metadataValues);
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetPaymentAlreadyTerminated.selector, dataSetId));
        pdpServiceWithPayments.piecesAdded(dataSetId, 0, pieces, addPiecesExtraData);
        console.log("[OK] piecesAdded correctly reverted after termination");

        console.log("Testing dataSetDeleted - should revert (in grace period)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRailsNotFinalized.selector, dataSetId, info.pdpEndEpoch));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        // Wait for payment end epoch to elapse
        console.log("\n5. Rolling past payment end epoch");
        console.log("Current block:", block.number);
        console.log("Rolling to block:", info.pdpEndEpoch + 1);
        vm.roll(info.pdpEndEpoch + 1);

        // check status is still Terminating as data set is not yet deleted from PDP
        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Terminating), "expected Terminating");

        // Ensure other functions also revert now
        console.log("\n6. Testing operations after payment end epoch");
        // piecesScheduledRemove
        console.log("Testing piecesScheduledRemove - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        bytes memory scheduleRemoveData = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.pdpEndEpoch, block.number
            )
        );
        mockPDPVerifier.piecesScheduledRemove(dataSetId, pieceIds, address(pdpServiceWithPayments), scheduleRemoveData);
        console.log("[OK] piecesScheduledRemove correctly reverted");

        // possessionProven
        console.log("Testing possessionProven - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.pdpEndEpoch, block.number
            )
        );
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        console.log("[OK] possessionProven correctly reverted");

        // nextProvingPeriod
        console.log("Testing nextProvingPeriod - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.pdpEndEpoch, block.number
            )
        );
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, block.number + maxProvingPeriod, 100, "");
        console.log("[OK] nextProvingPeriod correctly reverted");
        console.log("\n7. Testring dataSetDeleted");
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.NotFound), "expected NotFound");
        console.log("\n=== Test completed successfully! ===");
    }

    // CDN Service Termination Tests
    function testTerminateCDNServiceLifecycle() public {
        console.log("=== Test: CDN Payment Termination Lifecycle ===");

        // 1. Setup: Create a dataset with CDN enabled.
        console.log("1. Setting up: Creating dataset with service provider");

        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");

        // Prepare data set creation data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            payer: client,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true,
            1000e6, // rate allowance
            1000e6, // lockup allowance
            365 days // max lockup period
        );
        uint256 depositAmount = 100e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Create data set
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
        console.log("Created data set with ID:", dataSetId);

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, challengeEpoch, 100, "");

        assertEq(viewContract.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        // 3. Try to terminate payment from client address
        console.log("\n3. Terminating CDN payment rails from client address -- should revert");
        console.log("Current block:", block.number);
        vm.prank(client); // client terminates
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OnlyFilBeamControllerAllowed.selector, address(filBeamController), address(client)
            )
        );
        pdpServiceWithPayments.terminateCDNService(dataSetId);

        // 4. Try to terminate payment from FilBeam address
        console.log("\n4. Terminating CDN payment rails from FilBeam address -- should pass");
        console.log("Current block:", block.number);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        vm.prank(viewContract.filBeamControllerAddress()); // FilBeam terminates
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.CDNServiceTerminated(
            filBeamController, dataSetId, info.cacheMissRailId, info.cdnRailId
        );
        pdpServiceWithPayments.terminateCDNService(dataSetId);

        // 5. Assertions
        // Check if CDN data is cleared
        info = viewContract.getDataSet(dataSetId);
        (bool exists, string memory withCDN) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should not exist after termination");
        assertEq(withCDN, "", "withCDN value should be cleared for dataset");
        console.log("CDN service termination successful. Flag `withCDN` is cleared");

        Payments.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        Payments.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        Payments.RailView memory cdnRail = payments.getRail(info.cdnRailId);

        assertEq(pdpRail.endEpoch, 0, "PDP rail should NOT be terminated");
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should be terminated");
        assertTrue(cdnRail.endEpoch > 0, "CDN rail should be terminated");

        // Ensure future CDN service termination reverts
        vm.prank(filBeamController);
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        pdpServiceWithPayments.terminateCDNService(dataSetId);

        console.log("\n=== Test completed successfully! ===");
    }

    function testTerminateCDNService_checkPDPPaymentRate() public {
        // 1. Setup: Create a dataset with CDN enabled.
        console.log("1. Setting up: Creating dataset with service provider");

        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");

        // Prepare data set creation data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            payer: client,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true,
            1000e6, // rate allowance
            1000e6, // lockup allowance
            365 days // max lockup period
        );
        uint256 depositAmount = 100e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Create data set
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
        console.log("Created data set with ID:", dataSetId);

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, challengeEpoch, 100, "");

        assertEq(viewContract.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        Payments.RailView memory pdpRailPreTermination = payments.getRail(info.pdpRailId);

        // 3. Try to terminate payment from FilBeam address
        console.log("\n4. Terminating CDN payment rails from FilBeam address -- should pass");
        console.log("Current block:", block.number);
        vm.prank(viewContract.filBeamControllerAddress()); // FilBeam terminates
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.CDNServiceTerminated(
            filBeamController, dataSetId, info.cacheMissRailId, info.cdnRailId
        );
        pdpServiceWithPayments.terminateCDNService(dataSetId);

        // 4. Start new proving period and submit new proof
        console.log("\n4. Starting proving period and submitting proof");
        challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, challengeEpoch, 100, "");

        // Warp to challenge window
        provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // 5. Assert that payment rate has remained unchanged
        console.log("\n5. Assert that payment rate has remained unchanged");
        Payments.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(pdpRailPreTermination.paymentRate, pdpRail.paymentRate, "Payments rate should remain unchanged");

        console.log("\n=== Test completed successfully! ===");
    }

    function testTerminateCDNService_dataSetHasNoCDNEnabled() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Try to terminate CDN service
        console.log("Terminating CDN service for data set with -- should revert");
        console.log("Current block:", block.number);
        vm.prank(filBeamController);
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        pdpServiceWithPayments.terminateCDNService(dataSetId);
    }

    function testTransferCDNController() public {
        address newController = address(0xDEADBEEF);
        vm.prank(filBeamController);
        pdpServiceWithPayments.transferFilBeamController(newController);
        assertEq(viewContract.filBeamControllerAddress(), newController, "CDN controller should be updated");

        // Attempt transfer from old controller should revert
        vm.prank(filBeamController);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OnlyFilBeamControllerAllowed.selector, newController, filBeamController)
        );
        pdpServiceWithPayments.transferFilBeamController(address(0x1234));

        // Restore the original state
        vm.prank(newController);
        pdpServiceWithPayments.transferFilBeamController(filBeamController);
    }

    function testTransferCDNController_revertsIfZeroAddress() public {
        vm.prank(filBeamController);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilBeamController));
        pdpServiceWithPayments.transferFilBeamController(address(0));
    }

    // Data Set Metadata Storage Tests
    function testDataSetMetadataStorage() public {
        // Create a data set with metadata
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("label", "Test Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // read metadata key and value from contract
        (bool exists, string memory storedMetadata) = viewContract.getDataSetMetadata(dataSetId, metadataKeys[0]);
        (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);

        // Verify the stored metadata matches what we set
        assertTrue(exists, "Metadata key should exist");
        assertEq(storedMetadata, string(metadataValues[0]), "Stored metadata value should match");
        assertEq(storedKeys.length, 1, "Should have one metadata key");
        assertEq(storedKeys[0], metadataKeys[0], "Stored metadata key should match");
    }

    function testDataSetMetadataEmpty() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Verify no metadata is stored
        (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
        assertEq(storedKeys.length, 0, "Should have no metadata keys");
    }

    function testDataSetMetadataStorageMultipleKeys() public {
        // Create a data set with multiple metadata entries
        string[] memory metadataKeys = new string[](3);
        string[] memory metadataValues = new string[](3);

        metadataKeys[0] = "label";
        metadataValues[0] = "Test Metadata 1";

        metadataKeys[1] = "description";
        metadataValues[1] = "Test Description";

        metadataKeys[2] = "version";
        metadataValues[2] = "1.0.0";

        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Verify all metadata keys and values
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            (bool exists, string memory storedMetadata) = viewContract.getDataSetMetadata(dataSetId, metadataKeys[i]);
            assertTrue(exists, "Metadata key should exist");
            assertEq(
                storedMetadata,
                metadataValues[i],
                string(abi.encodePacked("Stored metadata for ", metadataKeys[i], " should match"))
            );
        }
        (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
        assertEq(storedKeys.length, metadataKeys.length, "Should have correct number of metadata keys");
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < storedKeys.length; j++) {
                if (keccak256(abi.encodePacked(storedKeys[j])) == keccak256(abi.encodePacked(metadataKeys[i]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string(abi.encodePacked("Metadata key ", metadataKeys[i], " should be stored")));
        }
    }

    function testMetadataQueries() public {
        // Test 1: Dataset with no metadata
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        uint256 dataSetId1 = createDataSetForClient(sp1, client, emptyKeys, emptyValues);

        // Test 2: Dataset with CDN metadata
        (string[] memory cdnKeys, string[] memory cdnValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId2 = createDataSetForClient(sp1, client, cdnKeys, cdnValues);

        // Test 3: Dataset with regular metadata
        string[] memory metaKeys = new string[](1);
        string[] memory metaValues = new string[](1);
        metaKeys[0] = "label";
        metaValues[0] = "test";
        uint256 dataSetId3 = createDataSetForClient(sp1, client, metaKeys, metaValues);

        // Test 4: Dataset with multiple metadata including CDN
        string[] memory bothKeys = new string[](2);
        string[] memory bothValues = new string[](2);
        bothKeys[0] = "label";
        bothValues[0] = "test";
        bothKeys[1] = "withCDN";
        bothValues[1] = "true";
        uint256 dataSetId4 = createDataSetForClient(sp1, client, bothKeys, bothValues);

        // Verify dataset with multiple metadata keys
        (bool exists1, string memory value) = viewContract.getDataSetMetadata(dataSetId4, "label");
        assertTrue(exists1, "label key should exist");
        assertEq(value, "test", "label value should be 'test' for dataset 4");
        (bool exists2,) = viewContract.getDataSetMetadata(dataSetId4, "withCDN");
        (, value) = viewContract.getDataSetMetadata(dataSetId4, "withCDN");
        assertTrue(exists2, "withCDN key should exist");
        assertEq(value, "true", "withCDN value should be 'true' for dataset 4");

        // Verify CDN metadata queries work correctly
        (bool exists3,) = viewContract.getDataSetMetadata(dataSetId2, "withCDN");
        (, value) = viewContract.getDataSetMetadata(dataSetId2, "withCDN");
        assertTrue(exists3, "withCDN key should exist");
        assertEq(value, "true", "withCDN value should be 'true' for dataset 2");

        (bool exists4,) = viewContract.getDataSetMetadata(dataSetId1, "withCDN");
        (, value) = viewContract.getDataSetMetadata(dataSetId1, "withCDN");
        assertFalse(exists4, "withCDN key should not exist");
        assertEq(value, "", "withCDN key should not exist in dataset 1");

        // Test getAllDataSetMetadata with no metadata
        (string[] memory keys, string[] memory values) = viewContract.getAllDataSetMetadata(dataSetId1);
        assertEq(keys.length, 0, "Should return empty arrays for no metadata");
        assertEq(values.length, 0, "Should return empty arrays for no metadata");

        // Test getAllDataSetMetadata with metadata
        (keys, values) = viewContract.getAllDataSetMetadata(dataSetId3);
        assertEq(keys.length, 1, "Should have one key");
        assertEq(keys[0], "label", "Key should be label");
        assertEq(values[0], "test", "Value should be test");
    }

    function testDataSetMetadataStorageMultipleDataSets() public {
        // Create multiple proof sets with metadata
        (string[] memory metadataKeys1, string[] memory metadataValues1) = _getSingleMetadataKV("label", "Data Set 1");
        (string[] memory metadataKeys2, string[] memory metadataValues2) = _getSingleMetadataKV("label", "Data Set 2");

        uint256 dataSetId1 = createDataSetForClient(sp1, client, metadataKeys1, metadataValues1);
        uint256 dataSetId2 = createDataSetForClient(sp2, client, metadataKeys2, metadataValues2);

        // Verify metadata for first data set
        (bool exists1, string memory storedMetadata1) = viewContract.getDataSetMetadata(dataSetId1, metadataKeys1[0]);
        assertTrue(exists1, "First dataset metadata key should exist");
        assertEq(storedMetadata1, string(metadataValues1[0]), "Stored metadata for first data set should match");

        // Verify metadata for second data set
        (bool exists2, string memory storedMetadata2) = viewContract.getDataSetMetadata(dataSetId2, metadataKeys2[0]);
        assertTrue(exists2, "Second dataset metadata key should exist");
        assertEq(storedMetadata2, string(metadataValues2[0]), "Stored metadata for second data set should match");
    }

    function testDataSetMetadataKeyLengthBoundaries() public {
        // Test key lengths: just below max (31), at max (32), and exceeding max (33)
        uint256[] memory keyLengths = new uint256[](3);
        keyLengths[0] = 31; // Just below max
        keyLengths[1] = 32; // At max
        keyLengths[2] = 33; // Exceeds max

        for (uint256 i = 0; i < keyLengths.length; i++) {
            uint256 keyLength = keyLengths[i];
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV(_makeStringOfLength(keyLength), "Test Metadata");

            if (keyLength <= 32) {
                // Should succeed for valid lengths
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify the metadata is stored correctly
                (bool exists, string memory storedMetadata) =
                    viewContract.getDataSetMetadata(dataSetId, metadataKeys[0]);
                assertTrue(exists, "Metadata key should exist");
                assertEq(
                    storedMetadata,
                    string(metadataValues[0]),
                    string.concat("Stored metadata value should match for key length ", Strings.toString(keyLength))
                );

                // Verify the metadata key is stored
                (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
                assertEq(storedKeys.length, 1, "Should have one metadata key");
                assertEq(
                    storedKeys[0],
                    metadataKeys[0],
                    string.concat("Stored metadata key should match for key length ", Strings.toString(keyLength))
                );
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(abi.encodeWithSelector(Errors.MetadataKeyExceedsMaxLength.selector, 0, 32, keyLength));
                mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
            }
        }
    }

    function testDataSetMetadataValueLengthBoundaries() public {
        // Test value lengths: just below max (127), at max (128), and exceeding max (129)
        uint256[] memory valueLengths = new uint256[](3);
        valueLengths[0] = 127; // Just below max
        valueLengths[1] = 128; // At max
        valueLengths[2] = 129; // Exceeds max

        for (uint256 i = 0; i < valueLengths.length; i++) {
            uint256 valueLength = valueLengths[i];
            string[] memory metadataKeys = new string[](1);
            string[] memory metadataValues = new string[](1);
            metadataKeys[0] = "key";
            metadataValues[0] = _makeStringOfLength(valueLength);

            if (valueLength <= 128) {
                // Should succeed for valid lengths
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify the metadata is stored correctly
                (bool exists, string memory storedMetadata) =
                    viewContract.getDataSetMetadata(dataSetId, metadataKeys[0]);
                assertTrue(exists, "Metadata key should exist");
                assertEq(
                    storedMetadata,
                    metadataValues[0],
                    string.concat("Stored metadata value should match for value length ", Strings.toString(valueLength))
                );

                // Verify the metadata key is stored
                (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
                assertEq(storedKeys.length, 1, "Should have one metadata key");
                assertEq(
                    storedKeys[0],
                    metadataKeys[0],
                    string.concat("Stored metadata key should match for value length ", Strings.toString(valueLength))
                );
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.MetadataValueExceedsMaxLength.selector, 0, 128, valueLength)
                );
                mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
            }
        }
    }

    function testDataSetMetadataKeyCountBoundaries() public {
        // Test key counts: just below max (MAX_KEYS_PER_DATASET - 1), at max, and exceeding max
        uint256[] memory keyCounts = new uint256[](3);
        keyCounts[0] = MAX_KEYS_PER_DATASET - 1; // Just below max
        keyCounts[1] = MAX_KEYS_PER_DATASET; // At max
        keyCounts[2] = MAX_KEYS_PER_DATASET + 1; // Exceeds max

        for (uint256 testIdx = 0; testIdx < keyCounts.length; testIdx++) {
            uint256 keyCount = keyCounts[testIdx];
            string[] memory metadataKeys = new string[](keyCount);
            string[] memory metadataValues = new string[](keyCount);

            for (uint256 i = 0; i < keyCount; i++) {
                metadataKeys[i] = string.concat("key", Strings.toString(i));
                metadataValues[i] = _makeStringOfLength(32);
            }

            if (keyCount <= MAX_KEYS_PER_DATASET) {
                // Should succeed for valid counts
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify all metadata keys and values
                for (uint256 i = 0; i < metadataKeys.length; i++) {
                    (bool exists, string memory storedMetadata) =
                        viewContract.getDataSetMetadata(dataSetId, metadataKeys[i]);
                    assertTrue(exists, string.concat("Key ", metadataKeys[i], " should exist"));
                    assertEq(
                        storedMetadata,
                        metadataValues[i],
                        string.concat("Stored metadata for ", metadataKeys[i], " should match")
                    );
                }

                (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
                assertEq(
                    storedKeys.length,
                    metadataKeys.length,
                    string.concat("Should have ", Strings.toString(keyCount), " metadata keys")
                );

                // Verify all keys are stored
                for (uint256 i = 0; i < metadataKeys.length; i++) {
                    bool found = false;
                    for (uint256 j = 0; j < storedKeys.length; j++) {
                        if (keccak256(bytes(storedKeys[j])) == keccak256(bytes(metadataKeys[i]))) {
                            found = true;
                            break;
                        }
                    }
                    assertTrue(found, string.concat("Metadata key ", metadataKeys[i], " should be stored"));
                }
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.TooManyMetadataKeys.selector, MAX_KEYS_PER_DATASET, keyCount)
                );
                mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
            }
        }
    }

    function setupDataSetWithPieceMetadata(
        uint256 pieceId,
        string[] memory keys,
        string[] memory values,
        bytes memory signature,
        address caller
    ) internal returns (PieceMetadataSetup memory setup) {
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        // Convert to per-piece format: each piece gets same metadata
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;

        // Encode extraData: (signature, metadataKeys, metadataValues)
        extraData = abi.encode(signature, allKeys, allValues);

        if (caller == address(mockPDPVerifier)) {
            vm.expectEmit(true, false, false, true);
            emit FilecoinWarmStorageService.PieceAdded(dataSetId, pieceId, pieceData[0], keys, values);
        } else {
            // Handle case where caller is not the PDP verifier
            vm.expectRevert(
                abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), caller)
            );
        }
        vm.prank(caller);
        pdpServiceWithPayments.piecesAdded(dataSetId, pieceId, pieceData, extraData);

        setup = PieceMetadataSetup({dataSetId: dataSetId, pieceId: pieceId, pieceData: pieceData, extraData: extraData});
    }

    function testPieceMetadataStorageAndRetrieval() public {
        // Test storing and retrieving piece metadata
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";

        PieceMetadataSetup memory setup =
            setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(mockPDPVerifier));

        // Verify piece metadata storage

        (string[] memory storedKeys, string[] memory storedValues) =
            viewContract.getAllPieceMetadata(setup.dataSetId, setup.pieceId);
        for (uint256 i = 0; i < values.length; i++) {
            assertEq(storedKeys[i], keys[i], string.concat("Stored key should match: ", keys[i]));
            assertEq(storedValues[i], values[i], string.concat("Stored value should match for key: ", keys[i]));
        }
    }

    function testPieceMetadataKeyLengthBoundaries() public {
        uint256 pieceId = 42;

        // Test key lengths: just below max (31), at max (32), and exceeding max (33)
        uint256[] memory keyLengths = new uint256[](3);
        keyLengths[0] = 31; // Just below max
        keyLengths[1] = 32; // At max
        keyLengths[2] = 33; // Exceeds max

        for (uint256 i = 0; i < keyLengths.length; i++) {
            uint256 keyLength = keyLengths[i];
            string[] memory keys = new string[](1);
            string[] memory values = new string[](1);
            keys[0] = _makeStringOfLength(keyLength);
            values[0] = "dog.jpg";

            // Create dataset
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV("label", "Test Root Metadata");
            uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

            Cids.Cid[] memory pieceData = new Cids.Cid[](1);
            pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

            // Convert to per-piece format
            string[][] memory allKeys = new string[][](1);
            string[][] memory allValues = new string[][](1);
            allKeys[0] = keys;
            allValues[0] = values;
            bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

            if (keyLength <= 32) {
                // Should succeed for valid lengths
                vm.expectEmit(true, false, false, true);
                emit FilecoinWarmStorageService.PieceAdded(dataSetId, pieceId + i, pieceData[0], keys, values);

                vm.prank(address(mockPDPVerifier));
                pdpServiceWithPayments.piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);

                // Verify piece metadata storage
                (bool exists, string memory storedMetadata) =
                    viewContract.getPieceMetadata(dataSetId, pieceId + i, keys[0]);
                assertTrue(exists, "Piece metadata key should exist");
                assertEq(
                    storedMetadata,
                    string(values[0]),
                    string.concat("Stored metadata should match for key length ", Strings.toString(keyLength))
                );

                (string[] memory storedKeys,) = viewContract.getAllPieceMetadata(dataSetId, pieceId + i);
                assertEq(storedKeys.length, 1, "Should have one metadata key");
                assertEq(
                    storedKeys[0],
                    keys[0],
                    string.concat("Stored key should match for key length ", Strings.toString(keyLength))
                );
            } else {
                // Should fail for exceeding max
                vm.expectRevert(abi.encodeWithSelector(Errors.MetadataKeyExceedsMaxLength.selector, 0, 32, keyLength));
                vm.prank(address(mockPDPVerifier));
                pdpServiceWithPayments.piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);
            }
        }
    }

    function testPieceMetadataValueLengthBoundaries() public {
        uint256 pieceId = 42;

        // Test value lengths: just below max (127), at max (128), and exceeding max (129)
        uint256[] memory valueLengths = new uint256[](3);
        valueLengths[0] = 127; // Just below max
        valueLengths[1] = 128; // At max
        valueLengths[2] = 129; // Exceeds max

        for (uint256 i = 0; i < valueLengths.length; i++) {
            uint256 valueLength = valueLengths[i];
            string[] memory keys = new string[](1);
            string[] memory values = new string[](1);
            keys[0] = "filename";
            values[0] = _makeStringOfLength(valueLength);

            // Create dataset
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV("label", "Test Root Metadata");
            uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

            Cids.Cid[] memory pieceData = new Cids.Cid[](1);
            pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

            // Convert to per-piece format
            string[][] memory allKeys = new string[][](1);
            string[][] memory allValues = new string[][](1);
            allKeys[0] = keys;
            allValues[0] = values;
            bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

            if (valueLength <= 128) {
                // Should succeed for valid lengths
                vm.expectEmit(true, false, false, true);
                emit FilecoinWarmStorageService.PieceAdded(dataSetId, pieceId + i, pieceData[0], keys, values);

                vm.prank(address(mockPDPVerifier));
                pdpServiceWithPayments.piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);

                // Verify piece metadata storage
                (bool exists, string memory storedMetadata) =
                    viewContract.getPieceMetadata(dataSetId, pieceId + i, keys[0]);
                assertTrue(exists, "Piece metadata key should exist");
                assertEq(
                    storedMetadata,
                    string(values[0]),
                    string.concat("Stored metadata should match for value length ", Strings.toString(valueLength))
                );

                (string[] memory storedKeys,) = viewContract.getAllPieceMetadata(dataSetId, pieceId + i);
                assertEq(storedKeys.length, 1, "Should have one metadata key");
                assertEq(storedKeys[0], keys[0], "Stored key should match 'filename'");
            } else {
                // Should fail for exceeding max
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.MetadataValueExceedsMaxLength.selector, 0, 128, valueLength)
                );
                vm.prank(address(mockPDPVerifier));
                pdpServiceWithPayments.piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);
            }
        }
    }

    function testPieceMetadataKeyCountBoundaries() public {
        uint256 pieceId = 42;

        // Test key counts: just below max, at max, and exceeding max
        uint256[] memory keyCounts = new uint256[](3);
        keyCounts[0] = MAX_KEYS_PER_PIECE - 1; // Just below max (4)
        keyCounts[1] = MAX_KEYS_PER_PIECE; // At max (5)
        keyCounts[2] = MAX_KEYS_PER_PIECE + 1; // Exceeds max (6)

        for (uint256 testIdx = 0; testIdx < keyCounts.length; testIdx++) {
            uint256 keyCount = keyCounts[testIdx];
            string[] memory keys = new string[](keyCount);
            string[] memory values = new string[](keyCount);

            for (uint256 i = 0; i < keyCount; i++) {
                keys[i] = string.concat("key", Strings.toString(i));
                values[i] = string.concat("value", Strings.toString(i));
            }

            // Create dataset
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV("label", "Test Root Metadata");
            uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

            Cids.Cid[] memory pieceData = new Cids.Cid[](1);
            pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

            // Convert to per-piece format
            string[][] memory allKeys = new string[][](1);
            string[][] memory allValues = new string[][](1);
            allKeys[0] = keys;
            allValues[0] = values;
            bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

            if (keyCount <= MAX_KEYS_PER_PIECE) {
                // Should succeed for valid counts
                vm.expectEmit(true, false, false, true);
                emit FilecoinWarmStorageService.PieceAdded(dataSetId, pieceId + testIdx, pieceData[0], keys, values);

                vm.prank(address(mockPDPVerifier));
                pdpServiceWithPayments.piecesAdded(dataSetId, pieceId + testIdx, pieceData, encodedData);

                // Verify piece metadata storage
                for (uint256 i = 0; i < keys.length; i++) {
                    (bool exists, string memory storedMetadata) =
                        viewContract.getPieceMetadata(dataSetId, pieceId + testIdx, keys[i]);
                    assertTrue(exists, string.concat("Key ", keys[i], " should exist"));
                    assertEq(
                        storedMetadata, values[i], string.concat("Stored metadata should match for key: ", keys[i])
                    );
                }

                (string[] memory storedKeys,) = viewContract.getAllPieceMetadata(dataSetId, pieceId + testIdx);
                assertEq(
                    storedKeys.length,
                    keys.length,
                    string.concat("Should have ", Strings.toString(keyCount), " metadata keys")
                );
            } else {
                // Should fail for exceeding max
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.TooManyMetadataKeys.selector, MAX_KEYS_PER_PIECE, keyCount)
                );
                vm.prank(address(mockPDPVerifier));
                pdpServiceWithPayments.piecesAdded(dataSetId, pieceId + testIdx, pieceData, encodedData);
            }
        }
    }

    function testPieceMetadataForSameKeyCannotRewrite() public {
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";

        PieceMetadataSetup memory setup =
            setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(mockPDPVerifier));

        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateMetadataKey.selector, setup.dataSetId, keys[0]));
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(setup.dataSetId, setup.pieceId, setup.pieceData, setup.extraData);
    }

    function testPieceMetadataCannotBeAddedByNonPDPVerifier() public {
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";

        setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(this));
    }

    function testPieceMetadataCannotBeCalledWithMoreValues() public {
        uint256 pieceId = 42;

        // Set metadata for the piece with more values than keys
        string[] memory keys = new string[](2);
        string[] memory values = new string[](3); // One extra value

        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";
        values[2] = "extraValue"; // Extra value

        // Create dataset first
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        // Convert to per-piece format with mismatched arrays
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;

        // Encode extraData with mismatched keys/values
        bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

        // Expect revert due to key/value mismatch
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MetadataKeyAndValueLengthMismatch.selector, keys.length, values.length)
        );
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(dataSetId, pieceId, pieceData, encodedData);
    }

    function testPieceMetadataCannotBeCalledWithMoreKeys() public {
        uint256 pieceId = 42;

        // Set metadata for the piece with more keys than values
        string[] memory keys = new string[](3); // One extra key
        string[] memory values = new string[](2);

        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";
        keys[2] = "extraKey"; // Extra key

        // Create dataset first
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        // Convert to per-piece format with mismatched arrays
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;

        // Encode extraData with mismatched keys/values
        bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

        // Expect revert due to key/value mismatch
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MetadataKeyAndValueLengthMismatch.selector, keys.length, values.length)
        );
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(dataSetId, pieceId, pieceData, encodedData);
    }

    function testGetPieceMetadata() public {
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";

        PieceMetadataSetup memory setup =
            setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(mockPDPVerifier));

        // Test getPieceMetadata for existing keys
        (bool exists1, string memory filename) =
            viewContract.getPieceMetadata(setup.dataSetId, setup.pieceId, "filename");
        assertTrue(exists1, "filename key should exist");
        assertEq(filename, "dog.jpg", "Filename metadata should match");

        (bool exists2, string memory contentType) =
            viewContract.getPieceMetadata(setup.dataSetId, setup.pieceId, "contentType");
        assertTrue(exists2, "contentType key should exist");
        assertEq(contentType, "image/jpeg", "Content type metadata should match");

        // Test getPieceMetadata for non-existent key - this is the important false case!
        (bool exists3, string memory nonExistentKey) =
            viewContract.getPieceMetadata(setup.dataSetId, setup.pieceId, "nonExistentKey");
        assertFalse(exists3, "Non-existent key should not exist");
        assertEq(bytes(nonExistentKey).length, 0, "Should return empty string for non-existent key");
    }

    function testGetPieceMetdataAllKeys() public {
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";

        PieceMetadataSetup memory setup =
            setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(mockPDPVerifier));

        // Test getPieceMetadataKeys
        (string[] memory storedKeys, string[] memory storedValues) =
            viewContract.getAllPieceMetadata(setup.dataSetId, setup.pieceId);
        assertEq(storedKeys.length, keys.length, "Should return correct number of metadata keys");
        for (uint256 i = 0; i < keys.length; i++) {
            assertEq(storedKeys[i], keys[i], string.concat("Stored key should match: ", keys[i]));
            assertEq(storedValues[i], values[i], string.concat("Stored value should match for key: ", keys[i]));
        }
    }

    function testGetPieceMetadata_NonExistentDataSet() public view {
        uint256 nonExistentDataSetId = 999;
        uint256 nonExistentPieceId = 43;

        // Attempt to get metadata for a non-existent proof set
        (bool exists, string memory filename) =
            viewContract.getPieceMetadata(nonExistentDataSetId, nonExistentPieceId, "filename");
        assertFalse(exists, "Key should not exist for non-existent data set");
        assertTrue(bytes(filename).length == 0, "Should return empty string");
        assertEq(bytes(filename).length, 0, "Should return empty string for non-existent proof set");
    }

    function testGetPieceMetadata_NonExistentKey() public {
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](1);
        string[] memory values = new string[](1);
        keys[0] = "filename";
        values[0] = "dog.jpg";

        PieceMetadataSetup memory setup =
            setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(mockPDPVerifier));

        // Attempt to get metadata for a non-existent key
        (bool exists, string memory nonExistentMetadata) =
            viewContract.getPieceMetadata(setup.dataSetId, setup.pieceId, "nonExistentKey");
        assertFalse(exists, "Non-existent key should not exist");
        assertTrue(bytes(nonExistentMetadata).length == 0, "Should return empty string");
        assertEq(bytes(nonExistentMetadata).length, 0, "Should return empty string for non-existent key");
    }

    function testPieceMetadataPerPieceDifferentMetadata() public {
        // Test different metadata for multiple pieces
        uint256 firstPieceId = 100;
        uint256 numPieces = 3;

        // Create dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Create multiple pieces with different metadata
        Cids.Cid[] memory pieceData = new Cids.Cid[](numPieces);
        for (uint256 i = 0; i < numPieces; i++) {
            pieceData[i] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file", i)));
        }

        // Prepare different metadata for each piece
        string[][] memory allKeys = new string[][](numPieces);
        string[][] memory allValues = new string[][](numPieces);

        // Piece 0: filename and contentType
        allKeys[0] = new string[](2);
        allValues[0] = new string[](2);
        allKeys[0][0] = "filename";
        allValues[0][0] = "document.pdf";
        allKeys[0][1] = "contentType";
        allValues[0][1] = "application/pdf";

        // Piece 1: filename, size, and compression
        allKeys[1] = new string[](3);
        allValues[1] = new string[](3);
        allKeys[1][0] = "filename";
        allValues[1][0] = "image.jpg";
        allKeys[1][1] = "size";
        allValues[1][1] = "1024000";
        allKeys[1][2] = "compression";
        allValues[1][2] = "jpeg";

        // Piece 2: just filename
        allKeys[2] = new string[](1);
        allValues[2] = new string[](1);
        allKeys[2][0] = "filename";
        allValues[2][0] = "data.json";

        bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

        // Expect events for each piece with their specific metadata
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.PieceAdded(dataSetId, firstPieceId, pieceData[0], allKeys[0], allValues[0]);
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.PieceAdded(dataSetId, firstPieceId + 1, pieceData[1], allKeys[1], allValues[1]);
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.PieceAdded(dataSetId, firstPieceId + 2, pieceData[2], allKeys[2], allValues[2]);

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);

        // Verify metadata for piece 0
        (bool e0, string memory v0) = viewContract.getPieceMetadata(dataSetId, firstPieceId, "filename");
        assertTrue(e0, "filename key should exist");
        assertEq(v0, "document.pdf", "Piece 0 filename should match");

        (bool e1, string memory v1) = viewContract.getPieceMetadata(dataSetId, firstPieceId, "contentType");
        assertTrue(e1, "contentType key should exist");
        assertEq(v1, "application/pdf", "Piece 0 contentType should match");

        // Verify metadata for piece 1
        (bool e2, string memory v2) = viewContract.getPieceMetadata(dataSetId, firstPieceId + 1, "filename");
        assertTrue(e2, "filename key should exist");
        assertEq(v2, "image.jpg", "Piece 1 filename should match");

        (bool e3, string memory v3) = viewContract.getPieceMetadata(dataSetId, firstPieceId + 1, "size");
        assertTrue(e3, "size key should exist");
        assertEq(v3, "1024000", "Piece 1 size should match");

        (bool e4, string memory v4) = viewContract.getPieceMetadata(dataSetId, firstPieceId + 1, "compression");
        assertTrue(e4, "compression key should exist");
        assertEq(v4, "jpeg", "Piece 1 compression should match");

        // Verify metadata for piece 2
        (bool e5, string memory v5) = viewContract.getPieceMetadata(dataSetId, firstPieceId + 2, "filename");
        assertTrue(e5, "filename key should exist");
        assertEq(v5, "data.json", "Piece 2 filename should match");

        // Verify getAllPieceMetadata returns correct data for each piece
        (string[] memory keys0, string[] memory values0) = viewContract.getAllPieceMetadata(dataSetId, firstPieceId);
        assertEq(keys0.length, 2, "Piece 0 should have 2 metadata keys");

        (string[] memory keys1, string[] memory values1) = viewContract.getAllPieceMetadata(dataSetId, firstPieceId + 1);
        assertEq(keys1.length, 3, "Piece 1 should have 3 metadata keys");

        (string[] memory keys2, string[] memory values2) = viewContract.getAllPieceMetadata(dataSetId, firstPieceId + 2);
        assertEq(keys2.length, 1, "Piece 2 should have 1 metadata key");
    }

    function testEmptyStringMetadata() public {
        // Create data set with empty string metadata
        string[] memory metadataKeys = new string[](2);
        metadataKeys[0] = "withCDN";
        metadataKeys[1] = "description";

        string[] memory metadataValues = new string[](2);
        metadataValues[0] = ""; // Empty string for withCDN
        metadataValues[1] = "Test dataset"; // Non-empty for description

        // Create dataset using the helper function
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Test that empty string is stored and retrievable
        (bool existsCDN, string memory withCDN) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(existsCDN, "withCDN key should exist");
        assertEq(withCDN, "", "Empty string should be stored and retrievable");

        // Test that non-existent key returns false
        (bool existsNonExistent, string memory nonExistent) =
            viewContract.getDataSetMetadata(dataSetId, "nonExistentKey");
        assertFalse(existsNonExistent, "Non-existent key should not exist");
        assertEq(nonExistent, "", "Non-existent key returns empty string");

        // Distinguish between these two cases:
        // - Empty value: exists=true, value=""
        // - Non-existent: exists=false, value=""

        // Also test for piece metadata with empty strings
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("test_piece_1")));

        string[] memory pieceKeys = new string[](2);
        pieceKeys[0] = "filename";
        pieceKeys[1] = "contentType";

        string[] memory pieceValues = new string[](2);
        pieceValues[0] = ""; // Empty filename
        pieceValues[1] = "application/octet-stream";

        makeSignaturePass(client);
        uint256 pieceId = 0; // First piece in this dataset
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, pieceId, pieces, FAKE_SIGNATURE, pieceKeys, pieceValues
        );

        // Test empty string in piece metadata
        (bool existsFilename, string memory filename) = viewContract.getPieceMetadata(dataSetId, pieceId, "filename");
        assertTrue(existsFilename, "filename key should exist");
        assertEq(filename, "", "Empty filename should be stored");

        (bool existsSize, string memory nonExistentPieceMeta) =
            viewContract.getPieceMetadata(dataSetId, pieceId, "size");
        assertFalse(existsSize, "size key should not exist");
        assertEq(nonExistentPieceMeta, "", "Non-existent piece metadata key returns empty string");
    }

    function testPieceMetadataArrayMismatchErrors() public {
        uint256 pieceId = 42;

        // Create dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Create 2 pieces
        Cids.Cid[] memory pieceData = new Cids.Cid[](2);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file1")));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file2")));

        // Test case 1: Wrong number of key arrays (only 1 for 2 pieces)
        string[][] memory wrongKeys = new string[][](1);
        string[][] memory correctValues = new string[][](2);
        wrongKeys[0] = new string[](1);
        wrongKeys[0][0] = "filename";
        correctValues[0] = new string[](1);
        correctValues[0][0] = "file1.txt";
        correctValues[1] = new string[](1);
        correctValues[1][0] = "file2.txt";

        bytes memory encodedData1 = abi.encode(FAKE_SIGNATURE, wrongKeys, correctValues);

        vm.expectRevert(abi.encodeWithSelector(Errors.MetadataArrayCountMismatch.selector, 1, 2));
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(dataSetId, pieceId, pieceData, encodedData1);

        // Test case 2: Wrong number of value arrays (only 1 for 2 pieces)
        string[][] memory correctKeys = new string[][](2);
        string[][] memory wrongValues = new string[][](1);
        correctKeys[0] = new string[](1);
        correctKeys[0][0] = "filename";
        correctKeys[1] = new string[](1);
        correctKeys[1][0] = "filename";
        wrongValues[0] = new string[](1);
        wrongValues[0][0] = "file1.txt";

        bytes memory encodedData2 = abi.encode(FAKE_SIGNATURE, correctKeys, wrongValues);

        vm.expectRevert(abi.encodeWithSelector(Errors.MetadataArrayCountMismatch.selector, 1, 2));
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(dataSetId, pieceId, pieceData, encodedData2);
    }

    function testPieceMetadataEmptyMetadataForAllPieces() public {
        uint256 firstPieceId = 200;
        uint256 numPieces = 2;

        // Create dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Create multiple pieces with no metadata
        Cids.Cid[] memory pieceData = new Cids.Cid[](numPieces);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file1")));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file2")));

        // Create empty metadata arrays for each piece
        string[][] memory allKeys = new string[][](numPieces); // Empty arrays
        string[][] memory allValues = new string[][](numPieces); // Empty arrays

        bytes memory encodedData = abi.encode(FAKE_SIGNATURE, allKeys, allValues);

        // Expect events with empty metadata arrays
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.PieceAdded(dataSetId, firstPieceId, pieceData[0], allKeys[0], allValues[0]);
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.PieceAdded(dataSetId, firstPieceId + 1, pieceData[1], allKeys[1], allValues[1]);

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);

        // Verify no metadata is stored
        (string[] memory keys0, string[] memory values0) = viewContract.getAllPieceMetadata(dataSetId, firstPieceId);
        assertEq(keys0.length, 0, "Piece 0 should have no metadata keys");
        assertEq(values0.length, 0, "Piece 0 should have no metadata values");

        (string[] memory keys1, string[] memory values1) = viewContract.getAllPieceMetadata(dataSetId, firstPieceId + 1);
        assertEq(keys1.length, 0, "Piece 1 should have no metadata keys");
        assertEq(values1.length, 0, "Piece 1 should have no metadata values");

        // Verify getting non-existent keys returns empty strings
        (bool exists, string memory nonExistentValue) = viewContract.getPieceMetadata(dataSetId, firstPieceId, "anykey");
        assertFalse(exists, "Non-existent key should return false");
        assertEq(bytes(nonExistentValue).length, 0, "Non-existent key should return empty string");
    }

    function testRailTerminated_RevertsIfCallerNotPaymentsContract() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectRevert(abi.encodeWithSelector(Errors.CallerNotPayments.selector, address(payments), address(sp1)));
        vm.prank(sp1);
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);
    }

    function testRailTerminated_RevertsIfTerminatorNotServiceContract() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectRevert(abi.encodeWithSelector(Errors.ServiceContractMustTerminateRail.selector));
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(0xdead), 123);
    }

    function testRailTerminated_RevertsIfRailNotAssociated() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetNotFoundForRail.selector, 1337));
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(1337, address(pdpServiceWithPayments), 123);
    }

    function testRailTerminated_SetsPdpEndEpochAndEmitsEvent() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.PDPPaymentTerminated(dataSetId, 123, info.pdpRailId);
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);
        // CDN rails don't track endEpoch in DataSetInfo
    }

    function testRailTerminated_DoesNotOverwritePdpEndEpoch() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.PDPPaymentTerminated(dataSetId, 123, info.pdpRailId);
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);

        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 321);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);
    }

    function testCreateDataSetWithCDN_VerifyDefaultBehavior() public {
        // Test that CDN datasets now have lockup values: 0.7 USDFC for CDN, 0.3 USDFC for cache-miss
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");

        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            payer: client,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days);
        uint256 depositAmount = 1e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect CDNPaymentRailsToppedUp event when creating the data set with CDN enabled
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(1, defaultCDNLockup, defaultCacheMissLockup);

        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Verify CDN rails were created with default zero lockup
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertTrue(dataSet.cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(dataSet.cdnRailId > 0, "CDN Rail ID should be non-zero");

        // Verify lockup amounts are set to the expected values
        Payments.RailView memory cacheMissRail = payments.getRail(dataSet.cacheMissRailId);
        Payments.RailView memory cdnRail = payments.getRail(dataSet.cdnRailId);
        assertEq(cacheMissRail.lockupFixed, defaultCacheMissLockup, "Cache miss lockup should be 0.3 USDFC");
        assertEq(cdnRail.lockupFixed, defaultCDNLockup, "CDN lockup should be 0.7 USDFC");
        // Verify that CDN rails have no validator
        assertEq(cacheMissRail.validator, address(0), "Cache miss rail should have no validator");
        assertEq(cdnRail.validator, address(0), "CDN rail should have no validator");
    }

    function testCreateDataSetWithCDN_EmitsCDNPaymentRailsToppedUp() public {
        // Test that creating a dataset with CDN enabled emits CDNPaymentRailsToppedUp event
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");

        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            payer: client,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days);
        uint256 depositAmount = 1e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect the CDNPaymentRailsToppedUp event with correct parameters
        // Event signature: CDNPaymentRailsToppedUp(uint256 indexed dataSetId, uint256 totalCdnLockup, uint256 totalCacheMissLockup)
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            1, // dataSetId will be 1 (first dataset created)
            defaultCDNLockup, // Should be 0.7 USDFC
            defaultCacheMissLockup // Should be 0.3 USDFC
        );

        // Create the dataset
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Verify the dataset was created with CDN rails
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertTrue(dataSet.cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(dataSet.cdnRailId > 0, "CDN Rail ID should be non-zero");
    }

    function testCreateDataSetWithoutCDN_NoCDNPaymentRailsToppedUpEvent() public {
        // Test that creating a dataset without CDN does not emit CDNPaymentRailsToppedUp event
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);

        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            payer: client,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days);
        uint256 depositAmount = 10e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Record logs to verify CDNPaymentRailsToppedUp event is NOT emitted
        vm.recordLogs();

        // Create the dataset
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Check that CDNPaymentRailsToppedUp event was NOT emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 cdnEventSignature = keccak256("CDNPaymentRailsToppedUp(uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(
                logs[i].topics[0], cdnEventSignature, "CDNPaymentRailsToppedUp should not be emitted without CDN"
            );
        }

        // Verify the dataset was created without CDN rails
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertEq(dataSet.cacheMissRailId, 0, "Cache Miss Rail ID should be zero");
        assertEq(dataSet.cdnRailId, 0, "CDN Rail ID should be zero");
    }

    // Tests for settleFilBeamPaymentRails function
    function testSettleFilBeamPaymentRails_BothAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Top up the rails first to allow for settlement
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnAmount, defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Now settle the payments
        vm.expectEmit(true, false, false, true, address(payments));
        emit Payments.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true, address(payments));
        emit Payments.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_OnlyCdnAmount() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 75000;
        uint256 cacheMissAmount = 0;

        // Top up only the CDN rail
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnAmount, defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Now settle only the CDN payment
        vm.expectEmit(true, false, false, true, address(payments));
        emit Payments.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_OnlyCacheMissAmount() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 0;
        uint256 cacheMissAmount = 30000;

        // Top up only the cache miss rail
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnAmount, defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Now settle only the cache miss payment
        vm.expectEmit(true, false, false, true, address(payments));
        emit Payments.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_ZeroAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, 0, 0);
    }

    function testSettleFilBeamPaymentRails_OnlyfilBeamController() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Expecting the payment to fail due to insufficient lockup (OneTimePaymentExceedsLockup error)
        // Try to settle more than the initial lockup
        uint256 cdnAmount = defaultCDNLockup + 50000; // More than initial 0.7 USDFC
        uint256 cacheMissAmount = defaultCacheMissLockup + 25000; // More than initial 0.3 USDFC

        vm.expectRevert();
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_RevertIfNotController() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyFilBeamControllerAllowed.selector, filBeamController, client));
        vm.prank(client);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, 50000, 25000);

        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyFilBeamControllerAllowed.selector, filBeamController, sp1));
        vm.prank(sp1);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, 50000, 25000);
    }

    function testSettleFilBeamPaymentRails_InvalidDataSetId() public {
        uint256 invalidDataSetId = 999999;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetId.selector, invalidDataSetId));
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(invalidDataSetId, 50000, 25000);
    }

    function testSettleFilBeamPaymentRails_DataSetWithoutCDN() public {
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, emptyKeys, emptyValues);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetId.selector, dataSetId));
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, 50000, 25000);
    }

    function testSettleFilBeamPaymentRails_DataSetWithEmptyCDNMetadata() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Top up the rails first
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnAmount, defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Empty CDN metadata still creates CDN rails and can be settled after top-up
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_EmitsCorrectEvents() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 100000;
        uint256 cacheMissAmount = 50000;

        // Top up the rails first
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnAmount, defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Verify correct events are emitted
        vm.expectEmit(true, false, false, true, address(payments));
        emit Payments.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true, address(payments));
        emit Payments.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_NoEventsForZeroAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        vm.recordLogs();
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, 0, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(
                logs[i].topics[0] == Payments.RailOneTimePaymentProcessed.selector,
                "RailOneTimePaymentProcessed should not be emitted for zero amounts"
            );
        }
    }

    function testSettleFilBeamPaymentRails_ProcessesPaymentsCorrectly() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 75000;
        uint256 cacheMissAmount = 35000;

        // Top up the rails first
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnAmount, defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Verify rails have correct lockup before settlement (initial + top-up)
        Payments.RailView memory cdnRailBefore = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRailBefore = payments.getRail(info.cacheMissRailId);
        assertEq(
            cdnRailBefore.lockupFixed,
            defaultCDNLockup + cdnAmount,
            "CDN rail should have lockup equal to initial plus top-up"
        );
        assertEq(
            cacheMissRailBefore.lockupFixed,
            defaultCacheMissLockup + cacheMissAmount,
            "Cache miss rail should have lockup equal to initial plus top-up"
        );

        // Process the payments
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    // Tests for insufficient lockup failures
    function testSettleFilBeamPaymentRails_FailsWithInsufficientLockup() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Try to settle more than the initial lockup amount
        uint256 cdnAmount = defaultCDNLockup + 50000; // More than initial 0.7 USDFC
        uint256 cacheMissAmount = defaultCacheMissLockup + 10000; // More than initial 0.3 USDFC

        // Attempt to settle without additional top-up (only initial lockup available)
        // Expecting OneTimePaymentExceedsLockup error
        vm.expectRevert();
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_FailsWhenLockupLessThanSettlement() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Top up with smaller amounts than we'll try to settle
        uint256 topUpCdn = 10000;
        uint256 topUpCacheMiss = 5000;
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, topUpCdn, topUpCacheMiss);

        // Try to settle with amounts larger than initial plus top-up
        uint256 cdnAmount = defaultCDNLockup + topUpCdn + 50000; // More than available lockup
        uint256 cacheMissAmount = defaultCacheMissLockup + topUpCacheMiss + 10000; // More than available lockup

        // Should fail due to insufficient lockup
        vm.expectRevert();
        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_AfterTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up CDN rails with sufficient funds
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 100000, 50000);

        // Terminate the CDN service (this removes withCDN metadata)
        vm.prank(filBeamController);
        pdpServiceWithPayments.terminateCDNService(dataSetId);

        // Verify withCDN metadata is removed
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should be removed after termination");

        // Should still be able to settle CDN payment rails after termination
        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Expect the correct events to be emitted for successful settlement
        vm.expectEmit(true, false, false, true);
        emit Payments.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true);
        emit Payments.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_AfterServiceTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up CDN rails with sufficient funds
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 100000, 50000);

        // Terminate the entire service (this also removes withCDN metadata and terminates CDN rails)
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Verify withCDN metadata is removed
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should be removed after service termination");

        // Should still be able to settle CDN payment rails after termination
        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Expect the correct events to be emitted for successful settlement
        vm.expectEmit(true, false, false, true);
        emit Payments.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true);
        emit Payments.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    // Tests for topUpCDNPaymentRails function
    function testTopUpCDNPaymentRails_Success() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        // Verify initial lockup matches expected values
        Payments.RailView memory cdnRailBefore = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRailBefore = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRailBefore.lockupFixed, defaultCDNLockup, "CDN rail should start with 0.7 USDFC lockup");
        assertEq(
            cacheMissRailBefore.lockupFixed,
            defaultCacheMissLockup,
            "Cache miss rail should start with 0.3 USDFC lockup"
        );

        // Top up the rails
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Verify lockup increased by top-up amount
        Payments.RailView memory cdnRailAfter = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRailAfter = payments.getRail(info.cacheMissRailId);
        assertEq(
            cdnRailAfter.lockupFixed, defaultCDNLockup + cdnTopUp, "CDN rail lockup should equal initial plus top-up"
        );
        assertEq(
            cacheMissRailAfter.lockupFixed,
            defaultCacheMissLockup + cacheMissTopUp,
            "Cache miss rail lockup should equal initial plus top-up"
        );
    }

    function testTopUpCDNPaymentRails_OnlyPayerCanTopUp() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Try to top up as non-payer
        vm.expectRevert();
        vm.prank(sp1);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 1000, 1000);

        // Try to top up as another random address
        vm.expectRevert();
        vm.prank(address(0x123));
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 1000, 1000);

        // Should work as payer
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + 1000, defaultCacheMissLockup + 1000
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 1000, 1000);
    }

    function testTopUpCDNPaymentRails_RequiresCDNEnabled() public {
        // Create dataset without CDN
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, emptyKeys, emptyValues);

        // Should fail because CDN is not enabled
        vm.expectRevert();
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 1000, 1000);
    }

    function testTopUpCDNPaymentRails_IncrementalTopUps() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // First top-up
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + 1000, defaultCacheMissLockup + 500
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 1000, 500);

        Payments.RailView memory cdnRail1 = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRail1 = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRail1.lockupFixed, defaultCDNLockup + 1000);
        assertEq(cacheMissRail1.lockupFixed, defaultCacheMissLockup + 500);

        // Second top-up (should be additive)
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + 3000, defaultCacheMissLockup + 2000
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 2000, 1500);

        Payments.RailView memory cdnRail2 = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRail2 = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRail2.lockupFixed, defaultCDNLockup + 3000, "CDN lockup should be initial plus cumulative top-ups");
        assertEq(
            cacheMissRail2.lockupFixed,
            defaultCacheMissLockup + 2000,
            "Cache miss lockup should be initial plus cumulative top-ups"
        );
    }

    function testTopUpCDNPaymentRails_ZeroAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up with zero amounts (should revert with InvalidTopUpAmount error)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTopUpAmount.selector, dataSetId));
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 0, 0);

        // Verify lockup remains at initial values
        Payments.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRail.lockupFixed, defaultCDNLockup, "CDN lockup should remain at initial 0.7 USDFC");
        assertEq(
            cacheMissRail.lockupFixed, defaultCacheMissLockup, "Cache miss lockup should remain at initial 0.3 USDFC"
        );
    }

    function testTopUpCDNPaymentRails_InvalidDataSetId() public {
        uint256 invalidDataSetId = 99999999999999999;

        vm.expectRevert();
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(invalidDataSetId, 1000, 1000);
    }

    function testTopUpCDNPaymentRails_RevertsAfterCDNTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Top up initially (should succeed)
        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Terminate CDN service
        vm.prank(filBeamController);
        pdpServiceWithPayments.terminateCDNService(dataSetId);

        // Attempt to top up again (should fail because withCDN metadata was removed)
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);
    }

    function testTopUpCDNPaymentRails_RevertsAfterServiceTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Top up initially (should succeed)
        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Terminate entire service (including CDN rails)
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Attempt to top up again (should fail because withCDN metadata was removed)
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);
    }

    function testTopUpCDNPaymentRails_RevertsForIndividuallyTerminatedRails() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up initially (should succeed)
        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Directly terminate CDN rail through Payments contract (simulating edge case)
        // Note: The service contract is the controller of the rails
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cdnRailId);

        // Attempt to top up only CDN rail (should fail since CDN rail is terminated)
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, 0);

        // Attempt to top up only cache miss rail (should also fail since CDN rail is terminated)
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 0, cacheMissTopUp);

        // Now terminate cache miss rail too
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cacheMissRailId);

        // Attempt to top up both (should fail on first check)
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);
    }

    function testTopUpCDNPaymentRails_SucceedsBeforeTermination() public {
        // Positive test to ensure normal functionality still works
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        // Multiple top-ups should all succeed before termination
        vm.startPrank(client);

        // First top-up
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Second top-up
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp * 3, defaultCacheMissLockup + cacheMissTopUp * 3
        );
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp * 2, cacheMissTopUp * 2);

        // Third top-up (only CDN)
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp * 4, defaultCacheMissLockup + cacheMissTopUp * 3
        );
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, cdnTopUp, 0);

        // Fourth top-up (only cache miss)
        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.CDNPaymentRailsToppedUp(
            dataSetId, defaultCDNLockup + cdnTopUp * 4, defaultCacheMissLockup + cacheMissTopUp * 4
        );
        pdpServiceWithPayments.topUpCDNPaymentRails(dataSetId, 0, cacheMissTopUp);

        vm.stopPrank();

        // Verify rails are still active and have correct lockup amounts
        Payments.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        Payments.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);

        // Rails should not be terminated
        assertEq(cdnRail.endEpoch, 0, "CDN rail should not be terminated");
        assertEq(cacheMissRail.endEpoch, 0, "Cache miss rail should not be terminated");

        // Verify lockup amounts (initial lockup plus sum of all top-ups)
        uint256 expectedCdnLockupTotal = defaultCDNLockup + (cdnTopUp * 4); // initial + (1 + 2 + 1 + 0 = 4x)
        uint256 defaultCacheMissLockupTotal = defaultCacheMissLockup + (cacheMissTopUp * 4); // initial + (1 + 2 + 0 + 1 = 4x)
        assertEq(cdnRail.lockupFixed, expectedCdnLockupTotal, "CDN rail lockup incorrect");
        assertEq(cacheMissRail.lockupFixed, defaultCacheMissLockupTotal, "Cache miss rail lockup incorrect");
    }

    function _makeStringOfLength(uint256 len) internal pure returns (string memory s) {
        s = string(_makeBytesOfLength(len));
    }

    function _makeBytesOfLength(uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = "a";
        }
    }

    /**
     * @notice Regression test for: CDN data set clean up
     * @dev Tests that railToDataSet mappings are properly cleaned up when dataSetDeleted is called
     * This test ensures that the fix prevents rail mapping leaks after dataset deletion
     */
    function testRegression_CDNDataSetCleanup() public {
        console.log("=== Regression Test: CDN Data Set Clean Up Fix ===");

        // Test 1: CDN dataset cleanup
        console.log("1. Testing CDN dataset rail mapping cleanup");
        _testCDNDatasetRailMappingCleanup();

        // Test 2: Non-CDN dataset cleanup
        console.log("2. Testing non-CDN dataset rail mapping cleanup");
        _testNonCDNDatasetRailMappingCleanup();

        // Test 3: Complete dataSetDeleted cleanup verification
        console.log("3. Testing complete dataSetDeleted cleanup verification");
        _testCompleteDataSetDeletedCleanup();

        console.log("=== Regression test completed successfully! ===");
    }

    function _testCDNDatasetRailMappingCleanup() internal {
        // Create a dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, metadataKeys, metadataValues);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Verify CDN rails were created
        assertTrue(info.cacheMissRailId != 0, "Cache miss rail should be created for CDN dataset");
        assertTrue(info.cdnRailId != 0, "CDN rail should be created for CDN dataset");

        // Verify rail mappings exist before deletion
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == dataSetId, "PDP rail mapping should exist");

        // Terminate the service
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get updated info after termination to get pdpEndEpoch
        info = viewContract.getDataSet(dataSetId);

        // Wait for payment end epoch to elapse
        vm.roll(info.pdpEndEpoch + 1);

        // Call dataSetDeleted to trigger cleanup
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        // Verify all rail mappings are cleaned up (this is the fix from issue #269)
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == 0, "PDP rail mapping should be cleaned up");
        assertTrue(
            viewContract.railToDataSet(info.cacheMissRailId) == 0, "Cache miss rail mapping should be cleaned up"
        );
        assertTrue(viewContract.railToDataSet(info.cdnRailId) == 0, "CDN rail mapping should be cleaned up");
    }

    function _testNonCDNDatasetRailMappingCleanup() internal {
        // Create a dataset without CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, metadataKeys, metadataValues);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Verify CDN rails were NOT created
        assertTrue(info.cacheMissRailId == 0, "Cache miss rail should NOT be created for non-CDN dataset");
        assertTrue(info.cdnRailId == 0, "CDN rail should NOT be created for non-CDN dataset");

        // Verify only PDP rail mapping exists before deletion
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == dataSetId, "PDP rail mapping should exist");

        // Terminate the service to set pdpEndEpoch
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get updated info after termination to get pdpEndEpoch
        info = viewContract.getDataSet(dataSetId);

        // Wait for payment end epoch to elapse
        vm.roll(info.pdpEndEpoch + 1);

        // Call dataSetDeleted to trigger cleanup
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        // Verify PDP rail mapping is cleaned up
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == 0, "PDP rail mapping should be cleaned up");
    }

    function _testCompleteDataSetDeletedCleanup() internal {
        // Create a dataset with CDN and multiple metadata keys
        string[] memory metadataKeys = new string[](3);
        string[] memory metadataValues = new string[](3);
        metadataKeys[0] = "withCDN";
        metadataValues[0] = "";
        metadataKeys[1] = "label";
        metadataValues[1] = "test-dataset";
        metadataKeys[2] = "description";
        metadataValues[2] = "A test dataset for cleanup verification";

        uint256 dataSetId = createDataSetForClient(serviceProvider, client, metadataKeys, metadataValues);

        // Get initial dataset info
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Verify initial state exists
        assertTrue(info.pdpRailId != 0, "PDP rail should exist");

        // Verify rail mappings exist
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == dataSetId, "PDP rail mapping should exist");

        // Verify metadata exists
        (bool withCDNExists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        (bool labelExists,) = viewContract.getDataSetMetadata(dataSetId, "label");
        (bool descriptionExists,) = viewContract.getDataSetMetadata(dataSetId, "description");
        assertTrue(withCDNExists, "withCDN metadata should exist");
        assertTrue(labelExists, "label metadata should exist");
        assertTrue(descriptionExists, "description metadata should exist");

        // Verify dataset info exists
        assertTrue(viewContract.getDataSet(dataSetId).pdpRailId != 0, "Dataset info should exist");

        // Set up proving state to test cleanup by calling nextProvingPeriod via mock PDP verifier
        // From setUp(): maxProvingPeriod = 2880, challengeWindowSize = 60
        uint256 currentBlock = block.number;
        uint256 firstDeadline = currentBlock + 2880; // maxProvingPeriod
        uint256 validChallengeEpoch = firstDeadline - 60 + 1;

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, validChallengeEpoch, 10, bytes(""));

        // Verify proving-related fields have non-zero values before deletion
        uint256 provingDeadlineBefore = viewContract.provingDeadline(dataSetId);
        bool provenThisPeriodBefore = viewContract.provenThisPeriod(dataSetId);
        uint256 provingActivationEpochBefore = viewContract.provingActivationEpoch(dataSetId);

        assertTrue(provingDeadlineBefore != 0, "provingDeadline should be non-zero after nextProvingPeriod");
        assertFalse(provenThisPeriodBefore, "provenThisPeriod should be false after nextProvingPeriod");
        assertTrue(
            provingActivationEpochBefore != 0, "provingActivationEpoch should be non-zero after nextProvingPeriod"
        );

        // Verify client dataset list includes this dataset
        FilecoinWarmStorageService.DataSetInfoView[] memory clientDataSets = viewContract.getClientDataSets(client);
        bool foundInList = false;
        for (uint256 i = 0; i < clientDataSets.length; i++) {
            if (clientDataSets[i].dataSetId == dataSetId) {
                foundInList = true;
                break;
            }
        }
        assertTrue(foundInList, "Dataset should be in client dataset list");

        // Terminate the service
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get updated info after termination
        info = viewContract.getDataSet(dataSetId);

        // Wait for payment end epoch to elapse
        vm.roll(info.pdpEndEpoch + 1);

        // Call dataSetDeleted to trigger complete cleanup
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        // Verify ALL mappings are cleaned up

        // Rail mappings should be cleaned up
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == 0, "PDP rail mapping should be cleaned up");

        // Metadata mappings should be cleaned up
        (bool withCDNExistsAfter,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        (bool labelExistsAfter,) = viewContract.getDataSetMetadata(dataSetId, "label");
        (bool descriptionExistsAfter,) = viewContract.getDataSetMetadata(dataSetId, "description");
        assertFalse(withCDNExistsAfter, "withCDN metadata key should be cleaned up");
        assertFalse(labelExistsAfter, "label metadata key should be cleaned up");
        assertFalse(descriptionExistsAfter, "description metadata key should be cleaned up");

        // Check that metadata values are also cleaned up from storage using internal function
        string memory withCDNValueAfter = pdpServiceWithPayments._getDataSetMetadataValue(dataSetId, "withCDN");
        string memory labelValueAfter = pdpServiceWithPayments._getDataSetMetadataValue(dataSetId, "label");
        string memory descriptionValueAfter = pdpServiceWithPayments._getDataSetMetadataValue(dataSetId, "description");
        assertEq(withCDNValueAfter, "", "withCDN metadata value should be cleaned up from storage");
        assertEq(labelValueAfter, "", "label metadata value should be cleaned up from storage");
        assertEq(descriptionValueAfter, "", "description metadata value should be cleaned up from storage");

        // Proving-related fields should be cleaned up
        assertTrue(viewContract.provingDeadline(dataSetId) == 0, "provingDeadline should be cleaned up");
        assertFalse(viewContract.provenThisPeriod(dataSetId), "provenThisPeriod should be cleaned up");
        assertTrue(viewContract.provingActivationEpoch(dataSetId) == 0, "provingActivationEpoch should be cleaned up");

        // Dataset info should be cleaned up
        FilecoinWarmStorageService.DataSetInfoView memory dataSetInfo = viewContract.getDataSet(dataSetId);
        assertTrue(dataSetInfo.pdpRailId == 0, "pdpRailId should be cleaned up");
        assertTrue(dataSetInfo.cacheMissRailId == 0, "cacheMissRailId should be cleaned up in DataSetInfoView");
        assertTrue(dataSetInfo.cdnRailId == 0, "cdnRailId should be cleaned up in DataSetInfoView");
        assertTrue(dataSetInfo.payer == address(0), "payer should be cleaned up");
        assertTrue(dataSetInfo.payee == address(0), "payee should be cleaned up");
        assertTrue(dataSetInfo.serviceProvider == address(0), "serviceProvider should be cleaned up");
        assertTrue(dataSetInfo.commissionBps == 0, "commissionBps should be cleaned up");
        assertTrue(dataSetInfo.clientDataSetId == 0, "clientDataSetId should be cleaned up");
        assertTrue(dataSetInfo.pdpEndEpoch == 0, "pdpEndEpoch should be cleaned up");
        assertTrue(dataSetInfo.providerId == 0, "providerId should be cleaned up");
        assertTrue(dataSetInfo.dataSetId == dataSetId, "dataSetId should remain unchanged");

        // Client dataset list should not include this dataset
        clientDataSets = viewContract.getClientDataSets(client);
        foundInList = false;
        for (uint256 i = 0; i < clientDataSets.length; i++) {
            if (clientDataSets[i].dataSetId == dataSetId) {
                foundInList = true;
                break;
            }
        }
        assertTrue(!foundInList, "Dataset should be removed from client dataset list");
    }
}

contract SignatureCheckingService is FilecoinWarmStorageService {
    constructor(
        address _pdpVerifierAddress,
        address _paymentsContractAddress,
        IERC20Metadata _usdfcTokenAddress,
        address _filBeamAddressBeneficiary,
        ServiceProviderRegistry _serviceProviderRegistry,
        SessionKeyRegistry _sessionKeyRegistry
    )
        FilecoinWarmStorageService(
            _pdpVerifierAddress,
            _paymentsContractAddress,
            _usdfcTokenAddress,
            _filBeamAddressBeneficiary,
            _serviceProviderRegistry,
            _sessionKeyRegistry
        )
    {}

    function doRecoverSigner(bytes32 messageHash, bytes memory signature) public pure returns (address) {
        return recoverSigner(messageHash, signature);
    }
}

contract FilecoinWarmStorageServiceSignatureTest is Test {
    using SafeERC20 for MockERC20;

    // Contracts
    SignatureCheckingService public pdpService;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public serviceProviderRegistry;

    // Test accounts with known private keys
    address public payer;
    uint256 public payerPrivateKey;
    address public creator;
    address public wrongSigner;
    uint256 public wrongSignerPrivateKey;
    uint256 public filBeamControllerPrivateKey;
    address public filBeamController;
    uint256 public filBeamBeneficiaryPrivateKey;
    address public filBeamBeneficiary;

    SessionKeyRegistry sessionKeyRegistry = new SessionKeyRegistry();

    function setUp() public {
        // Set up test accounts with known private keys
        payerPrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        payer = vm.addr(payerPrivateKey);

        wrongSignerPrivateKey = 0x9876543210987654321098765432109876543210987654321098765432109876;
        wrongSigner = vm.addr(wrongSignerPrivateKey);

        filBeamControllerPrivateKey = 0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef;
        filBeamController = vm.addr(filBeamControllerPrivateKey);

        filBeamBeneficiaryPrivateKey = 0x133713371337133713371337133713371337133713371337133713371337;
        filBeamBeneficiary = vm.addr(filBeamBeneficiaryPrivateKey);

        creator = address(0xf2);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        serviceProviderRegistry = ServiceProviderRegistry(address(registryProxy));

        // Deploy Payments contract (no longer upgradeable)
        payments = new Payments();

        // Deploy and initialize the service
        SignatureCheckingService serviceImpl = new SignatureCheckingService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );
        bytes memory initData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60), // challengeWindowSize
            filBeamController, // filBeamControllerAddress
            "Test Service", // service name
            "Test Description" // service description
        );

        MyERC1967Proxy serviceProxy = new MyERC1967Proxy(address(serviceImpl), initData);
        pdpService = SignatureCheckingService(address(serviceProxy));

        // Fund the payer
        mockUSDFC.safeTransfer(payer, 1000 * 10 ** 6); // 1000 USDFC
    }

    // Test the recoverSigner function indirectly through signature verification
    function testRecoverSignerWithValidSignature() public view {
        // Create the message hash that should be signed
        bytes32 messageHash = keccak256(abi.encode(42));

        // Sign the message hash with the payer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPrivateKey, messageHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Test that the signature verifies correctly
        address recoveredSigner = pdpService.doRecoverSigner(messageHash, validSignature);
        assertEq(recoveredSigner, payer, "Should recover the correct signer address");
    }

    function testRecoverSignerWithWrongSigner() public view {
        // Create the message hash
        bytes32 messageHash = keccak256(abi.encode(42));

        // Sign with wrong signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongSignerPrivateKey, messageHash);
        bytes memory wrongSignature = abi.encodePacked(r, s, v);

        // Test that the signature recovers the wrong signer (not the expected payer)
        address recoveredSigner = pdpService.doRecoverSigner(messageHash, wrongSignature);
        assertEq(recoveredSigner, wrongSigner, "Should recover the wrong signer address");
        assertTrue(recoveredSigner != payer, "Should not recover the expected payer address");
    }

    function testRecoverSignerInvalidLength() public {
        bytes32 messageHash = keccak256(abi.encode(42));
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes16(0)); // Wrong length (48 bytes instead of 65)

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignatureLength.selector, 65, invalidSignature.length));
        pdpService.doRecoverSigner(messageHash, invalidSignature);
    }

    function testRecoverSignerInvalidValue() public {
        bytes32 messageHash = keccak256(abi.encode(42));

        // Create signature with invalid v value
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));
        uint8 v = 25; // Invalid v value (should be 27 or 28)
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedSignatureV.selector, 25));
        pdpService.doRecoverSigner(messageHash, invalidSignature);
    }
}

// Test contract for upgrade scenarios
contract FilecoinWarmStorageServiceUpgradeTest is Test {
    FilecoinWarmStorageService public warmStorageService;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public serviceProviderRegistry;

    address public deployer;
    address public filBeamController;
    address public filBeamBeneficiary;

    SessionKeyRegistry sessionKeyRegistry = new SessionKeyRegistry();

    function setUp() public {
        deployer = address(this);
        filBeamController = address(0xf2);
        filBeamBeneficiary = address(0xf3);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        serviceProviderRegistry = ServiceProviderRegistry(address(registryProxy));

        // Deploy Payments contract (no longer upgradeable)
        payments = new Payments();

        // Deploy FilecoinWarmStorageService with original initialize (without proving period params)
        // This simulates an existing deployed contract before the upgrade
        FilecoinWarmStorageService warmStorageImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );
        bytes memory initData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60), // challengeWindowSize
            filBeamController, // filBeamControllerAddress
            "Test Service", // service name
            "Test Description" // service description
        );

        MyERC1967Proxy warmStorageProxy = new MyERC1967Proxy(address(warmStorageImpl), initData);
        warmStorageService = FilecoinWarmStorageService(address(warmStorageProxy));
    }

    function testConfigureProvingPeriod() public {
        // Test that we can call configureProvingPeriod to set new proving period parameters
        uint64 newMaxProvingPeriod = 120; // 2 hours
        uint256 newChallengeWindowSize = 30;

        // This should work since we're using reinitializer(2)
        warmStorageService.configureProvingPeriod(newMaxProvingPeriod, newChallengeWindowSize);

        // Deploy view contract and verify values through it
        FilecoinWarmStorageServiceStateView viewContract = new FilecoinWarmStorageServiceStateView(warmStorageService);
        warmStorageService.setViewContract(address(viewContract));

        // Verify the values were set correctly through the view contract
        (uint64 updatedMaxProvingPeriod, uint256 updatedChallengeWindow,,) = viewContract.getPDPConfig();
        assertEq(updatedMaxProvingPeriod, newMaxProvingPeriod, "Max proving period should be updated");
        assertEq(updatedChallengeWindow, newChallengeWindowSize, "Challenge window size should be updated");
    }

    function testSetViewContract() public {
        // Deploy view contract
        FilecoinWarmStorageServiceStateView viewContract = new FilecoinWarmStorageServiceStateView(warmStorageService);

        // Set view contract
        warmStorageService.setViewContract(address(viewContract));

        // Verify it was set
        assertEq(warmStorageService.viewContractAddress(), address(viewContract), "View contract should be set");

        // Test that non-owner cannot set view contract
        vm.prank(address(0x123));
        vm.expectRevert();
        warmStorageService.setViewContract(address(0x456));

        // Test that it cannot be set again (one-time only)
        FilecoinWarmStorageServiceStateView newViewContract =
            new FilecoinWarmStorageServiceStateView(warmStorageService);
        vm.expectRevert(abi.encodeWithSelector(Errors.AddressAlreadySet.selector, Errors.AddressField.View));
        warmStorageService.setViewContract(address(newViewContract));

        // Test that zero address is rejected (would need a new contract to test this properly)
        // This is now unreachable in this test since view contract is already set
    }

    function testMigrateWithViewContract() public {
        // First, deploy a view contract
        FilecoinWarmStorageServiceStateView viewContract = new FilecoinWarmStorageServiceStateView(warmStorageService);

        // Simulate migration being called during upgrade (must be called by proxy itself)
        warmStorageService.migrate(address(viewContract));

        // Verify view contract was set
        assertEq(warmStorageService.viewContractAddress(), address(viewContract), "View contract should be set");

        // Verify we can call PDP functions through view contract
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        assertEq(maxProvingPeriod, 2880, "Max proving period should be accessible through view");
        assertEq(challengeWindow, 60, "Challenge window should be accessible through view");
    }

    function testNextPDPChallengeWindowStartThroughView() public {
        // Deploy and set view contract
        FilecoinWarmStorageServiceStateView viewContract = new FilecoinWarmStorageServiceStateView(warmStorageService);
        warmStorageService.setViewContract(address(viewContract));

        // This should revert since no data set exists with proving period initialized
        vm.expectRevert(abi.encodeWithSelector(Errors.ProvingPeriodNotInitialized.selector, 999));
        viewContract.nextPDPChallengeWindowStart(999);

        // Note: We can't fully test nextPDPChallengeWindowStart without creating a data set
        // and initializing its proving period, which requires the full PDP system setup.
        // The function is tested indirectly through the PDP system integration tests.
    }

    function testConfigureProvingPeriodWithInvalidParameters() public {
        // Test that configureChallengePeriod validates parameters correctly

        // Test zero max proving period
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxProvingPeriodZero.selector));
        warmStorageService.configureProvingPeriod(0, 30);

        // Test zero challenge window size
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 0));
        warmStorageService.configureProvingPeriod(120, 0);

        // Test challenge window size >= max proving period
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 120));
        warmStorageService.configureProvingPeriod(120, 120);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 150));
        warmStorageService.configureProvingPeriod(120, 150);
    }

    function testMigrate() public {
        // Test migrate function for versioning
        // Note: This would typically be called during a proxy upgrade via upgradeToAndCall
        // We're testing the function directly here for simplicity

        // Start recording logs
        vm.recordLogs();

        // Simulate calling migrate during upgrade
        vm.prank(warmStorageService.owner());
        warmStorageService.migrate(address(0));

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the ContractUpgraded event (reinitializer also emits Initialized event)
        bytes32 expectedTopic = keccak256("ContractUpgraded(string,address)");
        bool foundEvent = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedTopic) {
                // Decode and verify the event data
                (string memory version, address implementation) = abi.decode(logs[i].data, (string, address));
                assertEq(version, "0.3.0", "Version should be 0.3.0");
                assertTrue(implementation != address(0), "Implementation address should not be zero");
                foundEvent = true;
                break;
            }
        }

        assertTrue(foundEvent, "Should emit ContractUpgraded event");
    }

    function testMigrateOnlyOnce() public {
        // Test that migrate can only be called once per reinitializer version
        warmStorageService.migrate(address(0));

        // Second call should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        warmStorageService.migrate(address(0));
    }
}

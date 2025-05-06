// SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Minimal ENS registry interface
interface ENS {
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
}

// Minimal BaseRegistrar interface (for expiration)
interface IBaseRegistrar {
    function nameExpires(uint256 id) external view returns (uint256);
}

interface IResolver {
    function setContenthash(bytes32 node, bytes calldata hash) external;
}

// Minimal PriceOracle interface
interface IPriceOracle {
    struct Price {
        uint256 base;
        uint256 premium;
    }
}

// ETHRegistrarController interface
interface IETHRegistrarController {
    function rentPrice(string calldata name, uint256 duration) external view returns (IPriceOracle.Price memory);
    function register(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external payable;
    function makeCommitment(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external pure returns (bytes32);
    function commit(bytes32 commitment) external;
    function available(string calldata name) external view returns (bool);
    function valid(string calldata name) external pure returns (bool);
}

contract IndieNodeENSRegistrar is Ownable, ReentrancyGuard {
    IETHRegistrarController public controller;
    IBaseRegistrar public baseRegistrar;
    ENS public ensRegistry;
    uint256 public FEE = 0.001 ether;

    modifier onlyContractOwner() {
        require(owner() == msg.sender, "Caller is not the contract owner");
        _;
    }

    constructor(address _ensRegistry) Ownable(msg.sender) {
        require(_ensRegistry != address(0), "Invalid ENS registry address");

        ensRegistry = ENS(_ensRegistry); // Save ENS registry reference
        
        bytes32 ethNode = keccak256(abi.encodePacked(bytes32(0), keccak256("eth")));
        address registrarAddr = ensRegistry.owner(ethNode);
        require(registrarAddr != address(0), "Invalid registrar");

        baseRegistrar = IBaseRegistrar(registrarAddr);
        // Controller must be set manually or via updateController()
    }

    event NameCommitmentSubmitted(string name, address indexed sender, bytes32 commitment);
    event NameRegistered(
        string name,
        address indexed registrant,
        address indexed owner,
        uint256 totalCost,
        uint256 timestamp
    );

    // Optional function to set controller after deploy
    function updateController(address _controller) external onlyContractOwner {
        require(_controller != address(0), "Invalid controller address");
        controller = IETHRegistrarController(_controller);
    }

    function generateCommitment(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external view returns (bytes32) {
        require(address(controller) != address(0), "Controller not set");
        require(controller.valid(name), "ENS name is invalid");
        require(controller.available(name), "ENS name is not available");

        return controller.makeCommitment(
            name,
            owner,
            duration,
            secret,
            resolver,
            data,
            reverseRecord,
            ownerControlledFuses
        );
    }

    // Second function submits the commitment
    function submitCommitment(string calldata name, bytes32 commitment) external {
        require(address(controller) != address(0), "Controller not set");
        controller.commit(commitment);
        emit NameCommitmentSubmitted(name, msg.sender, commitment);
    }

    // Updated commitToName with the correct argument order:
    function commitToName(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external {
        require(address(controller) != address(0), "Controller not set");
        require(controller.valid(name), "ENS name is invalid");
        require(controller.available(name), "ENS name is not available");

        bytes32 commitment = controller.makeCommitment(
            name,
            owner,
            duration,
            secret,
            resolver,
            data,
            reverseRecord,
            ownerControlledFuses
        );

        controller.commit(commitment);
        emit NameCommitmentSubmitted(name, msg.sender, commitment);
    }

    function getTotalPrice(string calldata name, uint256 duration) external view returns (uint256 totalCost, uint256 base, uint256 premium) {
        IPriceOracle.Price memory price = controller.rentPrice(name, duration);
        totalCost = price.base + price.premium + FEE;
        return (totalCost, price.base, price.premium);
    }

    function registerWithFee(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external payable nonReentrant {
        require(address(controller) != address(0), "Controller not set");

        IPriceOracle.Price memory price = controller.rentPrice(name, duration);
        uint256 totalCost = price.base + price.premium + FEE;
        require(msg.value >= totalCost, "Insufficient payment");

        controller.register{value: price.base + price.premium}(
            name,
            owner,
            duration,
            secret,
            resolver,
            data,
            reverseRecord,
            ownerControlledFuses
        );

        emit NameRegistered(name, msg.sender, owner, totalCost, block.timestamp);
    }

    /// @notice Set the contenthash for a precomputed node in one call
    function setContentHashByNode(
        bytes32 node,
        bytes calldata contentHash
    ) external onlyContractOwner {
        address resolver = ensRegistry.resolver(node);
        require(resolver != address(0), "Resolver not set");
        IResolver(resolver).setContenthash(node, contentHash);
    }


    function isAvailable(string calldata name) external view returns (bool) {
        return controller.available(name);
    }

    function isValid(string calldata name) external view returns (bool) {
        return controller.valid(name);
    }

    function getFee() external view returns (uint256) {
        return FEE;
    }

    function getExpiry(string calldata name) external view returns (uint256) {
        uint256 labelHash = uint256(keccak256(bytes(name)));
        return baseRegistrar.nameExpires(labelHash);
    }

    function withdraw() external onlyContractOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "Withdrawal failed");
    }

    function updateFee(uint256 newFee) external onlyContractOwner {
        require(newFee <= 0.01 ether, "Fee too high");
        FEE = newFee;
    }
}

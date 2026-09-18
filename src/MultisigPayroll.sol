// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MultisigPayroll
 * @notice M-of-N multisig treasury with EIP-712 typed signature verification,
 * relayer execution, replay protection, strict signer ordering, and self-managed governance.
 */
contract MultisigPayroll is EIP712, ReentrancyGuard {
    bytes32 public constant PAYMENT_TYPEHASH =
        keccak256("Payment(address destination,uint256 value,bytes data,uint256 nonce,uint256 deadline)");

    uint256 public threshold;
    address[] public owners;
    mapping(address => bool) public isOwner;
    mapping(uint256 => bool) public isNonceUsed;

    // Custom errors
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error ZeroAddress();
    error DuplicateOwner(address owner);
    error ExpiredDeadline(uint256 currentTimestamp, uint256 deadline);
    error NonceAlreadyUsed(uint256 nonce);
    error InsufficientSignatures(uint256 provided, uint256 requiredThreshold);
    error UnauthorizedSigner(address signer);
    error DuplicateOrUnorderedSigner(address signer);
    error InsufficientBalance(uint256 requested, uint256 available);
    error ExecutionFailed(bytes reason);
    error OnlySelf();
    error OwnerNotFound(address owner);

    // Events
    event PaymentExecuted(
        address indexed destination,
        uint256 value,
        bytes data,
        uint256 indexed nonce,
        address indexed relayer
    );
    event Deposit(address indexed sender, uint256 amount);
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    constructor(
        address[] memory initialOwners,
        uint256 initialThreshold
    ) EIP712("MultisigPayroll", "1") {
        if (initialThreshold == 0 || initialThreshold > initialOwners.length) {
            revert InvalidThreshold(initialThreshold, initialOwners.length);
        }

        for (uint256 i = 0; i < initialOwners.length; i++) {
            address owner = initialOwners[i];
            if (owner == address(0)) revert ZeroAddress();
            if (isOwner[owner]) revert DuplicateOwner(owner);

            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }

        threshold = initialThreshold;
        emit ThresholdChanged(0, initialThreshold);
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Computes EIP-712 hash for a typed payment payload
     */
    function getPaymentDigest(
        address destination,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_TYPEHASH,
                destination,
                value,
                keccak256(data),
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Execute a multi-signed payroll or contract call through a relayer
     * @param destination Target recipient or contract
     * @param value Amount of ETH to forward
     * @param data Calldata for contract execution or empty
     * @param nonce Replay protection nonce
     * @param deadline Expiry timestamp
     * @param signatures Signatures from unique owners in ascending address order
     */
    function executePayment(
        address destination,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes[] calldata signatures
    ) external nonReentrant returns (bytes memory returnData) {
        if (block.timestamp > deadline) revert ExpiredDeadline(block.timestamp, deadline);
        if (isNonceUsed[nonce]) revert NonceAlreadyUsed(nonce);
        if (signatures.length < threshold) {
            revert InsufficientSignatures(signatures.length, threshold);
        }
        if (destination == address(0)) revert ZeroAddress();
        if (value > address(this).balance) {
            revert InsufficientBalance(value, address(this).balance);
        }

        isNonceUsed[nonce] = true;

        bytes32 digest = getPaymentDigest(destination, value, data, nonce, deadline);

        // Verify signatures are from authorized owners and in strictly ascending order
        address lastSigner = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isOwner[signer]) revert UnauthorizedSigner(signer);
            if (signer <= lastSigner) revert DuplicateOrUnorderedSigner(signer);
            lastSigner = signer;
        }

        (bool success, bytes memory result) = destination.call{value: value}(data);
        if (!success) {
            revert ExecutionFailed(result);
        }

        emit PaymentExecuted(destination, value, data, nonce, msg.sender);
        return result;
    }

    // --- Self-governed Owner Management (Callable only via executePayment to address(this)) ---

    function addOwnerWithThreshold(address newOwner, uint256 newThreshold) external onlySelf {
        if (newOwner == address(0)) revert ZeroAddress();
        if (isOwner[newOwner]) revert DuplicateOwner(newOwner);

        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);

        _setThreshold(newThreshold);
    }

    function removeOwnerWithThreshold(address ownerToRemove, uint256 newThreshold) external onlySelf {
        if (!isOwner[ownerToRemove]) revert OwnerNotFound(ownerToRemove);

        isOwner[ownerToRemove] = false;
        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
        }

        emit OwnerRemoved(ownerToRemove);
        _setThreshold(newThreshold);
    }

    function changeThreshold(uint256 newThreshold) external onlySelf {
        _setThreshold(newThreshold);
    }

    function _setThreshold(uint256 newThreshold) internal {
        if (newThreshold == 0 || newThreshold > owners.length) {
            revert InvalidThreshold(newThreshold, owners.length);
        }
        uint256 oldThreshold = threshold;
        threshold = newThreshold;
        emit ThresholdChanged(oldThreshold, newThreshold);
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./interface/IMigrator.sol";
import "./interfaces/IAxelarMigrator.sol";

import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {IAxelarGasService} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Axelar Migrator
/// @notice Bridges EigenFi pool assets from Ethereum to Stellar over Axelar GMP and unlocks assets on inbound withdrawals.
contract AxelarMigrator is IMigrator, IAxelarMigrator, AxelarExecutable, Ownable {
    using SafeERC20 for IERC20;

    uint8 private constant MESSAGE_TYPE_DEPOSIT = 0;
    uint8 private constant MESSAGE_TYPE_WITHDRAW = 1;
    uint8 private constant MESSAGE_TYPE_YIELD_UPDATE = 2;

    /// @notice Thrown when a token array and amount array are empty or mismatched.
    error InvalidArrayLength();

    /// @notice Thrown when a token amount is zero.
    error ZeroAmount();

    /// @notice Thrown when a token address is the zero address.
    error InvalidToken();

    /// @notice Thrown when destination or trusted source configuration is empty.
    error EmptyDestinationConfiguration();

    /// @notice Thrown when an inbound Axelar message does not come from the trusted chain.
    error InvalidSourceChain();

    /// @notice Thrown when an inbound Axelar message does not come from the trusted contract.
    error InvalidSourceAddress();

    /// @notice Thrown when an inbound message type is unsupported.
    error InvalidMessageType();

    /// @notice Thrown when a recipient string cannot be parsed into an EVM address.
    error InvalidRecipientString();

    /// @notice Axelar gas service used to prepay GMP execution on the destination chain.
    address public immutable gasService;

    /// @notice Remote Axelar destination chain identifier.
    string public destinationChain;

    /// @notice Remote Axelar destination contract string.
    string public destinationAddress;

    /// @notice Trusted source chain identifier for inbound messages.
    string public trustedSourceChain;

    /// @notice Trusted source contract string for inbound messages.
    string public trustedSourceAddress;

    /// @param gateway_ The Axelar gateway contract on the source chain.
    /// @param gasService_ The Axelar gas service contract on the source chain.
    /// @param destinationChain_ The destination chain identifier used for outbound GMP calls.
    /// @param destinationAddress_ The destination contract string used for outbound GMP calls.
    constructor(
        address gateway_,
        address gasService_,
        string memory destinationChain_,
        string memory destinationAddress_
    ) AxelarExecutable(gateway_) Ownable(msg.sender) {
        if (gasService_ == address(0)) revert InvalidAddress();
        if (bytes(destinationChain_).length == 0 || bytes(destinationAddress_).length == 0) {
            revert EmptyDestinationConfiguration();
        }

        gasService = gasService_;
        destinationChain = destinationChain_;
        destinationAddress = destinationAddress_;
        trustedSourceChain = destinationChain_;
        trustedSourceAddress = destinationAddress_;
    }

    /// @notice Accepts native ETH to prefund Axelar gas payments.
    receive() external payable {}

    /// @inheritdoc IMigrator
    /// @dev The EigenFi pool approves the migrator before calling this function, so the migrator pulls custody with transferFrom.
    function migrate(
        address,
        address[] calldata _tokens,
        address _destination,
        uint256[] calldata _amounts
    ) external override {
        uint256 length = _tokens.length;
        if (length == 0 || length != _amounts.length) revert InvalidArrayLength();

        string memory stellarRecipient = _addressToString(_destination);
        uint256 gasPaymentPerMessage = address(this).balance / length;

        for (uint256 i = 0; i < length; ++i) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];

            if (token == address(0)) revert InvalidToken();
            if (amount == 0) revert ZeroAmount();

            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            bytes memory payload = abi.encode(MESSAGE_TYPE_DEPOSIT, token, amount, stellarRecipient);

            if (gasPaymentPerMessage > 0) {
                IAxelarGasService(gasService).payNativeGasForContractCall{value: gasPaymentPerMessage}(
                    address(this),
                    destinationChain,
                    destinationAddress,
                    payload,
                    msg.sender
                );
            }

            gateway().callContract(destinationChain, destinationAddress, payload);
            emit BridgeDeposit(token, amount, stellarRecipient);
        }
    }

    /// @notice Updates the outbound destination and the trusted inbound source pair.
    /// @dev This contract assumes a single symmetric remote bridge counterpart.
    /// @param destinationChain_ The remote Axelar chain identifier.
    /// @param destinationAddress_ The remote bridge handler address string.
    function setDestination(string calldata destinationChain_, string calldata destinationAddress_) external onlyOwner {
        if (bytes(destinationChain_).length == 0 || bytes(destinationAddress_).length == 0) {
            revert EmptyDestinationConfiguration();
        }

        destinationChain = destinationChain_;
        destinationAddress = destinationAddress_;
        trustedSourceChain = destinationChain_;
        trustedSourceAddress = destinationAddress_;
    }

    /// @notice Withdraws ERC-20s that are stranded in the migrator.
    /// @param token The ERC-20 token to recover.
    /// @param amount The amount of tokens to recover.
    function withdrawStuckTokens(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        IERC20(token).safeTransfer(owner(), amount);
    }

    /// @inheritdoc AxelarExecutable
    function _execute(
        bytes32,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override {
        if (!_equalStrings(sourceChain, trustedSourceChain)) revert InvalidSourceChain();
        if (!_equalStrings(sourceAddress, trustedSourceAddress)) revert InvalidSourceAddress();

        (uint8 messageType, address token, uint256 amount, string memory recipient) = abi.decode(
            payload,
            (uint8, address, uint256, string)
        );

        if (messageType == MESSAGE_TYPE_WITHDRAW) {
            if (token == address(0)) revert InvalidToken();
            if (amount == 0) revert ZeroAmount();

            address ethRecipient = _stringToAddress(recipient);
            IERC20(token).safeTransfer(ethRecipient, amount);
            emit BridgeWithdraw(token, amount, ethRecipient);
            return;
        }

        if (messageType == MESSAGE_TYPE_YIELD_UPDATE) {
            emit YieldUpdate(amount);
            return;
        }

        revert InvalidMessageType();
    }

    /// @dev Encodes an EVM address as a 0x-prefixed lowercase hex string.
    function _addressToString(address account) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(account)), 20);
    }

    /// @dev Parses a 0x-prefixed hex string into an EVM address.
    function _stringToAddress(string memory value) internal pure returns (address) {
        bytes memory data = bytes(value);
        if (data.length != 42 || data[0] != "0" || (data[1] != "x" && data[1] != "X")) {
            revert InvalidRecipientString();
        }

        uint160 parsed;
        for (uint256 i = 2; i < 42; ++i) {
            parsed = (parsed << 4) | _fromHexChar(uint8(data[i]));
        }

        return address(parsed);
    }

    /// @dev Converts a single hex ASCII character into its numeric nibble.
    function _fromHexChar(uint8 character) internal pure returns (uint160) {
        if (character >= uint8(bytes1("0")) && character <= uint8(bytes1("9"))) {
            return uint160(character - uint8(bytes1("0")));
        }
        if (character >= uint8(bytes1("a")) && character <= uint8(bytes1("f"))) {
            return uint160(10 + character - uint8(bytes1("a")));
        }
        if (character >= uint8(bytes1("A")) && character <= uint8(bytes1("F"))) {
            return uint160(10 + character - uint8(bytes1("A")));
        }

        revert InvalidRecipientString();
    }

    /// @dev Compares two strings by keccak256 hash.
    function _equalStrings(string memory left, string memory right) internal pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}

/// @title Mock Axelar Gateway
/// @notice Minimal gateway mock used by the Hardhat test suite.
contract MockAxelarGateway {
    bytes32 private constant APPROVAL_PREFIX = keccak256("contract-call-approved");

    bytes public lastPayload;
    string public lastDestinationChain;
    string public lastDestinationAddress;

    mapping(bytes32 => bool) private approvals;

    /// @notice Mirrors Axelar's ContractCall event for test assertions.
    /// @param sender The sender that initiated the contract call.
    /// @param destinationChain The destination chain identifier.
    /// @param destinationContractAddress The destination contract string.
    /// @param payloadHash The payload hash.
    /// @param payload The raw payload.
    event ContractCall(
        address indexed sender,
        string destinationChain,
        string destinationContractAddress,
        bytes32 indexed payloadHash,
        bytes payload
    );

    /// @notice Records the last outbound call and emits the Axelar-style event.
    /// @param destinationChain_ The destination chain identifier.
    /// @param destinationContractAddress_ The destination contract string.
    /// @param payload_ The raw payload.
    function callContract(
        string calldata destinationChain_,
        string calldata destinationContractAddress_,
        bytes calldata payload_
    ) external {
        lastDestinationChain = destinationChain_;
        lastDestinationAddress = destinationContractAddress_;
        lastPayload = payload_;

        emit ContractCall(
            msg.sender,
            destinationChain_,
            destinationContractAddress_,
            keccak256(payload_),
            payload_
        );
    }

    /// @notice Marks a contract call as approved for a subsequent execute() invocation.
    /// @param commandId The Axelar command identifier.
    /// @param sourceChain The source chain identifier.
    /// @param sourceAddress The source contract string.
    /// @param contractAddress The destination contract address on the local chain.
    /// @param payloadHash The payload hash.
    function approveContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) external {
        approvals[_approvalKey(commandId, sourceChain, sourceAddress, contractAddress, payloadHash)] = true;
    }

    /// @notice Returns whether a call is approved for execution.
    /// @param commandId The Axelar command identifier.
    /// @param sourceChain The source chain identifier.
    /// @param sourceAddress The source contract string.
    /// @param contractAddress The destination contract address on the local chain.
    /// @param payloadHash The payload hash.
    /// @return True if the call is currently approved.
    function isContractCallApproved(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) external view returns (bool) {
        return approvals[_approvalKey(commandId, sourceChain, sourceAddress, contractAddress, payloadHash)];
    }

    /// @notice Validates a call for the caller and clears the approval after successful consumption.
    /// @param commandId The Axelar command identifier.
    /// @param sourceChain The source chain identifier.
    /// @param sourceAddress The source contract string.
    /// @param payloadHash The payload hash.
    /// @return True if the call was approved.
    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool) {
        bytes32 key = _approvalKey(commandId, sourceChain, sourceAddress, msg.sender, payloadHash);
        bool approved = approvals[key];
        if (approved) {
            delete approvals[key];
        }

        return approved;
    }

    /// @notice Satisfies the gateway interface expected by AxelarExecutable.
    /// @param commandId The command identifier.
    /// @return Always false in the local mock.
    function isCommandExecuted(bytes32 commandId) external pure returns (bool) {
        commandId;
        return false;
    }

    /// @dev Derives the approval storage key.
    function _approvalKey(
        bytes32 commandId,
        string memory sourceChain,
        string memory sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(APPROVAL_PREFIX, commandId, sourceChain, sourceAddress, contractAddress, payloadHash));
    }
}

/// @title Mock Axelar Gas Service
/// @notice Minimal gas service mock used by the Hardhat test suite.
contract MockAxelarGasService {
    address public lastSender;
    string public lastDestinationChain;
    string public lastDestinationAddress;
    bytes public lastPayload;
    address public lastRefundAddress;
    uint256 public lastValue;

    /// @notice Mirrors the native gas payment event needed for test assertions.
    /// @param sourceAddress The paying source contract.
    /// @param destinationChain The destination chain identifier.
    /// @param destinationAddress The destination contract string.
    /// @param payloadHash The payload hash.
    /// @param gasFeeAmount The native gas fee amount.
    /// @param refundAddress The refund address.
    event NativeGasPaidForContractCall(
        address indexed sourceAddress,
        string destinationChain,
        string destinationAddress,
        bytes32 indexed payloadHash,
        uint256 gasFeeAmount,
        address refundAddress
    );

    /// @notice Records the last native gas payment for a contract call.
    /// @param sender The source contract paying for gas.
    /// @param destinationChain_ The destination chain identifier.
    /// @param destinationAddress_ The destination contract string.
    /// @param payload_ The outbound GMP payload.
    /// @param refundAddress_ The refund address.
    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain_,
        string calldata destinationAddress_,
        bytes calldata payload_,
        address refundAddress_
    ) external payable {
        lastSender = sender;
        lastDestinationChain = destinationChain_;
        lastDestinationAddress = destinationAddress_;
        lastPayload = payload_;
        lastRefundAddress = refundAddress_;
        lastValue = msg.value;

        emit NativeGasPaidForContractCall(
            sender,
            destinationChain_,
            destinationAddress_,
            keccak256(payload_),
            msg.value,
            refundAddress_
        );
    }
}

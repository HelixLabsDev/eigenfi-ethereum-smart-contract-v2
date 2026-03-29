// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "../interface/IMigrator.sol";

/// @title Axelar Migrator Interface
/// @notice Interface for the EigenFi migrator that bridges pool assets over Axelar GMP.
interface IAxelarMigrator is IMigrator {
    /// @notice Emitted when a deposit migration is forwarded to the Stellar bridge handler.
    /// @param token The ERC-20 token being bridged.
    /// @param amount The amount of tokens bridged.
    /// @param stellarRecipient The destination recipient string sent to Stellar.
    event BridgeDeposit(address indexed token, uint256 amount, string stellarRecipient);

    /// @notice Emitted when a withdrawal message from Stellar unlocks ERC-20s on Ethereum.
    /// @param token The ERC-20 token being released.
    /// @param amount The amount of tokens released.
    /// @param ethRecipient The Ethereum recipient that received the unlocked funds.
    event BridgeWithdraw(address indexed token, uint256 amount, address indexed ethRecipient);

    /// @notice Emitted when a yield update message is received from Stellar.
    /// @param newTotalAssets The total assets value reported by the remote bridge.
    event YieldUpdate(uint256 newTotalAssets);

    /// @notice Returns the configured Axelar gas service address.
    /// @return The Axelar gas service contract address.
    function gasService() external view returns (address);

    /// @notice Returns the configured Axelar destination chain string.
    /// @return The destination chain identifier.
    function destinationChain() external view returns (string memory);

    /// @notice Returns the configured destination contract address string on the remote chain.
    /// @return The destination contract address string.
    function destinationAddress() external view returns (string memory);

    /// @notice Returns the trusted source chain identifier for inbound Axelar executions.
    /// @return The trusted source chain identifier.
    function trustedSourceChain() external view returns (string memory);

    /// @notice Returns the trusted source contract address string for inbound Axelar executions.
    /// @return The trusted source contract address string.
    function trustedSourceAddress() external view returns (string memory);

    /// @notice Updates the remote Axelar destination and trusted source pair.
    /// @param destinationChain_ The new destination chain identifier.
    /// @param destinationAddress_ The new destination contract address string.
    function setDestination(string calldata destinationChain_, string calldata destinationAddress_) external;

    /// @notice Withdraws ERC-20s stranded in the migrator.
    /// @param token The ERC-20 token to withdraw.
    /// @param amount The amount of tokens to withdraw.
    function withdrawStuckTokens(address token, uint256 amount) external;

}

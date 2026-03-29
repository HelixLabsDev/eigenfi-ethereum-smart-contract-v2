/**
 * @type import('hardhat/config').HardhatUserConfig
 */
require("@nomicfoundation/hardhat-ignition-ethers");
require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("hardhat-abi-exporter");

const { API_URL, PRIVATE_KEY, ETHERSCAN_API_KEY } = process.env;
const sepoliaNetwork =
  API_URL && PRIVATE_KEY
    ? {
        ethereum_sepolia: {
          url: API_URL,
          accounts: [PRIVATE_KEY],
        },
      }
    : {};

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  networks: sepoliaNetwork,
  etherscan: {
    // Your API key for Etherscan
    // Obtain one at https://etherscan.io/
    apiKey: ETHERSCAN_API_KEY,
  },
  sourcify: {
    enabled: true,
  },
  abiExporter: {
    path: "./app/abi",
    runOnCompile: process.env.EXPORT_ABI === "true",
    clear: process.env.EXPORT_ABI === "true",
    flat: true,
    spacing: 2,
  },
};

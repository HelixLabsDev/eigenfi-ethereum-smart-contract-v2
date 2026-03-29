const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
require("dotenv").config();

const AXELAR_SEPOLIA_GATEWAY = "0x999117D44220F33e0441fbAb2A5aDB8FF485c54D";
const AXELAR_SEPOLIA_GAS_SERVICE = "0xbe406f0189a0b4cf3a05c286473d23791dd44cc6";
const SEPOLIA_WETH = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9";
const DEFAULT_STELLAR_AXELAR_CHAIN = process.env.AXELAR_STELLAR_CHAIN || "stellar-2025-q1";

/**
 * Deploys the Axelar migrator and applies the Sepolia WETH allowlist fix on the pool.
 */
async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  const existingAddresses = require("../addresses.json");

  const poolAddress =
    process.env.EIGENFI_POOL_ADDRESS || existingAddresses.EigenFiPool_Sepolia;
  const stellarBridgeHandler = process.env.AXELAR_STELLAR_BRIDGE_HANDLER;

  if (!stellarBridgeHandler) {
    throw new Error("AXELAR_STELLAR_BRIDGE_HANDLER must be set");
  }

  const AxelarMigrator = await ethers.getContractFactory("AxelarMigrator");
  const migrator = await AxelarMigrator.deploy(
    AXELAR_SEPOLIA_GATEWAY,
    AXELAR_SEPOLIA_GAS_SERVICE,
    DEFAULT_STELLAR_AXELAR_CHAIN,
    stellarBridgeHandler
  );
  await migrator.waitForDeployment();

  const migratorAddress = await migrator.getAddress();
  const pool = await ethers.getContractAt("EigenFiPool", poolAddress);

  if (!(await pool.tokenAllowlist(SEPOLIA_WETH))) {
    const allowWethTx = await pool.setStakable(SEPOLIA_WETH, true);
    await allowWethTx.wait();
  }

  if (await pool.migratorBlocklist(migratorAddress)) {
    const unblockTx = await pool.blockMigrator(migratorAddress, false);
    await unblockTx.wait();
  }

  const output = {
    AxelarMigrator_Sepolia: migratorAddress,
    AxelarGateway_Sepolia: AXELAR_SEPOLIA_GATEWAY,
    AxelarGasService_Sepolia: AXELAR_SEPOLIA_GAS_SERVICE,
    EigenFiPool_Sepolia: poolAddress,
    WETH_Sepolia: SEPOLIA_WETH,
    AxelarStellarChain: DEFAULT_STELLAR_AXELAR_CHAIN,
    AxelarStellarBridgeHandler: stellarBridgeHandler,
    deployer: deployer.address,
  };

  const outputPath = path.join(__dirname, "axelar-addresses.json");
  fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));

  console.log("AxelarMigrator deployed:", migratorAddress);
  console.log("Saved deployment metadata to:", outputPath);
  console.log(
    "EigenFiPool has no migrator registry setter; migration remains opt-in via pool.migrate(...) authorization."
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

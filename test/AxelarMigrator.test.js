const { expect } = require("chai");
const { ethers } = require("hardhat");

const STELLAR_CHAIN = "stellar-2025-q1";
const STELLAR_HANDLER = "CCSNWHMQSPTW4PS7L32OIMH7Z6NFNCKYZKNFSWRSYX7MK64KHBDZDT5I";
const MIGRATION_AMOUNT = ethers.parseUnits("10", 18);

describe("AxelarMigrator", function () {
  async function deployFixture() {
    const [owner, user, recipient, other] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockToken");
    const token = await MockToken.deploy(owner.address);
    const weth = await MockToken.deploy(owner.address);
    await token.waitForDeployment();
    await weth.waitForDeployment();

    const EigenFiPool = await ethers.getContractFactory("EigenFiPool");
    const pool = await EigenFiPool.deploy(
      owner.address,
      [await token.getAddress()],
      await weth.getAddress()
    );
    await pool.waitForDeployment();

    const MockAxelarGateway = await ethers.getContractFactory("MockAxelarGateway");
    const gateway = await MockAxelarGateway.deploy();
    await gateway.waitForDeployment();

    const MockAxelarGasService = await ethers.getContractFactory(
      "MockAxelarGasService"
    );
    const gasService = await MockAxelarGasService.deploy();
    await gasService.waitForDeployment();

    const AxelarMigrator = await ethers.getContractFactory("AxelarMigrator");
    const migrator = await AxelarMigrator.deploy(
      await gateway.getAddress(),
      await gasService.getAddress(),
      STELLAR_CHAIN,
      STELLAR_HANDLER
    );
    await migrator.waitForDeployment();

    await token.mint(user.address, MIGRATION_AMOUNT * 3n);

    return {
      owner,
      user,
      recipient,
      other,
      token,
      weth,
      pool,
      gateway,
      gasService,
      migrator,
    };
  }

  async function helixSignature(signer, migrator, pool) {
    const latestBlock = await ethers.provider.getBlock("latest");
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const signatureExpiry = BigInt(latestBlock.timestamp + 3600);
    const digest = ethers.solidityPackedKeccak256(
      ["address", "uint256", "address", "uint256"],
      [await migrator.getAddress(), signatureExpiry, await pool.getAddress(), chainId]
    );
    const signature = await signer.signMessage(ethers.getBytes(digest));

    return { signatureExpiry, signature };
  }

  async function approveGateway(gateway, migrator, sourceChain, sourceAddress, payload) {
    const commandId = ethers.keccak256(ethers.toUtf8Bytes(`cmd:${sourceChain}:${sourceAddress}`));
    const payloadHash = ethers.keccak256(payload);

    await gateway.approveContractCall(
      commandId,
      sourceChain,
      sourceAddress,
      await migrator.getAddress(),
      payloadHash
    );

    return commandId;
  }

  it("migrate() encodes the deposit payload and calls the gateway", async function () {
    const { owner, user, other, token, pool, gateway, gasService, migrator } =
      await deployFixture();

    await owner.sendTransaction({
      to: await migrator.getAddress(),
      value: ethers.parseEther("1"),
    });

    await token.connect(user).approve(await pool.getAddress(), MIGRATION_AMOUNT);
    await pool
      .connect(user)
      .depositFor(await token.getAddress(), user.address, MIGRATION_AMOUNT);

    const { signatureExpiry, signature } = await helixSignature(owner, migrator, pool);
    await pool
      .connect(user)
      .migrate(
        [await token.getAddress()],
        await migrator.getAddress(),
        other.address,
        signatureExpiry,
        signature
      );

    const payload = await gateway.lastPayload();
    const [messageType, bridgedToken, amount, stellarRecipient] =
      ethers.AbiCoder.defaultAbiCoder().decode(
        ["uint8", "address", "uint256", "string"],
        payload
      );

    expect(messageType).to.equal(0);
    expect(bridgedToken).to.equal(await token.getAddress());
    expect(amount).to.equal(MIGRATION_AMOUNT);
    expect(stellarRecipient).to.equal(other.address.toLowerCase());

    expect(await gateway.lastDestinationChain()).to.equal(STELLAR_CHAIN);
    expect(await gateway.lastDestinationAddress()).to.equal(STELLAR_HANDLER);
    expect(await gasService.lastSender()).to.equal(await migrator.getAddress());
    expect(await gasService.lastRefundAddress()).to.equal(await pool.getAddress());
    expect(await gasService.lastValue()).to.be.gt(0);
    expect(await token.balanceOf(await migrator.getAddress())).to.equal(MIGRATION_AMOUNT);
    expect(await pool.balance(await token.getAddress(), user.address)).to.equal(0);
  });

  it("execute() with a WITHDRAW payload transfers tokens to the recipient", async function () {
    const { owner, recipient, token, gateway, migrator } = await deployFixture();

    await token.transfer(await migrator.getAddress(), MIGRATION_AMOUNT);

    const payload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint8", "address", "uint256", "string"],
      [1, await token.getAddress(), MIGRATION_AMOUNT, recipient.address.toLowerCase()]
    );
    const commandId = await approveGateway(
      gateway,
      migrator,
      STELLAR_CHAIN,
      STELLAR_HANDLER,
      payload
    );

    await expect(
      migrator.execute(commandId, STELLAR_CHAIN, STELLAR_HANDLER, payload)
    )
      .to.emit(migrator, "BridgeWithdraw")
      .withArgs(await token.getAddress(), MIGRATION_AMOUNT, recipient.address);

    expect(await token.balanceOf(recipient.address)).to.equal(MIGRATION_AMOUNT);
    expect(await token.balanceOf(await migrator.getAddress())).to.equal(0);
    expect(owner.address).to.not.equal(recipient.address);
  });

  it("execute() with an invalid source chain reverts", async function () {
    const { recipient, token, gateway, migrator } = await deployFixture();

    const badSourceChain = "not-stellar";
    const payload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint8", "address", "uint256", "string"],
      [1, await token.getAddress(), MIGRATION_AMOUNT, recipient.address.toLowerCase()]
    );
    const commandId = await approveGateway(
      gateway,
      migrator,
      badSourceChain,
      STELLAR_HANDLER,
      payload
    );

    await expect(
      migrator.execute(commandId, badSourceChain, STELLAR_HANDLER, payload)
    ).to.be.revertedWithCustomError(migrator, "InvalidSourceChain");
  });

  it("execute() with an invalid message type reverts", async function () {
    const { recipient, token, gateway, migrator } = await deployFixture();

    const payload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint8", "address", "uint256", "string"],
      [9, await token.getAddress(), MIGRATION_AMOUNT, recipient.address.toLowerCase()]
    );
    const commandId = await approveGateway(
      gateway,
      migrator,
      STELLAR_CHAIN,
      STELLAR_HANDLER,
      payload
    );

    await expect(
      migrator.execute(commandId, STELLAR_CHAIN, STELLAR_HANDLER, payload)
    ).to.be.revertedWithCustomError(migrator, "InvalidMessageType");
  });

  it("migrate() with a zero amount reverts", async function () {
    const { user, other, token, migrator } = await deployFixture();

    await expect(
      migrator
        .connect(user)
        .migrate(user.address, [await token.getAddress()], other.address, [0])
    ).to.be.revertedWithCustomError(migrator, "ZeroAmount");
  });

  it("setDestination is only callable by the owner", async function () {
    const { owner, other, migrator } = await deployFixture();

    await expect(
      migrator.connect(other).setDestination("stellar-2025-q2", "CBRIDGEHANDLER")
    )
      .to.be.revertedWithCustomError(migrator, "OwnableUnauthorizedAccount")
      .withArgs(other.address);

    await migrator
      .connect(owner)
      .setDestination("stellar-2025-q2", "CBRIDGEHANDLER");

    expect(await migrator.destinationChain()).to.equal("stellar-2025-q2");
    expect(await migrator.destinationAddress()).to.equal("CBRIDGEHANDLER");
    expect(await migrator.trustedSourceChain()).to.equal("stellar-2025-q2");
    expect(await migrator.trustedSourceAddress()).to.equal("CBRIDGEHANDLER");
  });

  it("withdrawStuckTokens is only callable by the owner", async function () {
    const { owner, other, token, migrator } = await deployFixture();

    await token.transfer(await migrator.getAddress(), MIGRATION_AMOUNT);

    await expect(
      migrator
        .connect(other)
        .withdrawStuckTokens(await token.getAddress(), MIGRATION_AMOUNT)
    )
      .to.be.revertedWithCustomError(migrator, "OwnableUnauthorizedAccount")
      .withArgs(other.address);

    await expect(
      migrator
        .connect(owner)
        .withdrawStuckTokens(await token.getAddress(), MIGRATION_AMOUNT)
    ).to.changeTokenBalances(
      token,
      [migrator, owner],
      [-MIGRATION_AMOUNT, MIGRATION_AMOUNT]
    );
  });
});

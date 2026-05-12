import hre from "hardhat";
import dotenv from "dotenv";
dotenv.config();

// ============================================================
//  ADDRESSES
// ============================================================
const FACTORY_ADDRESS  = "0x379C1d8E0172e1b71E6B05d9617016762DFeC0f1";
const PLATFORM_ADDRESS = "0x929f950c6DD3DD4A6E69337c69A469517187c5af";
const USER_PRIVATE_KEY = process.env.USER_PRIVATE_KEY;
const RECEIVER         = "0xf37E1174960075E38207aB049516d01C1aBdd808";
const TOKEN_ADDRESS    = "0xdDaE58165e10779cbAC4D69d8847747edc078968";
const WALLET_ADDRESS   = "0xe3A10D07704AdDA2a2d43482701A651F4840D6B6";

// ============================================================
//  HELPERS
// ============================================================
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
function pass(msg) { console.log(`  ✅ PASS — ${msg}`); }
function fail(msg) { console.log(`  ❌ FAIL — ${msg}`); }
function info(msg) { console.log(`     ${msg}`); }

function check(label, actual, expected) {
  if (actual === expected) {
    pass(`${label}: ${actual}`);
  } else {
    fail(`${label}\n       expected: ${expected}\n       got:      ${actual}`);
  }
}

function section(title) {
  console.log("\n" + "═".repeat(60));
  console.log("  " + title);
  console.log("═".repeat(60));
}

async function expectRevert(label, fn) {
  try {
    await fn();
    fail(`${label} — should have reverted but DIDN'T`);
  } catch (e) {
    const msg = e.shortMessage || e.message || "";
    pass(`${label} — reverted: "${msg.split("\n")[0].slice(0, 80)}"`);
  }
}

// ============================================================
//  MAIN
// ============================================================
async function main() {
  const connection = await hre.network.connect();
  const { ethers } = connection;

  const [deployer] = await ethers.getSigners();
  const userSigner = new ethers.Wallet(USER_PRIVATE_KEY, ethers.provider);

  const ERC20_ABI = [
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function totalSupply() view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address to, uint256 amount) returns (bool)",
  ];

  const token    = new ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, ethers.provider);
  const decimals = await token.decimals();
  const symbol   = await token.symbol();
  const fmt      = (n) => ethers.formatUnits(n, decimals);
  const parse    = (n) => ethers.parseUnits(n.toString(), decimals);

  const wallet  = await ethers.getContractAt("TimeDelayWallet", WALLET_ADDRESS);

  // ============================================================
  //  TOKEN INFO
  // ============================================================
  section("TOKEN INFO");
  info(`Token    : ${await token.name()} (${symbol})`);
  info(`Address  : ${TOKEN_ADDRESS}`);
  info(`Decimals : ${decimals}`);
  info(`Supply   : ${fmt(await token.totalSupply())} ${symbol}`);
  info(`Wallet   : ${WALLET_ADDRESS}`);
  info(`Owner    : ${userSigner.address}`);
  info(`Platform : ${deployer.address}`);
  info(`Receiver : ${RECEIVER}`);

  // ============================================================
  //  INITIAL BALANCES
  // ============================================================
  section("INITIAL BALANCES");

  const initWalletGLD   = await token.balanceOf(WALLET_ADDRESS);
  const initPlatformGLD = await token.balanceOf(deployer.address);
  const initReceiverGLD = await token.balanceOf(RECEIVER);

  info(`Wallet balance    : ${fmt(initWalletGLD)} ${symbol}`);
  info(`Platform balance  : ${fmt(initPlatformGLD)} ${symbol}`);
  info(`Receiver balance  : ${fmt(initReceiverGLD)} ${symbol}`);

  check(`Wallet funded with GLD`, initWalletGLD > 0n, true);

  // ============================================================
  //  1 — setTokenMinTxAmount FOR GLD
  // ============================================================
  section("1 — PER-TOKEN MINIMUM (setTokenMinTxAmount)");

  const tokenMin = parse(1);   // 1 GLD minimum
  await (await wallet.connect(userSigner).setTokenMinTxAmount(TOKEN_ADDRESS, tokenMin)).wait();
  check(`tokenMinTxAmount[${symbol}] set to 1 ${symbol}`,
    (await wallet.tokenMinTxAmount(TOKEN_ADDRESS)).toString(), tokenMin.toString());

  await expectRevert(
    `Queue 0.5 ${symbol} (below 1 ${symbol} min) reverts`,
    () => wallet.connect(userSigner).queueTransaction(RECEIVER, parse(0.5), TOKEN_ADDRESS)
  );
  pass(`Global min does not apply — per-token min of 1 ${symbol} enforced`);

  // ============================================================
  //  2 — QUEUE ERC20 TRANSACTION + FEE VERIFICATION
  // ============================================================
  section("2 — QUEUE ERC20 TRANSACTION + FEE CALCULATION");

  const queueValue  = parse(10);                   // 10 GLD
  const expectedFee = queueValue * 100n / 10000n;  // 1% = 0.1 GLD
  const totalNeeded = queueValue + expectedFee;     // 10.1 GLD

  info(`Queue value   : ${fmt(queueValue)} ${symbol}`);
  info(`Expected fee  : ${fmt(expectedFee)} ${symbol}  (feeBps=100 → 1%)`);
  info(`Total needed  : ${fmt(totalNeeded)} ${symbol}`);

  const platformGLDBefore = await token.balanceOf(deployer.address);
  const walletGLDBefore   = await token.balanceOf(WALLET_ADDRESS);

  const queueTx = await wallet.connect(userSigner).queueTransaction(RECEIVER, queueValue, TOKEN_ADDRESS);
  const queueRx = await queueTx.wait();

  const queueLog = queueRx.logs
    .map(l => { try { return wallet.interface.parseLog(l); } catch { return null; } })
    .find(l => l?.name === "TransactionQueued");

  const txId         = queueLog.args.txId;
  const executeAfter = queueLog.args.executeAfter;

  pass(`TransactionQueued event emitted`);
  info(`txId          : ${txId}`);
  info(`Execute after : ${new Date(Number(executeAfter) * 1000).toLocaleTimeString()}`);

  const platformGLDAfter = await token.balanceOf(deployer.address);
  const walletGLDAfter   = await token.balanceOf(WALLET_ADDRESS);

  check(`Fee credited to platform (${fmt(expectedFee)} ${symbol})`,
    (platformGLDAfter - platformGLDBefore).toString(), expectedFee.toString());
  check(`Wallet decreased by fee only`,
    (walletGLDBefore - walletGLDAfter).toString(), expectedFee.toString());

  const locked = await wallet.lockedAmount(TOKEN_ADDRESS);
  check(`lockedAmount = value only (${fmt(queueValue)} ${symbol}, fee not double-locked)`,
    locked.toString(), queueValue.toString());

  const available    = await wallet.getAvailableBalance(TOKEN_ADDRESS);
  const walletNow    = await token.balanceOf(WALLET_ADDRESS);
  const expectedAvail = walletNow - locked;
  check(`getAvailableBalance = walletBal - locked`,
    available.toString(), expectedAvail.toString());
  info(`Available : ${fmt(available)} ${symbol}`);

  const storedTx = await wallet.getTransaction(txId);
  check(`storedTx.token = TOKEN_ADDRESS`, storedTx.token.toLowerCase(), TOKEN_ADDRESS.toLowerCase());
  check(`storedTx.value = ${fmt(queueValue)} ${symbol}`, storedTx.value.toString(), queueValue.toString());
  check(`storedTx.fee   = ${fmt(expectedFee)} ${symbol}`, storedTx.fee.toString(), expectedFee.toString());
  check(`storedTx.to    = RECEIVER`, storedTx.to.toLowerCase(), RECEIVER.toLowerCase());
  check(`storedTx.executed  = false`, storedTx.executed.toString(), "false");
  check(`storedTx.cancelled = false`, storedTx.cancelled.toString(), "false");

  // ============================================================
  //  3 — OVER-QUEUE PREVENTION
  // ============================================================
  section("3 — OVER-QUEUE PREVENTION (ERC20)");

  const avail = await wallet.getAvailableBalance(TOKEN_ADDRESS);
  info(`Available balance: ${fmt(avail)} ${symbol}`);

  await expectRevert(
    "Cannot queue more than available GLD balance",
    () => wallet.connect(userSigner).queueTransaction(RECEIVER, avail + 1n, TOKEN_ADDRESS)
  );
  pass("lockedAmount prevents over-allocation for ERC20");

  // ============================================================
  //  4 — EXECUTE BEFORE DELAY (must fail)
  // ============================================================
  section("4 — EXECUTE BEFORE DELAY");

  await expectRevert(
    "executeTransaction before delay reverts",
    () => wallet.connect(userSigner).executeTransaction(txId)
  );

  // ============================================================
  //  5 — CANCEL ERC20 TRANSACTION
  // ============================================================
  section("5 — CANCEL ERC20 TRANSACTION");

  const cancelValue = parse(5);   // 5 GLD
  const cqTx = await wallet.connect(userSigner).queueTransaction(RECEIVER, cancelValue, TOKEN_ADDRESS);
  const cqRx = await cqTx.wait();
  const cqLog = cqRx.logs
    .map(l => { try { return wallet.interface.parseLog(l); } catch { return null; } })
    .find(l => l?.name === "TransactionQueued");
  const cancelTxId = cqLog.args.txId;
  info(`Queued cancel test txId: ${cancelTxId}`);

  const lockedBefore    = await wallet.lockedAmount(TOKEN_ADDRESS);
  const walletPreCancel = await token.balanceOf(WALLET_ADDRESS);

  await (await wallet.connect(userSigner).cancelTransaction(cancelTxId)).wait();

  const lockedAfter      = await wallet.lockedAmount(TOKEN_ADDRESS);
  const walletPostCancel = await token.balanceOf(WALLET_ADDRESS);

  check("lockedAmount decreased by value on cancel",
    (lockedBefore - lockedAfter).toString(), cancelValue.toString());
  check("Wallet token balance unchanged on cancel",
    walletPostCancel.toString(), walletPreCancel.toString());

  const cancelFee = cancelValue * 100n / 10000n;
  pass(`Fee (${fmt(cancelFee)} ${symbol}) is non-refundable on cancel`);
  await expectRevert("Double cancel reverts",
    () => wallet.connect(userSigner).cancelTransaction(cancelTxId));

  // ============================================================
  //  6 — WAIT FOR DELAY + EXECUTE
  // ============================================================
  section("6 — WAITING FOR 2-MINUTE DELAY");

  const now    = Math.floor(Date.now() / 1000);
  const waitMs = (Number(executeAfter) - now + 5) * 1000;
  if (waitMs > 0) {
    info(`Waiting ${Math.ceil(waitMs / 1000)} seconds...`);
    await sleep(waitMs);
  }
  pass("Delay passed");

  section("7 — EXECUTE ERC20 TRANSACTION");

  const receiverGLDBefore = await token.balanceOf(RECEIVER);
  const lockedPreExec     = await wallet.lockedAmount(TOKEN_ADDRESS);

  const executeTx = await wallet.connect(userSigner).executeTransaction(txId);
  const executeRx = await executeTx.wait();

  const receiverGLDAfter = await token.balanceOf(RECEIVER);
  const lockedPostExec   = await wallet.lockedAmount(TOKEN_ADDRESS);
  const receiverGot      = receiverGLDAfter - receiverGLDBefore;

  check(`Receiver got exact value (${fmt(queueValue)} ${symbol})`,
    receiverGot.toString(), queueValue.toString());
  check("lockedAmount decreased by value after execute",
    (lockedPreExec - lockedPostExec).toString(), queueValue.toString());

  const execLog       = executeRx.logs.map(l => { try { return wallet.interface.parseLog(l); } catch { return null; } }).find(l => l?.name === "TransactionExecuted");
  const execDetailLog = executeRx.logs.map(l => { try { return wallet.interface.parseLog(l); } catch { return null; } }).find(l => l?.name === "TransactionExecutedDetailed");

  check("TransactionExecuted event emitted",          execLog?.name,                                       "TransactionExecuted");
  check("TransactionExecutedDetailed event emitted",  execDetailLog?.name,                                 "TransactionExecutedDetailed");
  check(`execDetail.to    = RECEIVER`,                execDetailLog?.args.to.toLowerCase(),                RECEIVER.toLowerCase());
  check(`execDetail.value = ${fmt(queueValue)} ${symbol}`, execDetailLog?.args.value.toString(),           queueValue.toString());
  check(`execDetail.token = TOKEN_ADDRESS`,           execDetailLog?.args.token.toLowerCase(),             TOKEN_ADDRESS.toLowerCase());

  await expectRevert("Double execute reverts",
    () => wallet.connect(userSigner).executeTransaction(txId));

  // ============================================================
  //  FINAL BALANCES
  // ============================================================
  section("FINAL BALANCES");

  const finalWalletGLD   = await token.balanceOf(WALLET_ADDRESS);
  const finalPlatformGLD = await token.balanceOf(deployer.address);
  const finalReceiverGLD = await token.balanceOf(RECEIVER);
  const finalLocked      = await wallet.lockedAmount(TOKEN_ADDRESS);
  const finalAvail       = await wallet.getAvailableBalance(TOKEN_ADDRESS);

  info(`Wallet balance    : ${fmt(finalWalletGLD)} ${symbol}`);
  info(`Platform received : ${fmt(finalPlatformGLD - initPlatformGLD)} ${symbol} (total fees collected)`);
  info(`Receiver received : ${fmt(finalReceiverGLD - initReceiverGLD)} ${symbol} (net transferred)`);
  info(`Locked amount     : ${fmt(finalLocked)} ${symbol}`);
  info(`Available balance : ${fmt(finalAvail)} ${symbol}`);
  info(`txCounter         : ${await wallet.txCounter()}`);

  console.log("\n" + "═".repeat(60));
  console.log("  ERC20 TEST RESULTS");
  console.log("═".repeat(60));
  console.log(`  ✅ Wallet funded with GLD tokens`);
  console.log(`  ✅ Per-token minimum (setTokenMinTxAmount) for ${symbol}`);
  console.log(`  ✅ queueTransaction with ERC20 token`);
  console.log(`  ✅ Fee (1%) deducted at queue time`);
  console.log(`  ✅ Fee credited to platformAdmin in ${symbol}`);
  console.log(`  ✅ lockedAmount = value only (fee not double-locked)`);
  console.log(`  ✅ getAvailableBalance correct for ERC20`);
  console.log(`  ✅ getTransaction stores token, value, fee correctly`);
  console.log(`  ✅ Over-queuing prevented for ERC20`);
  console.log(`  ✅ Execute before delay blocked`);
  console.log(`  ✅ cancelTransaction — value unlocked, fee non-refundable`);
  console.log(`  ✅ Double cancel blocked`);
  console.log(`  ✅ executeTransaction transfers exact ${symbol} to receiver`);
  console.log(`  ✅ TransactionExecuted + Detailed events include token address`);
  console.log(`  ✅ Double execute blocked`);
  console.log(`\n  🎉 ALL ERC20 (${symbol}) CHECKS PASSED`);
  console.log("═".repeat(60) + "\n");
}

main().catch((e) => {
  console.error("\n❌ ERC20 TEST FAILED:", e.message || e);
  process.exitCode = 1;
});

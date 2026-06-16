# Time Secure Wallet

A non-custodial smart contract wallet with a mandatory time delay between scheduling and executing transfers. Built on Solidity using the EIP-1167 minimal proxy (clone) pattern for gas-efficient deployment.

Deployed on **XHAVIC L2** and **Sepolia** testnets.

---

## How It Works

1. Owner **queues** a transfer — funds are locked, a platform fee is taken immediately, and a delay timer starts.
2. After the delay passes, the owner **executes** the transfer to release funds to the recipient.
3. At any point before execution, the owner can **cancel** — funds return, fee is non-refundable.

The delay is a security feature: it gives time to detect and cancel unauthorized transactions.

---

## Key Features

- **Time-locked transfers** — mandatory delay before any funds can leave the wallet
- **EIP-1167 clone factory** — every user gets their own isolated wallet contract at minimal gas cost
- **Fee-at-queue-time** — platform fee is snapshotted and sent immediately; future fee changes don't affect queued transactions
- **Pause / unpause** — platform admin can freeze new queues without blocking cancellations
- **Two-step ownership transfer** — prevents accidental wallet lockout
- **ERC-20 support** — works with native coin and any ERC-20 token

---

## Deployed Contracts

| Network | Contract | Address |
|---------|----------|---------|
| XHAVIC Testnet | WalletFactory | `0xE4FC0db39138dd457C9b4b4DA73Bf3e19cec7F37` |
| Sepolia Testnet | WalletFactory | `0x0301327589710f6A9978cbf77D02C914902b76A3` |

> **Note:** `DELAY` is currently set to `2 minutes` for testnet. It must be changed to `86400` (24 hours) before mainnet deployment.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Smart Contracts | Solidity ^0.8.20 |
| Framework | Hardhat v3 |
| Libraries | OpenZeppelin Contracts v5 |
| Web3 | ethers.js v6 |
| Networks | XHAVIC L2 (Chain ID: 16585), Sepolia |

---

## Prerequisites

- [Node.js](https://nodejs.org/) v18 or higher
- npm v9 or higher
- A wallet with testnet funds (XVC or SepoliaETH)

---

## Installation

```bash
git clone <repo-url>
cd timedelay-wallet
npm install
```

---

## Configuration

Create a `.env` file in the project root:

```env
# Your deployer/signer private key (without 0x prefix)
PRIVATE_KEY=your_private_key_here

# RPC URLs
SEPOLIA_RPC_URL=https://rpc.sepolia.org
XHAVIC_RPC_URL=https://testrpc.xhaviscan.com
```

> Never commit your `.env` file. It is already listed in `.gitignore`.

---

## Compile Contracts

```bash
npx hardhat compile
```

---

## Deploy

### Deploy to XHAVIC Testnet

```bash
npx hardhat run scripts/deploy.js --network xhavic
```

### Deploy to Sepolia

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

The deploy script:
1. Deploys `TimeDelayWallet` implementation contract
2. Deploys `WalletFactory` with the implementation address and your address as `platformAdmin`
3. Logs both contract addresses

---

## Usage

### Create a Wallet

Call `createWallet()` on the `WalletFactory` contract. This deploys a personal `TimeDelayWallet` clone assigned to your address.

### Queue a Transfer

```solidity
wallet.queueTransaction(recipientAddress, amountInWei, tokenAddress)
// Use address(0) as tokenAddress for native coin (XVC/ETH)
```

Returns a `txId`. Fee is sent to `platformAdmin` immediately and is non-refundable.

### Execute a Transfer

After the delay has passed:

```solidity
wallet.executeTransaction(txId)
```

### Cancel a Transfer

Before execution (works even when the wallet is paused):

```solidity
wallet.cancelTransaction(txId)
```

---

## Project Structure

```
timedelay-wallet/
├── contracts/
│   ├── TimeDelayWallet.sol    # Core wallet logic — time delay, queue, execute, cancel
│   └── WalletFactory.sol      # EIP-1167 clone factory + owner registry
├── scripts/
│   └── deploy.js              # Deployment script
├── test/
│   └── Lock.js                # Contract tests
├── hardhat.config.js          # Network config (XHAVIC, Sepolia)
└── .env                       # Environment variables (not committed)
```

---

## Network Info

| Property | Value |
|----------|-------|
| Network Name | XHAVIC Testnet |
| Chain ID | 16585 |
| RPC URL | https://testrpc.xhaviscan.com |
| Block Explorer | https://xhaviscan.com |

---

## Security Notes

- This project is pending a third-party smart contract audit.
- The `DELAY` constant must be updated to `86400` (24 hours) before any mainnet deployment.
- The `minTxAmount` default (`1e13`) is calibrated for 18-decimal tokens. Review before using with tokens like USDC (6 decimals).
- Platform admin has the ability to pause new queues and update the fee rate — it cannot move user funds.

---

## License

MIT

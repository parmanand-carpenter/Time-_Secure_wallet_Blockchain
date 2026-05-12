// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TimeDelayWallet
/// @notice Non-custodial escrow wallet with a mandatory time delay between
///         scheduling and executing transfers. Deployed as an EIP-1167 clone.
/// @dev Uses CEI pattern throughout. Fee is collected at queue time and is non-refundable.
contract TimeDelayWallet is ReentrancyGuard {

    using SafeERC20 for IERC20;

    address public owner;
    address public pendingOwner; // set during two-step ownership transfer

    // ================= PLATFORM CONTROL =================

    address public platformAdmin;
    address public pendingPlatformAdmin; // set during two-step platform admin transfer

    // ================= COMMISSION =================

    /// @notice Fee rate in basis points. 100 = 1%, max 500 = 5%.
    uint256 public feeBps;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ================= CORE =================

    uint256 public constant DELAY = 24 hours;

    bool public initialized;

    /// @notice Represents a single queued transfer.
    /// @param executeAfter Timestamp after which execution is allowed (block.timestamp + DELAY).
    /// @param fee Fee snapshot at queue time — immune to future updateFee() calls.
    struct Transaction {
        address to;
        uint256 value;
        address token;      // address(0) = native coin
        uint256 executeAfter;
        uint256 fee;
        bool executed;
        bool cancelled;
    }

    uint256 public txCounter;
    mapping(uint256 => Transaction) public transactions;

    /// @notice Tracks locked value per token for pending transactions.
    ///         Only _value is tracked here — fee is sent to platformAdmin immediately.
    mapping(address => uint256) public lockedAmount;

    /// @dev Fallback global minimum. Use setTokenMinTxAmount for per-token overrides.
    uint256 public minTxAmount;

    /// @notice Per-token minimum transaction amount. Overrides minTxAmount when set.
    mapping(address => uint256) public tokenMinTxAmount;

    /// @notice Accumulated fees that could not be transferred directly to platformAdmin.
    mapping(address => uint256) public unclaimedFees;

    /// @notice When paused, only queueTransaction is blocked. executeTransaction remains available.
    bool public paused;

    // ================= EVENTS =================

    event Initialized(address owner);
    event TransactionQueued(
        uint256 indexed txId,
        address indexed to,
        uint256 value,
        address token,
        uint256 executeAfter
    );
    event TransactionExecuted(uint256 indexed txId);
    event TransactionExecutedDetailed(uint256 indexed txId, address indexed to, uint256 value, address token);
    event TransactionCancelled(uint256 indexed txId);
    event TransactionCancelledDetailed(uint256 indexed txId, address token, uint256 value);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event PauseToggled(bool paused);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event PlatformAdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event PlatformAdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // ================= MODIFIERS =================

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyPlatform() {
        require(msg.sender == platformAdmin, "Not platform");
        _;
    }

    /// @dev Not applied to cancelTransaction or executeTransaction — users must always be able to exit.
    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    // ================= CONSTRUCTOR =================

    /// @dev Locks the implementation contract. All user wallets are clones initialized via initialize().
    constructor() {
        initialized = true;
    }

    // ================= INITIALIZE =================

    /// @notice One-time setup called by WalletFactory after cloning.
    /// @param _owner Wallet owner address.
    /// @param _platformAdmin Receives fees and has admin controls.
    function initialize(
        address _owner,
        address _platformAdmin
    ) external {
        require(!initialized, "Already initialized");
        require(_owner != address(0), "Invalid owner");
        require(_platformAdmin != address(0), "Invalid platform");

        owner = _owner;
        platformAdmin = _platformAdmin;
        feeBps = 100;
        minTxAmount = 1e13;

        initialized = true;

        emit Initialized(_owner);
    }

    // ================= RECEIVE =================

    receive() external payable {}

    // ================= QUEUE =================

    /// @notice Schedules a transfer after the delay. Fee is sent to platformAdmin immediately.
    /// @dev Follows Checks-Effects-Interactions. Fee is snapshotted — future updateFee() won't affect this tx.
    /// @param _to Recipient address.
    /// @param _value Transfer amount. Available balance must cover _value + fee.
    /// @param _token Token address. Use address(0) for native ETH/XVC.
    /// @return txId Use this ID to execute or cancel later.
    function queueTransaction(
        address _to,
        uint256 _value,
        address _token
    )
        external
        onlyOwner
        nonReentrant
        notPaused
        returns (uint256)
    {
        // CHECKS
        uint256 effectiveMin = tokenMinTxAmount[_token] > 0 ? tokenMinTxAmount[_token] : minTxAmount;
        require(_value >= effectiveMin, "Below minimum transaction amount");
        require(_to != address(0), "Invalid recipient");

        uint256 fee = (_value * feeBps) / BPS_DENOMINATOR;
        uint256 totalRequired = _value + fee;

        if (_token == address(0)) {
            uint256 balance = address(this).balance;
            require(balance >= lockedAmount[address(0)], "Lock overflow");
            require(balance - lockedAmount[address(0)] >= totalRequired, "Insufficient available balance");
        } else {
            uint256 balance = IERC20(_token).balanceOf(address(this));
            require(balance >= lockedAmount[_token], "Lock overflow");
            require(balance - lockedAmount[_token] >= totalRequired, "Insufficient available balance");
        }

        // EFFECTS
        uint256 txId = txCounter;

        // Fee is non-refundable on cancellation
        transactions[txId] = Transaction({
            to: _to,
            value: _value,
            token: _token,
            executeAfter: block.timestamp + DELAY,
            fee: fee,
            executed: false,
            cancelled: false
        });

        txCounter++;
        lockedAmount[_token] += _value;

        emit TransactionQueued(txId, _to, _value, _token, block.timestamp + DELAY);

        // INTERACTIONS
        if (fee > 0) {
            if (_token == address(0)) {
                (bool feeSent, ) = platformAdmin.call{value: fee}("");
                require(feeSent, "Fee transfer failed");
            } else {
                // Accumulate fee locally if platformAdmin is blocklisted by the token issuer,
                // preventing a permanent DoS on queueTransaction for that token.
                try IERC20(_token).transfer(platformAdmin, fee) returns (bool sent) {
                    if (!sent) {
                        unclaimedFees[_token] += fee;
                    }
                } catch {
                    unclaimedFees[_token] += fee;
                }
            }
        }

        return txId;
    }

    // ================= EXECUTE =================

    /// @notice Executes a queued transaction after the delay has elapsed.
    /// @dev CEI: txn.executed = true and lockedAmount decremented before external transfer.
    ///      notPaused is intentionally omitted — users must be able to execute pending txs even when paused.
    /// @param _txId Transaction ID to execute.
    function executeTransaction(uint256 _txId)
        external
        onlyOwner
        nonReentrant
    {
        require(_txId < txCounter, "Invalid txId");

        Transaction storage txn = transactions[_txId];

        require(!txn.executed, "Already executed");
        require(!txn.cancelled, "Cancelled");
        require(block.timestamp >= txn.executeAfter, "Too early");

        txn.executed = true;

        require(lockedAmount[txn.token] >= txn.value, "Unlock overflow");
        lockedAmount[txn.token] -= txn.value;

        if (txn.token == address(0)) {
            (bool success, ) = txn.to.call{value: txn.value}("");
            require(success, "Native transfer failed");
        } else {
            // Use actual available balance to guard against fee-on-transfer / rebasing token drift.
            uint256 available = IERC20(txn.token).balanceOf(address(this));
            uint256 toSend = txn.value > available ? available : txn.value;
            IERC20(txn.token).safeTransfer(txn.to, toSend);
        }

        emit TransactionExecuted(_txId);
        emit TransactionExecutedDetailed(_txId, txn.to, txn.value, txn.token);
    }

    // ================= CANCEL =================

    /// @notice Cancels a queued transaction. Callable even when paused. Fee is NOT returned.
    /// @param _txId Transaction ID to cancel.
    function cancelTransaction(uint256 _txId)
        external
        onlyOwner
    {
        require(_txId < txCounter, "Invalid txId");

        Transaction storage txn = transactions[_txId];

        require(!txn.executed, "Already executed");
        require(!txn.cancelled, "Already cancelled");

        txn.cancelled = true;

        require(lockedAmount[txn.token] >= txn.value, "Unlock overflow");
        lockedAmount[txn.token] -= txn.value;

        emit TransactionCancelled(_txId);
        emit TransactionCancelledDetailed(_txId, txn.token, txn.value);
    }

    // ================= PAUSE =================

    /// @param _paused True to pause (blocks new queues only), false to unpause.
    function setPaused(bool _paused) external onlyPlatform {
        paused = _paused;
        emit PauseToggled(_paused);
    }

    // ================= VIEWS =================

    /// @notice Returns available (unlocked) balance for a token.
    /// @param _token Use address(0) for native ETH/XVC.
    function getAvailableBalance(address _token) public view returns (uint256) {
        uint256 balance = _token == address(0)
            ? address(this).balance
            : IERC20(_token).balanceOf(address(this));
        return balance - lockedAmount[_token];
    }

    /// @notice Returns the Transaction struct for a given txId.
    function getTransaction(uint256 _txId) external view returns (Transaction memory) {
        return transactions[_txId];
    }

    // ================= UPDATE COMMISSION =================

    /// @notice Updates fee rate. Only affects future queues — existing txs keep their snapshot.
    /// @param _newFeeBps New rate in BPS. Max 500 (5%).
    function updateFee(uint256 _newFeeBps) external onlyPlatform {
        require(_newFeeBps <= 500, "Fee too high");
        emit FeeUpdated(feeBps, _newFeeBps);
        feeBps = _newFeeBps;
    }

    /// @notice Step 1 of two-step platformAdmin transfer. New admin must call acceptPlatformAdmin().
    /// @param _newPlatformAdmin Must not be zero address.
    function updatePlatformAdmin(address _newPlatformAdmin) external onlyPlatform {
        require(_newPlatformAdmin != address(0), "Invalid address");
        pendingPlatformAdmin = _newPlatformAdmin;
        emit PlatformAdminTransferStarted(platformAdmin, _newPlatformAdmin);
    }

    /// @notice Step 2 of two-step platformAdmin transfer. Must be called by pendingPlatformAdmin.
    function acceptPlatformAdmin() external {
        require(msg.sender == pendingPlatformAdmin, "Not pending platform admin");
        address oldAdmin = platformAdmin;
        platformAdmin = pendingPlatformAdmin;
        pendingPlatformAdmin = address(0);
        emit PlatformAdminUpdated(oldAdmin, platformAdmin);
    }

    // ================= TOKEN MINIMUM =================

    /// @notice Sets a per-token minimum transaction amount, overriding the global minTxAmount.
    /// @dev Use this to correctly set minimums for low-decimal tokens such as USDC (6 decimals).
    /// @param _token Token address. Use address(0) for native coin.
    /// @param _min Minimum amount in the token's native decimals. Set to 0 to revert to global minimum.
    function setTokenMinTxAmount(address _token, uint256 _min) external onlyOwner {
        tokenMinTxAmount[_token] = _min;
    }

    // ================= CLAIM FEES =================

    /// @notice Allows platformAdmin to withdraw fees that accumulated when direct transfer failed.
    /// @param _token Token address. Use address(0) for native coin.
    function claimFees(address _token) external onlyPlatform {
        uint256 amount = unclaimedFees[_token];
        require(amount > 0, "No unclaimed fees");
        unclaimedFees[_token] = 0;
        if (_token == address(0)) {
            (bool sent, ) = platformAdmin.call{value: amount}("");
            require(sent, "Transfer failed");
        } else {
            IERC20(_token).safeTransfer(platformAdmin, amount);
        }
    }

    // ================= OWNERSHIP =================

    /// @notice Initiates two-step ownership transfer. New owner must call acceptOwnership().
    /// @param newOwner Candidate address. Must not be zero.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Completes ownership transfer. Must be called by pendingOwner.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }
}

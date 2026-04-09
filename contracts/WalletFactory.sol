// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./TimeDelayWallet.sol";

/// @title WalletFactory
/// @notice Deploys TimeDelayWallet clones via EIP-1167 and maintains an owner registry.
/// @dev platformAdmin is set once at construction and injected into every clone.
contract WalletFactory {

    /// @notice TimeDelayWallet implementation that all clones delegate to. Immutable.
    address public immutable implementation;

    /// @notice Platform admin injected into every clone. Receives fees. Immutable.
    address public immutable platformAdmin;

    // ================= REGISTRY =================

    mapping(address => address[]) private _wallets;      // owner → wallets[]
    mapping(address => address)   private _walletOwner;  // wallet → owner

    /// @notice Emitted when a new wallet clone is deployed.
    event WalletCreated(address indexed wallet, address indexed owner);

    /// @param _implementation Deployed TimeDelayWallet implementation address.
    /// @param _platformAdmin Platform admin address for all clones.
    constructor(
        address _implementation,
        address _platformAdmin
    ) {
        require(_implementation != address(0), "Invalid implementation");
        require(_platformAdmin != address(0), "Invalid platform");

        implementation = _implementation;
        platformAdmin = _platformAdmin;
    }

    /// @notice Deploys a new TimeDelayWallet clone for msg.sender.
    /// @return Address of the newly deployed wallet clone.
    function createWallet() external returns (address) {
        address payable clone = payable(Clones.clone(implementation));

        TimeDelayWallet(clone).initialize(
            msg.sender,
            platformAdmin
        );

        _wallets[msg.sender].push(clone);
        _walletOwner[clone] = msg.sender;

        emit WalletCreated(clone, msg.sender);

        return clone;
    }

    // ================= DISCOVERY =================

    /// @notice Returns all wallet addresses created by an owner.
    function getWallets(address _owner)
        external
        view
        returns (address[] memory)
    {
        return _wallets[_owner];
    }

    /// @notice Returns the number of wallets created by an owner.
    function getWalletCount(address _owner)
        external
        view
        returns (uint256)
    {
        return _wallets[_owner].length;
    }

    /// @notice Returns the owner of a wallet. Returns address(0) if not from this factory.
    function getWalletOwner(address _wallet)
        external
        view
        returns (address)
    {
        return _walletOwner[_wallet];
    }

    /// @notice Returns true if the wallet was created by the given owner through this factory.
    function isWalletOf(address _wallet, address _owner)
        external
        view
        returns (bool)
    {
        return _walletOwner[_wallet] == _owner;
    }
}

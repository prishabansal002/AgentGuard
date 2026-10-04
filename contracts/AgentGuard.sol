// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title AgentGuard
/// @notice AI proposes (and signs) payment intents; this contract decides whether they are allowed.
contract AgentGuard is Ownable, ReentrancyGuard, Pausable, EIP712 {
    struct Permission {
        address recipient;
        uint256 maxTx;
        uint256 dailyLimit;
        uint64 expiry;
        bool active;
        uint256 spentToday;
        uint64 lastDay;
    }

    struct PaymentIntent {
        address agent;
        address to;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bytes32 reasonHash;
    }

    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address agent,address to,uint256 amount,uint256 nonce,uint256 deadline,bytes32 reasonHash)"
    );

    mapping(address => bool) public registered;
    mapping(address => Permission) public permissions;
    mapping(address => uint256) public nonces;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event AgentRegistered(address indexed agent);
    event PermissionCreated(address indexed agent, address indexed recipient, uint256 maxTx, uint256 dailyLimit, uint64 expiry);
    event PermissionRevoked(address indexed agent);
    event PaymentExecuted(address indexed agent, address indexed to, uint256 amount, uint256 nonce, string reason);
    event SignedPaymentRelayed(address indexed agent, address indexed relayer);

    constructor() Ownable(msg.sender) EIP712("AgentGuard", "1") {}

    // ---------- Funds ----------
    receive() external payable { emit Deposited(msg.sender, msg.value); }

    function deposit() external payable { emit Deposited(msg.sender, msg.value); }

    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        require(address(this).balance >= amount, "insufficient vault balance");
        emit Withdrawn(owner(), amount);
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ---------- Owner controls ----------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerAgent(address agent) external onlyOwner {
        require(agent != address(0), "zero agent");
        registered[agent] = true;
        emit AgentRegistered(agent);
    }

    function createPermission(address agent, address recipient, uint256 maxTx, uint256 dailyLimit, uint64 expiry)
        external onlyOwner
    {
        require(registered[agent], "agent not registered");
        require(recipient != address(0), "zero recipient");
        require(maxTx > 0 && dailyLimit >= maxTx, "bad limits");
        require(expiry > block.timestamp, "expiry in past");

        permissions[agent] = Permission({
            recipient: recipient,
            maxTx: maxTx,
            dailyLimit: dailyLimit,
            expiry: expiry,
            active: true,
            spentToday: 0,
            lastDay: uint64(block.timestamp / 1 days)
        });
        emit PermissionCreated(agent, recipient, maxTx, dailyLimit, expiry);
    }

    function revokePermission(address agent) external onlyOwner {
        require(permissions[agent].recipient != address(0), "no permission");
        permissions[agent].active = false;
        emit PermissionRevoked(agent);
    }

    // ---------- Path 1: agent sends the tx itself ----------
    function executePayment(address to, uint256 amount, uint256 nonce, string calldata reason)
        external nonReentrant whenNotPaused
    {
        _pay(msg.sender, to, amount, nonce, reason);
    }

    // ---------- Path 2: agent SIGNS (EIP-712), anyone relays ----------
    function executeSigned(PaymentIntent calldata i, string calldata reason, bytes calldata signature)
        external nonReentrant whenNotPaused
    {
        require(block.timestamp <= i.deadline, "intent expired");
        require(keccak256(bytes(reason)) == i.reasonHash, "reason mismatch");
        require(
            SignatureChecker.isValidSignatureNow(i.agent, _hashTypedDataV4(_hashIntent(i)), signature),
            "bad signature"
        );
        emit SignedPaymentRelayed(i.agent, msg.sender);
        _pay(i.agent, i.to, i.amount, i.nonce, reason);
    }

    function _hashIntent(PaymentIntent calldata i) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_TYPEHASH, i.agent, i.to, i.amount, i.nonce, i.deadline, i.reasonHash));
    }

    // ---------- Single place where ALL rules are enforced ----------
    function _pay(address agent, address to, uint256 amount, uint256 nonce, string calldata reason) internal {
        Permission storage p = permissions[agent];

        // Checks
        require(registered[agent], "agent not registered");
        require(p.recipient != address(0), "no permission");
        require(p.active, "permission revoked");
        require(block.timestamp < p.expiry, "permission expired");
        require(nonce == nonces[agent], "invalid nonce");
        require(to == p.recipient, "recipient not authorized");
        require(amount > 0 && amount <= p.maxTx, "exceeds maximum transaction limit");

        uint64 today = uint64(block.timestamp / 1 days);
        uint256 spent = (p.lastDay == today) ? p.spentToday : 0;
        require(spent + amount <= p.dailyLimit, "exceeds daily limit");
        require(address(this).balance >= amount, "insufficient vault balance");

        // Effects
        nonces[agent] = nonce + 1;
        p.lastDay = today;
        p.spentToday = spent + amount;
        emit PaymentExecuted(agent, to, amount, nonce, reason);

        // Interaction
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "transfer failed");
    }

    // ---------- Views ----------
    function remainingDaily(address agent) external view returns (uint256) {
        Permission storage p = permissions[agent];
        if (p.recipient == address(0) || !p.active || block.timestamp >= p.expiry) return 0;
        uint256 spent = (p.lastDay == uint64(block.timestamp / 1 days)) ? p.spentToday : 0;
        return p.dailyLimit > spent ? p.dailyLimit - spent : 0;
    }

    function vaultBalance() external view returns (uint256) { return address(this).balance; }
}

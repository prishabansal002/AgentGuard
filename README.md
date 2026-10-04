# AgentGuard
On-chain permission and spending control for AI agents.

## Problem
AI agents are starting to pay for APIs and services on their own. Giving an agent a raw private key with a funded wallet means one prompt injection or bug can drain everything. Application-level checks (a database or a backend) live on a server that the agent's operator controls, and so they can be bypassed, edited or silently disabled.

## Solution
AgentGuard puts a smart contract between the AI agent and its funds. The AI can only *propose and sign* a payment intent. The contract holds the funds and independently decides whether the payment is authorized, according to rules set by the owner.

> The AI decides what it wants to do. The smart contract decides whether it is allowed to do it.

## Architecture
```
 Owner (MetaMask) ──register / permit / revoke / pause / deposit──┐
                                                                   ▼
 User text ─► AI parser ─► intent {recipient, amount, reason}   ┌───────────────┐
                              │                                 │  AgentGuard   │
                              ▼                                 │  smart        │
              Agent key signs EIP-712 PaymentIntent (off-chain) │  contract     │
                              │                                 │  (Sepolia)    │
                              ▼                                 │               │
              Relayer submits executeSigned() ─────────────────►│ checks rules  │
                                                                │ pays or       │
                                                                │ reverts       │
                                                                └───────────────┘
```

## Why Web3?
- The rules and the funds live in the same trust domain. The contract is both the policy and the vault, so there is no code path where the agent can spend without passing the checks.
- Permissions are public, auditable on-chain state, and every action emits an event.
- The owner keeps self-custody and can revoke or pause at any time with a transaction.
- Removing the contract removes the enforcement, so the blockchain is not decorative.

## Why AI?
The AI converts natural-language instructions (for example "pay 0.005 ETH to API Provider A") into structured intents. In this MVP the default parser is a simple deterministic parser, with a clearly marked hook (`parseWithLLM`) for an LLM API. The AI is not trusted for authorization.

## Security Model
| Threat | Mitigation |
|---|---|
| Agent or AI compromised | It can only pay the pre-approved recipient, within the per-transaction and daily limits, until expiry or revocation |
| Replay of a payment or signature | Per-agent on-chain nonce, and the EIP-712 domain binds chain ID and contract address |
| Tampered intent | EIP-712 signature verification fails (`bad signature`) |
| Stale signature | `deadline` field in the signed intent |
| Reentrancy | Checks-effects-interactions plus OpenZeppelin `ReentrancyGuard` |
| Unauthorized configuration | OpenZeppelin `Ownable` on all admin functions |
| Emergency | Owner can `pause()` all payments |

## Smart Contract Design
- `registerAgent`, `createPermission`, `revokePermission`, `pause/unpause`, `deposit`, `withdraw` (owner functions)
- `executePayment` (agent sends the transaction itself) and `executeSigned` (agent signs an EIP-712 `PaymentIntent`, any relayer submits)
- One internal function `_pay` enforces every rule for both paths: registered, permission exists, active, not expired, correct nonce, allowed recipient, max per transaction, daily limit, sufficient vault balance
- Signature validation uses OpenZeppelin `SignatureChecker`, which supports EOAs and ERC-1271 contract wallets
- Events: `Deposited`, `AgentRegistered`, `PermissionCreated`, `PermissionRevoked`, `PaymentExecuted`, `SignedPaymentRelayed`, `Withdrawn`

## How to Run
1. Open Remix (remix.ethereum.org), create `contracts/AgentGuard.sol`, compile with Solidity 0.8.24 and optimization enabled.
2. Deploy to Sepolia with the Injected Provider (MetaMask, a TEST account only).
3. Put the contract address, a TEST agent key and the recipient addresses in the config block of `index.html`.
4. Open `index.html` in Chrome with MetaMask installed.
Use throwaway test wallets only. The agent key in the page is for demo purposes.

## Demo
1. Valid: 0.005 ETH to the allowed recipient is authorized and the funds move on-chain.
2. 0.02 ETH exceeds the maximum transaction limit and is rejected.
3. 0.005 ETH to an unauthorized address is rejected (recipient not authorized).
4. After the owner revokes the permission, the next payment is rejected (permission revoked).
5. A tampered signed intent is rejected (bad signature).
6. After the owner pauses the contract, payments are rejected.

## Limitations
- The agent's key is held in the browser page for the demo; a real system needs a backend or a smart-account wallet.
- ETH only, one recipient per agent, one owner key (no multisig).
- The daily limit uses UTC calendar days, not a rolling window.
- The default intent parser is not an LLM; the LLM hook is optional.
- Not audited and tested only on a testnet.

## Future Improvements
- ERC-20 / stablecoin payments and multiple allowed recipients
- Rolling-window limits and per-recipient limits
- Smart-account (ERC-4337) agent wallets with session keys
- Multisig or timelock for the owner role
- Automated Hardhat/Foundry test suite and a formal audit# AgentGuard
On chain permission and spending control for AI agents

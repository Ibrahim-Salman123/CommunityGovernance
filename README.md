# CommunityGovernance — On-Chain DAO Voting

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Networks](https://img.shields.io/badge/Networks-Ethereum%20%7C%20Polygon%20%7C%20Arbitrum%20%7C%20Base-purple)]()

---

## Problem Statement

Most communities (DAOs, co-ops, neighbourhood associations) lack a tamper-proof, transparent voting mechanism. Traditional platforms (Snapshot, Tally) either rely on off-chain signatures with no binding enforcement, or require complex governor frameworks. This contract provides a self-contained, permissionless, on-chain governance layer that works with **any ERC-20 governance token**.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                CommunityGovernance                   │
│                                                      │
│  propose()  ──► Active  ──► Succeeded ──► execute()  │
│                    │                                 │
│                    └──► Defeated  (quorum not met    │
│                         or against > for)            │
│                                                      │
│  cancel()  ──► Cancelled  (proposer only)            │
└──────────────────────────────────────────────────────┘
         │  reads balanceOf()
         ▼
   ERC-20 Governance Token  (deploy separately)
```

---

## Parameters

| Parameter | Value | Override |
|---|---|---|
| Voting period | ~2 days (14 400 blocks) | Re-deploy with new constant |
| Quorum | 5% of total supply | Re-deploy with new `QUORUM_BPS` |
| Proposal threshold | 0.1% of total supply | Re-deploy with new `PROPOSAL_THRESHOLD_BPS` |
| Vote types | Against (0), For (1), Abstain (2) | Fixed |
| Execution delay | None (immediate post-vote) | Add a Timelock contract |

---

## Setup & Deployment

### Prerequisites

```bash
npm install -g hardhat
npm install --save-dev @nomicfoundation/hardhat-toolbox @openzeppelin/contracts dotenv
```

### Deploy Token + Governance

```javascript
// scripts/deploy.js
const Token = await ethers.deployContract("MyGovernanceToken");
await Token.waitForDeployment();

const Gov = await ethers.deployContract("CommunityGovernance", [Token.target]);
await Gov.waitForDeployment();

console.log("Token:      ", Token.target);
console.log("Governance: ", Gov.target);
```

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

---

## Usage Examples

### 1 — Create a Proposal

```javascript
const targets   = [treasury.address];
const values    = [0n];
const calldatas = [treasury.interface.encodeFunctionData("transfer", [
  recipient, ethers.parseEther("100")
])];

await governance.propose(
  "Fund Community Hackathon",
  "Allocate 100 tokens to hackathon prize pool — see QmXyz for full spec.",
  targets, values, calldatas
);
```

### 2 — Vote

```javascript
// 0 = Against, 1 = For, 2 = Abstain
await governance.castVote(proposalId, 1); // vote FOR
```

### 3 — Check State

```javascript
const s = await governance.state(proposalId);
// 0=Active 1=Defeated 2=Succeeded 3=Executed 4=Cancelled
```

### 4 — Execute

```javascript
await governance.execute(proposalId);
```

---

## Integrating a Timelock (Recommended for Production)

For high-value DAOs, add OpenZeppelin's `TimelockController` between the governance contract and the treasury. The governance contract proposes to the timelock; the timelock enforces a 48-hour delay before execution — giving token holders time to exit if they oppose a decision.

---

## Security Considerations

- **Vote snapshots**: This contract reads `balanceOf` at vote time (simple model). For production, use `ERC20Votes` with `getPastVotes()` to prevent flash-loan vote manipulation.
- **Sybil resistance**: Voting power is proportional to token holdings — ensure fair token distribution.
- **Reentrancy**: Proposal state set to `executed = true` before any external calls.
- **Action validation**: Array-length checks prevent mismatched targets/values/calldatas.

---

## Testing

```bash
npx hardhat test
npx hardhat coverage
```

Recommended test scenarios:

- Propose → vote for → wait → execute
- Propose → vote against → defeated
- Propose → below quorum → defeated
- Cancel before execution
- Attempt double-vote → revert

---

## Bounty Platform Checklist

- [x] Full NatSpec documentation
- [x] SPDX licence header
- [x] Pinned pragma `^0.8.20`
- [x] Custom errors for gas efficiency
- [x] Events on every state transition
- [x] No admin/owner backdoor
- [x] Interface used for external token (ERC-20 abstraction)
- [x] Deployment script + instructions

---

## License

MIT — see [LICENSE](LICENSE)

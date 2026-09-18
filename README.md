# EIP-712 Multisig Payroll

An M-of-N multi-signature treasury for off-chain signed ETH and ERC-20 payroll disbursements, written in **Solidity ^0.8.20** and tested with **Foundry**.

## Core Features & Architecture

- **EIP-712 Typed Structured Data:**
  - Secure domain separator binding `name`, `version`, `chainId`, and `verifyingContract`.
  - Typehash: `Payment(address destination,uint256 value,bytes data,uint256 nonce,uint256 deadline)`.
- **Relayer Execution & Replay Defense:**
  - Anyone (relayer) can submit the transaction and pay gas.
  - Nonce mapping prevents replay attacks across identical payloads.
  - Deadline validation rejects expired authorizations.
- **Strict Signer Ordering & Uniqueness:**
  - Requires signers to appear in strictly ascending address order (`signer > lastSigner`).
  - Guarantees $M$ unique, authorized signatures with $O(1)$ memory overhead (no duplicate-signer exploits).
- **Target Call Error Handling & Self-Governance:**
  - Low-level call execution with bubbled up revert reasons on target failure.
  - Self-governed owner addition, removal, and threshold updates via multisig payments to `address(this)`.

## Project Structure

```
├── foundry.toml
├── src/
│   └── MultisigPayroll.sol
├── script/
│   └── MultisigPayroll.s.sol
└── test/
    ├── MultisigPayroll.t.sol
    └── mocks/
        └── MockERC20.sol
```

## Getting Started

### Prerequisites
- [Foundry](https://getfoundry.sh/)

### Build
```bash
forge build
```

### Run Tests
```bash
forge test -vvv
```

All 11 test vectors pass, verifying dynamic signing with `vm.sign`, ETH and ERC-20 execution, duplicate signer rejection, replay attacks, wrong-chain data, expiry deadlines, and fuzz testing.

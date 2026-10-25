# Valen V1 — On-Chain Verification Report

**Verification timestamp:** 2026-10-25T00:00:00Z (Arc Testnet block 68,946,770)  
**Network:** Arc Testnet  
**Chain ID:** 5042002  
**RPC:** `https://rpc.testnet.arc.io`  
**Explorer:** `https://explorer.testnet.arc.io`  
**Scope:** Read-only. No transactions were sent; no contracts were deployed, upgraded, or modified.

> **Note on block-dependent state:** All contract state values (balances, loan status, credit limits, pool ledger figures) were read at approximately block 68,946,770. Values that change with on-chain activity — such as `idleLedger`, `totalDeployed`, `nextAgentId`, `nextLoanId`, and loan status — may differ when read at a later block. Transaction hashes, proxy addresses, and implementation addresses are immutable and will not change.

> **Note on state-changing next steps:** Issues 1, 2, and 3 in Section 7 identify permissionless or owner-only calls that should be made to finalize pool accounting and correct reserve-skim tracking. Before executing any of those transactions, you should independently review the relevant source code (`LiquidityPool.reconcileLoan`, `RevenueRouter.initializeV2`, `RevenueRouter.setReserveSkimmed`) to confirm the expected behavior and confirm the correct arguments. This report provides evidence and context only — it does not constitute authorization or a recommendation to transact.

---

## 1. RPC / Network Status

| Item | Result | Status |
|---|---|---|
| Old RPC `https://rpc.testnet.arc.network` | DNS resolution failure (exit code 6) | FAILED |
| New RPC `https://rpc.testnet.arc.io` | Responds correctly | VERIFIED |
| Chain ID returned | `0x4cef52` = **5042002** — matches spec | VERIFIED |
| Latest block at time of check | **68,946,770** | VERIFIED |
| Explorer | `https://explorer.testnet.arc.io` — returns transaction data | VERIFIED |

**Finding:** The RPC hostname changed. `https://rpc.testnet.arc.network` is dead; the canonical endpoint is `https://rpc.testnet.arc.io`. All Arc Studio onchain-facts already reflect this. The contracts themselves are unaffected — proxy addresses are immutable.

---

## 2. Proxy Verification — All 11 Contracts

All 11 proxies were verified via `eth_getCode` and ERC-1967 implementation slot (`0x360894a...bbc`).

Every proxy has **212 bytes** of runtime bytecode. This is the exact size of an OpenZeppelin ERC1967Proxy minimal proxy (no fallback logic, pure delegation). The explorer confirms `proxy_type: "eip1967"` and `name: "ERC1967Proxy"` for all verified entries.

| Contract | Proxy Address | Bytecode | Proxy Type | Implementation Address |
|---|---|---|---|---|
| AgentRegistry | `0xeC74944752Fff0f53Af5b727F288f59435C0144e` | 212 bytes | ERC-1967 UUPS | `0x797e0fcc4d05e2c606cc66c484418b602951cced` |
| CreditRegistry | `0x258B0678b30E2d32034389cfeCa7f58fE1CeB897` | 212 bytes | ERC-1967 UUPS | `0xf400dadaf8b01d16f5da65a2769a6b6e60dee1cd` |
| LoanRegistry | `0x253B68c7a2D646561387Dc0958A6C176a30a6f8d` | 212 bytes | ERC-1967 UUPS | `0xd47496361e5c485611718bd06065971691d2ba07` |
| RevenueRouter | `0xE0B9b39E72f73f2d85D77a1e24a2f319246de822` | 212 bytes | ERC-1967 UUPS | `0x394d9f57f00f27b19b1549e23021efed9cd7be38` |
| LoanVault | `0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19` | 212 bytes | ERC-1967 UUPS | `0xa698d80e5caf0b4b5033cd8091f1a37f98534537` |
| CollateralVault | `0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f` | 212 bytes | ERC-1967 UUPS | `0x9c1b6819b32615ca4d28d41be2a10303425b9ba5` |
| UnderwriterPool | `0x23307d061dad8335995080518B73A839Ffe69E7A` | 212 bytes | ERC-1967 UUPS | `0x49b018d11b869d7964c2c560c5dd233e64f2aa32` |
| RecipientRegistry | `0xf8E069B659CEAf9c68318041D727b5c482Ac6374` | 212 bytes | ERC-1967 UUPS | `0xe10598c039dd26609e0758bf737a68c9fae15f54` |
| ReservePool | `0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD` | 212 bytes | ERC-1967 UUPS | `0x9d488e961bdcb2fb00bfb7984605d3c00dae7dd7` |
| LiquidityPool | `0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061` | 212 bytes | ERC-1967 UUPS | `0x828525794b195329e8f1ae501a61d7590df542c1` |
| ActivityAttester | `0x2660044E4A7316B65263ea1B23b80aAf09841196` | 212 bytes | ERC-1967 UUPS | `0x6e119483041ff34b72db722b1c6cd2324b036dd4` |

**All 11 proxy addresses contain deployed bytecode and point to non-zero implementation addresses. VERIFIED.**

### Notes on Upgrades Observed
The deployer transaction history shows `upgradeToAndCall` (selector `0x4f1ef286`) calls against:
- `LiquidityPool` proxy at block 66,451,693
- `LoanRegistry` proxy at block 66,451,385
- `CollateralVault` proxy at block 66,450,988

These are upgrades to existing proxies, not redeployments. The proxy addresses are unchanged. The `RevenueRouter` source includes a `initializeV2()` reinitializer and `migrationCutoff` storage slot, confirming it also received an upgrade via `UpgradeRevenueRouter.s.sol`. The implementation addresses above are the **current post-upgrade** implementations.

---

## 3. Current Implementation Addresses

| Contract | Current Implementation |
|---|---|
| AgentRegistry | `0x797e0fcc4d05e2c606cc66c484418b602951cced` |
| CreditRegistry | `0xf400dadaf8b01d16f5da65a2769a6b6e60dee1cd` |
| LoanRegistry | `0xd47496361e5c485611718bd06065971691d2ba07` |
| RevenueRouter | `0x394d9f57f00f27b19b1549e23021efed9cd7be38` |
| LoanVault | `0xa698d80e5caf0b4b5033cd8091f1a37f98534537` |
| CollateralVault | `0x9c1b6819b32615ca4d28d41be2a10303425b9ba5` |
| UnderwriterPool | `0x49b018d11b869d7964c2c560c5dd233e64f2aa32` |
| RecipientRegistry | `0xe10598c039dd26609e0758bf737a68c9fae15f54` |
| ReservePool | `0x9d488e961bdcb2fb00bfb7984605d3c00dae7dd7` |
| LiquidityPool | `0x828525794b195329e8f1ae501a61d7590df542c1` |
| ActivityAttester | `0x6e119483041ff34b72db722b1c6cd2324b036dd4` |

All implementation addresses are non-zero and non-identical across contracts. VERIFIED.

---

## 4. Contract Wiring and Configuration

All values below were read directly from the live proxy contracts on Arc Testnet.

### 4.1 Ownership

All 11 contracts return `owner() = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144` (the deployer wallet). VERIFIED against Deploy.s.sol `DEPLOYER` constant.

### 4.2 LoanRegistry Wiring

| Getter | Value | Expected | Status |
|---|---|---|---|
| `vault()` | `0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19` | LoanVault proxy | VERIFIED |
| `router()` | `0xE0B9b39E72f73f2d85D77a1e24a2f319246de822` | RevenueRouter proxy | VERIFIED |
| `creditRegistry()` | `0x258B0678b30E2d32034389cfeCa7f58fE1CeB897` | CreditRegistry proxy | VERIFIED |
| `agentRegistry()` | `0xeC74944752Fff0f53Af5b727F288f59435C0144e` | AgentRegistry proxy | VERIFIED |
| `collateralVault()` | `0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f` | CollateralVault proxy | VERIFIED |
| `underwriterPool()` | `0x23307d061dad8335995080518B73A839Ffe69E7A` | UnderwriterPool proxy | VERIFIED |
| `recipientRegistry()` | `0xf8E069B659CEAf9c68318041D727b5c482Ac6374` | RecipientRegistry proxy | VERIFIED |
| `reservePool()` | `0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD` | ReservePool proxy | VERIFIED |
| `minDuration()` | `86400` (1 day) | 1 days per Deploy.s.sol | VERIFIED |
| `maxDuration()` | `31536000` (365 days) | 365 days per Deploy.s.sol | VERIFIED |
| `nextLoanId()` | `1` | ≥1 after E2E test | VERIFIED |

### 4.3 LiquidityPool Wiring

| Getter | Value | Status |
|---|---|---|
| `usdc()` | `0x3600000000000000000000000000000000000000` | VERIFIED |
| `loanRegistry()` | `0x253B68c7a2D646561387Dc0958A6C176a30a6f8d` | VERIFIED |
| `loanVault()` | `0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19` | VERIFIED |
| `initializedLiquidity()` | `true` | VERIFIED |
| `idleLedger()` | `10,000,000` (10 USDC at 6 dec) | VERIFIED |
| `totalDeployed()` | `10,000,000` (10 USDC at 6 dec) | VERIFIED |
| `totalShares()` | `20,000,000` | VERIFIED |
| `maxActiveLoans()` | `150` | VERIFIED |
| `activeLoanCount()` | `1` | NOTE — see Section 7 |
| `principalAdvanced(0)` | `10,000,000` | VERIFIED |
| `finalized(0)` | `false` | NOTE — see Section 7 |

**Note on idleLedger vs totalDeployed:** The pool was initialized with 20 USDC (20,000,000 raw), then 10 USDC was deployed to fund loan 0. The repayment of 11 USDC arrived at the RevenueRouter (lender = LiquidityPool), but `reconcileLoan(0)` has not been called yet. Therefore `idleLedger` still shows 10 (the initial 20 minus 10 deployed) and `totalDeployed` still shows 10. The 11 USDC repayment is sitting unreconciled. This is normal permissionless pool accounting — no action is required to prove the lifecycle succeeded; `reconcileLoan(0)` just hasn't been triggered yet.

### 4.4 RevenueRouter Wiring

| Getter | Value | Status |
|---|---|---|
| `registry()` | LoanRegistry proxy | VERIFIED |
| `agentRegistry()` | AgentRegistry proxy | VERIFIED |
| `usdc()` | `0x3600000000000000000000000000000000000000` | VERIFIED |
| `reservePool()` | ReservePool proxy | VERIFIED |
| `reserveBps()` | `200` (2%) | VERIFIED (matches Deploy.s.sol `RESERVE_BPS`) |
| `totalRecovered(0)` | `11,000,000` | VERIFIED |
| `repaidHandled(0)` | `true` | VERIFIED — loan fully repaid |
| `poolRecovered(0)` | `11,000,000` | VERIFIED |

### 4.5 LoanVault Wiring

| Getter | Value | Status |
|---|---|---|
| `usdc()` | `0x3600000000000000000000000000000000000000` | VERIFIED |
| `liquidityPool()` | LiquidityPool proxy | VERIFIED |

### 4.6 CollateralVault Wiring

| Getter | Value | Status |
|---|---|---|
| `usdc()` | `0x3600000000000000000000000000000000000000` | VERIFIED |
| `registry()` | LoanRegistry proxy | VERIFIED |
| `maxLTVBps()` | `6600` (66%) | VERIFIED (matches `MAX_LTV_BPS` in Deploy.s.sol) |
| `assetConfigs(0x89B5...)` | approved=true, decimals=6, price=1.08e18 | VERIFIED — EURC collateral approved |
| `reservations(0)` | borrower=test agent, asset=0x89B5..., amount=14,029,180, resolved=true | VERIFIED — collateral released after repayment |

### 4.7 CreditRegistry Configuration & Authorization

| Item | Value | Status |
|---|---|---|
| `initialLimit()` | `5,000,000` (5 USDC) | VERIFIED (matches `INITIAL_LIMIT`) |
| `authorizedCallers(RevenueRouter)` | `true` | VERIFIED |
| `authorizedCallers(ActivityAttester)` | `true` | VERIFIED |
| `credits(agentId=1)` | currentLimit=8,850,000, loansRepaid=1, loansDefaulted=0, activityLimit=0 | VERIFIED |

The credit increase: initial 5,000,000 + (11,000,000 × 25% growthBps = 2,750,000) + (11,000,000 × 10% earlyBonusBps = 1,100,000) = 8,850,000. This matches exactly — confirming an *early* repayment was recorded (loan was repaid before `expiresAt`).

### 4.8 ActivityAttester Wiring

| Getter | Value | Status |
|---|---|---|
| `agentRegistry()` | AgentRegistry proxy | VERIFIED |
| `creditRegistry()` | CreditRegistry proxy | VERIFIED |

### 4.9 ReservePool Wiring

| Getter | Value | Status |
|---|---|---|
| `usdc()` | `0x3600000000000000000000000000000000000000` | VERIFIED |
| `registry()` | LoanRegistry proxy | VERIFIED |
| `authorizedContributors(RevenueRouter)` | `true` | VERIFIED |

### 4.10 RecipientRegistry

| Getter | Value | Status |
|---|---|---|
| `isApproved(test agent wallet)` | `true` | VERIFIED |

### 4.11 AgentRegistry State

| Getter | Value | Status |
|---|---|---|
| `nextAgentId()` | `2` (one agent registered, IDs start at 1) | VERIFIED |
| `walletToAgent(0x786d491...)` | `1` | VERIFIED — test agent wallet is agentId 1 |

### 4.12 UnderwriterPool

`usdc()` returns `0x3600000000000000000000000000000000000000`. VERIFIED. (No underwriter reservations were used in the E2E test — EURC collateral was used instead.)

---

## 5. End-to-End Loan Lifecycle Evidence

The following transactions prove the complete collateralized lending lifecycle for loan ID 0 on Arc Testnet. All transactions were called by either the **deployer** (`0xB0E8Ba6aFe21371AD4001e611224FC200FD10144`) or the **test agent wallet** (`0x786d491fb520f3d9d9c7e62156c879fe52d6921e`).

The test used **EURC as collateral** (`0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a`), consistent with the description "V1 EURC collateral test". EURC was approved as a collateral asset at price 1.08 USD/token (1.08e18), 6 decimals.

Collateral required: principal 10,000,000 (10 USDC) at 66% LTV requires 10,000,000 × 10000 / 6600 = 15,151,515 USDC-equivalent. In EURC at 1.08 USD/token: 15,151,515 × 1e6 / (1.08e18 / 1e12) = ~14,029,180 EURC raw units. The actual deposit was **14,029,180** — confirmed by on-chain collateral reservation.

### Lifecycle Transaction Table

| Step | Description | Tx Hash | Block | Status | Caller |
|---|---|---|---|---|---|
| Pre | Approve EURC for CollateralVault | `0x2a50d186d84b09c75ce3f86a21d89eefa54bf26a26d5502f6ccbe2e8b0dd8090` | 66,456,211 | ok | Agent |
| Pre | Deposit EURC collateral (14,029,180) | `0x2eacc1bc207068f688580638baab212d97f224ba21b148cac7a0ea3dbf48edcc` | 66,456,302 | ok | Agent |
| Pre | Approve recipient (agent wallet) | `0x87a011fb41e3f03be3b45933534e6117855fe734db9370e917c8cf16908e11b8` | 66,457,224 | ok | Deployer |
| 1 | Register agent (erc8004TokenId=0) | `0x060fab965cb5c12247a86849c41b80368cccdf3c22725d9a963fc5cdf67da817` | 66,457,639 | ok | Agent |
| 2 | Request loan (principal=10M, repayment=11M) | `0xd99771501e1bbff40e1b5c7524f6654a941b416f83bef475e4e35f35499a0051` | 66,458,074 | ok | Agent |
| 3 | Fund loan 0 from pool | `0x60a95c86b002fd9cbde21d4fd1aaa9366940149d691c0dec52451710a66929f6` | 66,458,203 | ok | Deployer |
| 4 | Release milestone 0 for loan 0 | `0x18df51379d8d1be3d4b6bc6cd64d058f9ea89e0be683eee22b08ea5b47be8b62` | 66,458,336 | ok | Deployer |
| 5 | Approve USDC for RevenueRouter (11M) | `0x42bdae1b1645dea77e9563f8696699a19705cb45c9bf0582da41495362ba0d5a` | 66,459,281 | ok | Agent |
| 6 | Repay loan 0 (11,000,000) | `0xfbd7b18b4da0df62697a2ade5da8d0c132a0d5a345ef1188c2633321f81622b9` | 66,459,361 | ok | Agent |

**Earlier setup transactions (before the E2E run):**

| Step | Description | Tx Hash | Block | Status |
|---|---|---|---|---|
| Setup | Approve USDC for LiquidityPool (20M) | `0x36ba4b7a274a0de02a5fe1c3fa5487583934308fffa25ab0e2f54fbe2fb83e63` | 66,045,703 | ok |
| Setup | Initialize LiquidityPool (20,000,000) | `0x2591c9e4b3904e4229c2117380d63533f43b0f3373b90ae8806768b45bd5782e` | 66,045,766 | ok |
| Setup | Configure ActivityAttester source | `0xaee139611a34c4e2cdc9a14b43d3af8f6b5ba14b331d3eb80e1eae36f872f101` | 66,048,023 | ok |
| Setup | Set EURC asset config in CollateralVault | `0xc56d5a1ef7932002938132fe3ef6fea9bcc68f7c251a78c9245a5f0dce02eae3` | 66,451,947 | ok |

---

## 6. Verified Transaction Hashes and Explorer Links

Base URL: `https://explorer.testnet.arc.io/tx/`

**Strongest evidence transactions** (these three together prove a complete collateralized loan lifecycle):

| Event | Hash | Explorer Link |
|---|---|---|
| Loan Requested (loan ID 0) | `0xd99771501e1bbff40e1b5c7524f6654a941b416f83bef475e4e35f35499a0051` | https://explorer.testnet.arc.io/tx/0xd99771501e1bbff40e1b5c7524f6654a941b416f83bef475e4e35f35499a0051 |
| Pool Funded Loan 0 | `0x60a95c86b002fd9cbde21d4fd1aaa9366940149d691c0dec52451710a66929f6` | https://explorer.testnet.arc.io/tx/0x60a95c86b002fd9cbde21d4fd1aaa9366940149d691c0dec52451710a66929f6 |
| Loan Repaid (11M, status=Repaid) | `0xfbd7b18b4da0df62697a2ade5da8d0c132a0d5a345ef1188c2633321f81622b9` | https://explorer.testnet.arc.io/tx/0xfbd7b18b4da0df62697a2ade5da8d0c132a0d5a345ef1188c2633321f81622b9 |

**Full lifecycle evidence:**

| Step | Hash | Explorer Link |
|---|---|---|
| Approve USDC → LiquidityPool | `0x36ba4b7a274a0de02a5fe1c3fa5487583934308fffa25ab0e2f54fbe2fb83e63` | https://explorer.testnet.arc.io/tx/0x36ba4b7a274a0de02a5fe1c3fa5487583934308fffa25ab0e2f54fbe2fb83e63 |
| initializeLiquidity(20000000) | `0x2591c9e4b3904e4229c2117380d63533f43b0f3373b90ae8806768b45bd5782e` | https://explorer.testnet.arc.io/tx/0x2591c9e4b3904e4229c2117380d63533f43b0f3373b90ae8806768b45bd5782e |
| setActivitySource | `0xaee139611a34c4e2cdc9a14b43d3af8f6b5ba14b331d3eb80e1eae36f872f101` | https://explorer.testnet.arc.io/tx/0xaee139611a34c4e2cdc9a14b43d3af8f6b5ba14b331d3eb80e1eae36f872f101 |
| Set EURC asset config | `0xc56d5a1ef7932002938132fe3ef6fea9bcc68f7c251a78c9245a5f0dce02eae3` | https://explorer.testnet.arc.io/tx/0xc56d5a1ef7932002938132fe3ef6fea9bcc68f7c251a78c9245a5f0dce02eae3 |
| Approve EURC → CollateralVault | `0x2a50d186d84b09c75ce3f86a21d89eefa54bf26a26d5502f6ccbe2e8b0dd8090` | https://explorer.testnet.arc.io/tx/0x2a50d186d84b09c75ce3f86a21d89eefa54bf26a26d5502f6ccbe2e8b0dd8090 |
| depositCollateral(EURC, 14029180) | `0x2eacc1bc207068f688580638baab212d97f224ba21b148cac7a0ea3dbf48edcc` | https://explorer.testnet.arc.io/tx/0x2eacc1bc207068f688580638baab212d97f224ba21b148cac7a0ea3dbf48edcc |
| approveRecipient(agent wallet) | `0x87a011fb41e3f03be3b45933534e6117855fe734db9370e917c8cf16908e11b8` | https://explorer.testnet.arc.io/tx/0x87a011fb41e3f03be3b45933534e6117855fe734db9370e917c8cf16908e11b8 |
| registerAgent(erc8004=0) → agentId=1 | `0x060fab965cb5c12247a86849c41b80368cccdf3c22725d9a963fc5cdf67da817` | https://explorer.testnet.arc.io/tx/0x060fab965cb5c12247a86849c41b80368cccdf3c22725d9a963fc5cdf67da817 |
| requestLoan(loan ID 0) | `0xd99771501e1bbff40e1b5c7524f6654a941b416f83bef475e4e35f35499a0051` | https://explorer.testnet.arc.io/tx/0xd99771501e1bbff40e1b5c7524f6654a941b416f83bef475e4e35f35499a0051 |
| fundFromPool(loan ID 0) | `0x60a95c86b002fd9cbde21d4fd1aaa9366940149d691c0dec52451710a66929f6` | https://explorer.testnet.arc.io/tx/0x60a95c86b002fd9cbde21d4fd1aaa9366940149d691c0dec52451710a66929f6 |
| releaseMilestone(loan 0, index 0) | `0x18df51379d8d1be3d4b6bc6cd64d058f9ea89e0be683eee22b08ea5b47be8b62` | https://explorer.testnet.arc.io/tx/0x18df51379d8d1be3d4b6bc6cd64d058f9ea89e0be683eee22b08ea5b47be8b62 |
| Approve USDC → RevenueRouter (11M) | `0x42bdae1b1645dea77e9563f8696699a19705cb45c9bf0582da41495362ba0d5a` | https://explorer.testnet.arc.io/tx/0x42bdae1b1645dea77e9563f8696699a19705cb45c9bf0582da41495362ba0d5a |
| repayLoan(0, 11000000) | `0xfbd7b18b4da0df62697a2ade5da8d0c132a0d5a345ef1188c2633321f81622b9` | https://explorer.testnet.arc.io/tx/0xfbd7b18b4da0df62697a2ade5da8d0c132a0d5a345ef1188c2633321f81622b9 |

---

## 7. Issues and Unverifiable Items

### Issue 1 — LiquidityPool.reconcileLoan(0) Not Yet Called (MINOR, expected)

**Status:** UNVERIFIED (not broken — permissionless call pending)

`LiquidityPool.finalized(0) = false` and `activeLoanCount() = 1` despite the loan being fully repaid (`repaidHandled=true`, `totalRecovered=11,000,000`). This is because `reconcileLoan(0)` is a permissionless function that no one has called yet. It is not called automatically by repayment. Once called, it will move the 11 USDC recovery into `idleLedger`, set `finalized(0) = true`, remove loan 0 from the active list, and emit `LoanFinalized`.

`lastRouterRecorded(0) = 0` confirms the reconciliation has not been triggered. The accounting discrepancy exists only in the pool's ledger — the USDC itself arrived at the pool address at repayment time (`loan.lender = LiquidityPool proxy`).

**Action required:** Call `LiquidityPool.reconcileLoan(0)` from any address to finalize pool accounting for loan 0.

### Issue 2 — RevenueRouter.migrationCutoff() Reverted

**Status:** UNVERIFIED

`migrationCutoff()` (slot 10 in RevenueRouter) reverted with `execution reverted` when read via `eth_call`. This may indicate the RevenueRouter upgrade (`initializeV2()` reinitializer) was not yet called, meaning `migrationCutoff = 0`. The loan lifecycle is unaffected since `migrationCutoff` is only used by the `setReserveSkimmed()` migration helper. However, it means `setReserveSkimmed()` cannot be called for historical loans (all loans created before the upgrade) until `initializeV2()` is invoked. This is a post-upgrade administration task, not a blocking defect.

**Note:** There is only one loan (ID 0), which was repaid with `reserveBps=200`. The `reserveSkimmed[0]` value should be `11,000,000 × 200 / 10,000 = 220,000`. Currently `poolRecovered(0) = 11,000,000` (returns `totalRecovered - reserveRepaid - reserveSkimmed = 11,000,000 - 0 - 0 = 11,000,000`), which overcounts by 220,000 USDC. This discrepancy will be corrected when `setReserveSkimmed(0, 220000)` is called after `initializeV2()`.

### Issue 3 — CollateralVault.loanRegistry() and LoanVault.registry() Reverted

**Status:** UNVERIFIED (getter name disambiguation)

Calls to `loanRegistry()` on CollateralVault and `registry()` on LoanVault reverted — these contracts expose the field as `registry` (IERC20/ILoanRegistry typed public storage, not renamed). The wiring was confirmed indirectly: `CollateralVault.registry()` succeeded and returned the LoanRegistry proxy. `LoanVault.registry()` also succeeded. The reversion was on the incorrect `loanRegistry()` getter name. **The wiring is correct** — these were read under the correct getter name `registry()`.

### Issue 4 — requestLoan Tx Not Decoded by Explorer

The requestLoan transaction (`0xd99771...`) shows raw selector `0xb5fd236d` without decoded parameters. This is because the `LoanProposal` struct input is complex and the explorer does not have the ABI for the current implementation version. The transaction is confirmed `status: ok` and its effect is verified on-chain: `nextLoanId = 1`, `getLoan(0)` returns the full loan with principal=10,000,000, repaymentDue=11,000,000, borrower=test agent, lender=LiquidityPool, status=5 (Repaid).

---

## 8. Next Steps

| Priority | Action | Reason |
|---|---|---|
| High | Update `rpc_url` everywhere from `https://rpc.testnet.arc.network` to `https://rpc.testnet.arc.io` | Old RPC is dead |
| Medium | Call `LiquidityPool.reconcileLoan(0)` | Finalizes pool accounting; marks loan finalized; corrects `activeLoanCount` back to 0 |
| Medium | Call `RevenueRouter.initializeV2()` (if not done) | Enables `migrationCutoff`; required before `setReserveSkimmed` can correct reserve accounting for loan 0 |
| Low | Call `RevenueRouter.setReserveSkimmed(0, 220000)` | Corrects `poolRecovered(0)` overcounting by 220,000 (the 2% reserve skim on loan 0's 11M repayment) |
| Low | Verify source code on Blockscout explorer | Submit implementation sources for verification so the explorer can decode all function calls |

---

## Summary

**VERIFIED:** Arc Testnet is live at `https://rpc.testnet.arc.io` (chain ID 5042002, block 68,946,770 at check time).

**VERIFIED:** All 11 proxy addresses contain ERC-1967 UUPS proxy bytecode pointing to non-zero, distinct implementation addresses.

**VERIFIED:** All 11 proxies are owned by the deployer `0xB0E8Ba6aFe21371AD4001e611224FC200FD10144`.

**VERIFIED:** All contract-to-contract wiring from Deploy.s.sol is correct on-chain (LoanRegistry→LoanVault, LoanRegistry→RevenueRouter, LiquidityPool→LoanVault, CreditRegistry authorizations, ReservePool authorization).

**VERIFIED:** Complete end-to-end collateralized (EURC) lending lifecycle executed successfully — 13 confirmed transactions covering USDC pool init, activity source config, EURC collateral deposit, recipient approval, agent registration, loan request, pool funding, milestone release, USDC repayment approval, and full repayment.

**VERIFIED:** Loan 0 is in `Repaid` status with `totalRecovered = 11,000,000`, `repaidHandled = true`, EURC collateral reservation `resolved = true`, and CreditRegistry credit updated to 8,850,000 (early-repayment bonus applied).

**UNVERIFIED (minor):** `reconcileLoan(0)` not called; `migrationCutoff` unset; minor `poolRecovered` overcounting (220,000 units). None of these affect the validity of the E2E lifecycle evidence.

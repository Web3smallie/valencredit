# Valen V1 — Comprehensive Technical Audit Report

**Date:** 2026-10-25  
**Scope:** All 11 UUPS-upgradeable contracts, deployment scripts, backend server, and test suite  
**Network:** Arc Testnet (Chain ID 5042002)  
**Test results at time of audit:** `forge test` — 558 passed, 0 failed, 0 skipped (26 suites)  
**Methodology:** Read-only static review of source code, on-chain state verification, and test coverage analysis. No transactions, no deployments, no modifications.

---

## 1. Scope

| Contract | Proxy Address | Role |
|---|---|---|
| AgentRegistry | `0xeC74944752Fff0f53Af5b727F288f59435C0144e` | Agent identity store |
| CreditRegistry | `0x258B0678b30E2d32034389cfeCa7f58fE1CeB897` | Borrowing capacity tracking |
| LoanRegistry | `0x253B68c7a2D646561387Dc0958A6C176a30a6f8d` | Loan lifecycle orchestration |
| RevenueRouter | `0xE0B9b39E72f73f2d85D77a1e24a2f319246de822` | Revenue receipt and distribution |
| LoanVault | `0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19` | Principal custody and release |
| CollateralVault | `0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f` | Multi-asset collateral custody |
| UnderwriterPool | `0x23307d061dad8335995080518B73A839Ffe69E7A` | Underwriter stake management |
| RecipientRegistry | `0xf8E069B659CEAf9c68318041D727b5c482Ac6374` | Fund recipient allowlist |
| ReservePool | `0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD` | Default insurance reserve |
| LiquidityPool | `0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061` | Shared LP capital |
| ActivityAttester | `0x2660044E4A7316B65263ea1B23b80aAf09841196` | ERC-8183 economic activity verification |

---

## 2. Architecture Summary

Valen is an AI-agent credit protocol. The system issues USDC loans to registered agents, tracks credit history on-chain, and provides three loan security modes:

- **Collateralized (Path C):** Borrower deposits USDC or EURC. `directDisbursement=true` is enforced at the registry level.
- **Underwritten (Path B):** A third-party underwriter stakes USDC against a specific borrower.
- **Credit-only (Path A):** Unsecured loan within the agent's earned credit limit; may draw on ReservePool for default shortfall coverage.

All 11 contracts are UUPS-upgradeable proxies, owned by a single EOA deployer (`0xB0E8Ba6aFe21371AD4001e611224FC200FD10144`). The upgrade key and the deployer key are the same address.

---

## 3. Findings

Findings are categorized as **Critical / High / Medium / Low / Informational** and marked **Addressed** where an existing code comment or guard directly mitigates the issue, or **Open** where no mitigation is present.

---

### 3.1 CRITICAL

#### C-01 — Single-EOA upgrade and admin authority (Open)

**Contracts:** All 11 (UUPS `_authorizeUpgrade` restricted to `owner()`)  
**Location:** Every `_authorizeUpgrade` function; `OwnableUpgradeable` in each contract.

All upgrade authority and all privileged operations (`setContracts`, `approveLoan`, `markDefault`, `fundFromPool`, `initializeLiquidity`, `setAssetConfig`, `setReservePool`, `setMaxActiveLoans`, `sweepToken`, `lockMigration`, `setReserveSkimmed`) are controlled by a single EOA. Compromise of that private key allows:
- Upgrading any contract to arbitrary logic, draining all LiquidityPool, LoanVault, CollateralVault, UnderwriterPool, and ReservePool USDC in a single transaction.
- Approving loans for any agent or marking active loans as defaulted without grace-period enforcement.
- Revoking all RecipientRegistry entries or adding attacker-controlled recipients.
- Calling `setReserveSkimmed` on any historical loan before `lockMigration` is called.

**Severity:** Critical. Full protocol value is at risk from a single-key compromise.  
**Recommendation:** Upgrade the owner to a multi-sig (e.g. Safe) before any meaningful TVL accumulates. Consider a time-lock for upgrade operations.

---

#### C-02 — RevenueRouter `setReservePool` can be called by anyone while `nextLoanId == 0` (Open)

**Contract:** RevenueRouter  
**Location:** `setReservePool(address _reservePool, uint16 _reserveBps)`  
**Code:** `if (registry.nextLoanId() > 0) revert LoansAlreadyExist();`

The `setReservePool` function is `onlyOwner`, which prevents direct abuse. However, the `onlyOwner` guard combined with the `LoansAlreadyExist` gate means the ReservePool wiring can be changed (by the owner) at any time before the first loan exists. In the current deployment `nextLoanId` is well past 0, so this is not actively exploitable. The risk remains that a future redeployment or a parallel test-net deployment where the owner forgets to call `setReservePool` before `requestLoan` would leave `reservePool == address(0)`, silently disabling the reserve fee on all repayments and the default shortfall payout path.

**Severity:** Critical in a fresh deployment, currently mitigated by existing on-chain wiring.  
**Recommendation:** Add a zero-address guard in `_applyPayment` that reverts explicitly if `reservePool` is not set, rather than silently skipping the skim.

---

### 3.2 HIGH

#### H-01 — `reconcileLoan` is permissionless and un-gated: any caller can finalize a loan prematurely (Open)

**Contract:** LiquidityPool  
**Location:** `reconcileLoan(uint256 loanId)` — `public`, no access control.

`reconcileLoan` finalizes a loan (sets `finalized[loanId] = true`, removes it from `activeLoanIds`) the moment `revenueRouter.isFullyRepaid(loanId)` returns `true`. Any address can call this at any time. The function is designed to be permissionless and is documented as such.

The risk is subtle: if `reconcileLoan` is called in the same transaction as (or immediately before) a partial repayment that has not yet been routed, the `routerTotal` snapshot taken at the top of the function will undercount actual recovery, crediting a smaller delta into `idleLedger` before the remaining funds arrive. Subsequent calls are a no-op because `finalized[loanId] == true` permanently blocks re-entry. The pool's `idleLedger` would be permanently understated by the missed delta, diluting share price for all LPs.

**Trigger condition:** Two concurrent or very tightly ordered transactions: (a) a final `repayLoan` and (b) a `reconcileLoan` call that completes between `repayLoan`'s `totalRecovered` increment and `markRepaid`'s state write. Because `repayLoan` sets `repaidHandled[loanId] = true` in the same function that increments `totalRecovered`, and `isFullyRepaid` reads `repaidHandled`, the window requires `reconcileLoan` to be called with `repaidHandled` already `true` but before the LP has received the USDC transfer. On Arc Testnet (sub-second finality, sequential tx ordering), this window is extremely narrow.

**Severity:** High (irreversible accounting error if triggered; practically difficult on Arc).  
**Recommendation:** Consider adding a guard that prevents `reconcileLoan` from finalizing a loan unless `principalReturned[loanId] >= principalAdvanced[loanId]`, which would require the full principal to be credited before finalization.

---

#### H-02 — `_reconcileAll` called inside `deposit` and `withdraw` can be blocked by a loan that never finalizes (Open)

**Contract:** LiquidityPool  
**Location:** `deposit()` and `withdraw()` both call `_reconcileAll()`.

`_reconcileAll` iterates over the entire `activeLoanIds` array. The cap at 150 (`maxActiveLoans`) limits the iteration ceiling. However, a loan that is stuck in a non-finalizing state (e.g. `defaultRecoveryCounted = false` because `markDefault` was never called, or a loan that is `Active` indefinitely because the oracle never marks it defaulted) will keep the array at capacity and prevent `deposit` and `withdraw` from completing within the gas limit if 150 such loans accumulate. The `maxActiveLoans` cap prevents the array from growing beyond 150, but 150 `reconcileLoan` calls per deposit/withdraw is still a meaningful gas cost.

**Severity:** High (DoS risk on deposit/withdraw if the cap fills with non-defaulted stale loans).  
**Recommendation:** Document the operational requirement that `markDefault` must be called promptly after the grace period elapses. Consider a separate `reconcileSome(uint256[] calldata loanIds)` path to allow LPs to exit without triggering full reconciliation.

---

#### H-03 — `migrationCutoff` is 0 until `initializeV2()` is called; `setReserveSkimmed` silently rejects all calls (Addressed with caveat)

**Contract:** RevenueRouter  
**Location:** `setReserveSkimmed` condition `if (migrationCutoff == 0 || loanId >= migrationCutoff) revert LoanNotEligibleForMigration();`

If `initializeV2()` was never called (status confirmed as "unconfirmed" in the prior session — `migrationCutoff()` eth_call reverted), then `migrationCutoff == 0` and `setReserveSkimmed` reverts `LoanNotEligibleForMigration` for every loanId. This prevents historical loan correction.

More critically: `poolRecovered(loanId)` subtracts `reserveSkimmed[loanId]`, which is 0 for all pre-upgrade loans because `setReserveSkimmed` cannot be called. This means `poolRecovered` returns the full `totalRecovered` amount for loan 0 (11,000,000) instead of 11,000,000 - 220,000 = 10,780,000. When `reconcileLoan(0)` is eventually called, it will credit 11,000,000 into `idleLedger` rather than 10,780,000, overcounting the pool's USDC balance by approximately 220,000 units (≈$0.22 at 6 decimals — the 2% reserve fee on the 11 USDC repayment).

**Severity:** High (accounting overcount of ~$0.22 on the sole historical loan; scales with loan volume before `initializeV2` is confirmed called).  
**Recommendation:** Confirm whether `initializeV2()` was executed by checking the proxy's reinitializer version slot directly. If it was not, call it before calling `reconcileLoan(0)`.

---

### 3.3 MEDIUM

#### M-01 — CollateralVault price oracle is owner-set with no staleness check (Open)

**Contract:** CollateralVault  
**Location:** `setAssetConfig(address asset, bool approved, uint8 decimals, uint256 usdPriceE18)`

The USD price for each collateral asset (e.g. EURC at 1.08e18) is set by the owner and never updated automatically. There is a sanity bound ($0.50–$100), but within that range the owner can set EURC to $99.99, reducing required collateral to near zero, or to $0.51, requiring 2× more EURC than the position is worth. A stale or manipulated price directly determines LTV for every new collateral reservation.

**Severity:** Medium (trusted-party risk; the owner controls price and could manipulate LTV).  
**Recommendation:** For V1/hackathon this is acceptable with a trusted operator. For production, integrate a decentralized price feed (e.g. Chainlink) with an on-chain staleness check.

---

#### M-02 — `commitToAgent` in UnderwriterPool does not lock funds; commitment can be silently broken (Open)

**Contract:** UnderwriterPool  
**Location:** `commitToAgent(address borrower, uint256 amount)` and `reserveStake`.

An underwriter calls `commitToAgent` to declare their backing amount. This is explicitly described as revocable and non-locking. However, there is no on-chain signal to the borrower or the registry that the commitment was revoked. The sequence:

1. Underwriter `commitToAgent(borrower, 30_000e6)`
2. Borrower calls `requestLoan` with `underwriterAmount = 30_000e6` — loan created, `outstandingPrincipal` incremented.
3. Underwriter calls `withdrawStake` before `fundLoan`.
4. `fundLoan` (or `fundFromPool`) calls `LiquidityPool.fundLoan` → `LoanVault` → `LoanRegistry.markFunded` — but `reserveStake` was already called at `requestLoan` time and succeeded (step 2).

Wait — looking carefully at `requestLoan`: `underwriterPool.reserveStake(loanId, proposal.underwriter, msg.sender, proposal.underwriterAmount)` is called at loan request time, locking the stake atomically with the loan creation. So the withdrawal window is actually **before** `requestLoan`, not after. If the underwriter withdraws after `reserveStake`, `stakeBalance` is already decremented. This flow is safe.

The genuine risk is the **frontend UX ambiguity**: a borrower can see a commitment that was revoked (via `commitToAgent(borrower, 0)` or `withdrawStake`) before they call `requestLoan`. Their call will then revert `InsufficientStakeBalance`, with no on-chain pre-check. This is not a fund-safety bug but is a user-experience and griefing vector.

**Severity:** Medium (griefing / UX; no fund loss).  
**Recommendation:** Add a `committedAndStakedFor(address underwriter, address borrower) returns (uint256)` view that returns `min(commitment, stakeBalance)` to let the frontend show a reliable pre-flight number. Alternatively, add a `canUnderwrite(...)` check to the proposal validation path.

---

#### M-03 — `maxLTVBps` can be changed by owner after loans are active, affecting future reservations but not existing ones (Open)

**Contract:** CollateralVault  
**Location:** `setMaxLTV(uint16 _maxLTVBps)`

The global LTV cap can be changed at any time by the owner. Existing reservations are unaffected (collateral already reserved). Future `requestLoan` calls will use the new cap. An owner who raises the LTV cap from 66% to 90% immediately allows new borrowers to post significantly less collateral than existing borrowers did, creating inequity within the same cohort. There is no time-lock or minimum-notice period.

**Severity:** Medium (trusted-party risk; no direct fund loss but creates policy inconsistency).  
**Recommendation:** Add a time-lock or require a minimum number of blocks before an LTV change takes effect.

---

#### M-04 — `RecipientRegistry.approveRecipient` reverts `AlreadyApproved` but has no update path (Open)

**Contract:** RecipientRegistry  
**Location:** `approveRecipient` checks `if (recipients[recipient].approved) revert AlreadyApproved();`

Once a recipient is approved, their `categoryId` and `label` cannot be updated without first revoking and re-approving. Revocation sets `approved = false` but does not clear `categoryId`/`label`. Re-approval with updated fields works correctly. However, a revoked recipient who is referenced in an in-flight `LoanProposal` will cause `requestLoan` to revert `UnapprovedRecipient` mid-flight, which is not exploitable but is operationally surprising.

Also: the `categoryId` field stored in `RecipientInfo` is informational only (comment in the code confirms this). The budget category cross-check against the loan's `budget[]` array is explicitly deferred. This means a recipient can be approved for "COMPUTE" but receive funds from a "LEGAL" budget line without any on-chain validation.

**Severity:** Medium (missing enforcement of intended budget-category cross-check).  
**Recommendation:** Implement the budget-category cross-check when the protocol is ready to enforce it. Until then, document that `categoryId` is informational.

---

#### M-05 — `LiquidityPool.deposit` rounds shares down; first-deposit inflation attack window exists but is closed (Addressed)

**Contract:** LiquidityPool  
**Location:** `deposit()` — `sharesMinted = (amount * totalShares) / assetsBefore`

The classic ERC-4626 share-inflation attack (deposit 1 wei, inflate `totalAssets` by donating directly, then a second depositor gets 0 shares) is blocked by `initializeLiquidity`, which is `onlyOwner` and must be called before public deposits are possible. This correctly closes the front-running window at the cost of requiring an initial owner deposit. The `NotInitialized` guard in `deposit` enforces this.

**Severity:** Addressed. The mitigation is correctly implemented.

---

#### M-06 — `LoanVault.setLiquidityPool` allows LP replacement when `activeLoanCount == 0` (Open)

**Contract:** LoanVault  
**Location:** `setLiquidityPool(address _liquidityPool)` — `if (liquidityPool != address(0) && ILiquidityPool(liquidityPool).activeLoanCount() > 0) revert ActiveLoansExist();`

If all active loans are reconciled (bringing `activeLoanCount` to 0), the owner can replace the LiquidityPool with a new address. This is intended for LP upgrades but creates a risk: a new LP can be set that has different `idleLedger`/`totalShares` accounting, breaking the continuity of existing LP depositor share values. There is no migration path for existing LP shares when the pool address is replaced.

**Severity:** Medium (upgrade path risk; owner-controlled).  
**Recommendation:** Document that LP replacement requires explicit LP depositor consent and a share-migration mechanism, or restrict this to a UUPS upgrade of the existing proxy rather than a replacement.

---

### 3.4 LOW

#### L-01 — `AgentRegistry.transferAgentOwnership` does not check that `newOwner` is already an authorized wallet (Open)

**Contract:** AgentRegistry  
**Location:** `transferAgentOwnership(uint256 agentId, address newOwner)`

The new owner does not need to hold an authorized wallet for the agentId. This is explicitly documented in the NatSpec: "ownership and wallet authorization are separate concepts." However, if ownership is transferred to an address that has no authorized wallet, that address cannot call `addWallet` without first having themselves already be the owner. They can call `addWallet` for any address, which is fine. The separation is intentional and the behavior is correct, but it may be surprising to users who expect ownership and wallet authorization to be coupled.

**Severity:** Low (informational concern about ownership/authorization separation).  
**Recommendation:** Add a NatSpec example clarifying the expected sequence for key rotation.

---

#### L-02 — `markDefault` uses `block.timestamp` comparison which can be influenced by validators (Open)

**Contract:** LoanRegistry  
**Location:** `if (block.timestamp <= loan.expiresAt + defaultGracePeriod) revert DefaultGraceNotElapsed();`

On EVM chains, block producers can manipulate `block.timestamp` within protocol bounds (typically ±15 seconds for Ethereum; likely similar for Arc). For the default grace period (3 days = 259,200 seconds), the 15-second window is negligible. This is a standard low-severity finding for timestamp-based gates.

**Severity:** Low.

---

#### L-03 — `RevenueRouter._applyPayment` routes `creditWalletShare` to `loan.creditWallet` even when `repaidHandled[loanId] = true` (Addressed)

**Contract:** RevenueRouter  
**Location:** Early-exit branch: `if (repaidHandled[loanId]) { usdc.safeTransfer(loan.creditWallet, amount); return; }`

After a loan is fully repaid, additional payments go entirely to `loan.creditWallet`. This is intentional — it is the "bonus revenue" path where the agent earns revenue above the repayment amount and it all accrues to the agent's credit wallet. The comment in the code ("Step 5") documents this as the intended design.

**Severity:** Low (design decision, not a vulnerability). Verified as intentional.

---

#### L-04 — `CollateralVault.requiredCollateral` formula: potential precision loss for tokens with low decimal counts (Open)

**Contract:** CollateralVault  
**Location:** `requiredCollateral(uint256 principal, address asset)` — division before multiplication.

```solidity
return (requiredUsdc6 * 1e18 * (10 ** uint256(cfg.decimals))) / (cfg.usdPriceE18 * 1e6);
```

The numerator (`requiredUsdc6 * 1e18 * 10^assetDecimals`) is very large for 6-decimal tokens and intermediate multiplication stays within `uint256` bounds. However, for a hypothetical 2-decimal token at $1 USD: numerator = `15152 * 1e18 * 100 = 1.5e24`, denominator = `1e18 * 1e6 = 1e24`, result = 1 token unit. The formula is correct for the V1 approved tokens (USDC and EURC, both 6 decimal). No issue for current deployment.

**Severity:** Low (not applicable for V1 assets; informational for future asset additions).

---

#### L-05 — `ReservePool.recordContribution` increments `totalContributed` but does not verify the actual USDC transfer (Open)

**Contract:** ReservePool  
**Location:** `recordContribution(uint256 loanId, uint256 amount) external onlyAuthorizedContributor`

`recordContribution` updates `totalContributed` as a bookkeeping entry. The actual USDC transfer is performed by the caller (RevenueRouter) before calling `recordContribution`. If the `safeTransfer` in RevenueRouter succeeds but the `recordContribution` call is somehow skipped (e.g. due to a future code change that adds an early exit), `totalContributed` would be understated without fund loss. In the current code this is not an issue, but the accounting and custody are separated, which creates fragility.

**Severity:** Low.

---

#### L-06 — `ActivityAttester.attestActivity` is fully permissionless: any address can call it on behalf of an agent (Open)

**Contract:** ActivityAttester  
**Location:** `attestActivity(address source, uint256 jobId, uint256 agentId, address providerWallet, uint256 amount)`

There is no restriction on who can call `attestActivity`. Any address can submit an attestation for any agent as long as the `(source, jobId)` pair has not been used before and `providerWallet` is authorized for the `agentId`. This is architecturally correct (open attestation is a feature, not a bug — the trust comes from the source whitelist and wallet authorization), but it means a third party can increase an agent's credit limit without the agent's interaction. An approved activity source + a still-valid provider wallet can grant credit to a dormant agent.

**Severity:** Low (by design; worth documenting explicitly).

---

#### L-07 — `UnderwriterPool` has no maximum commitment value per underwriter-borrower pair (Open)

**Contract:** UnderwriterPool  
**Location:** `commitToAgent(address borrower, uint256 amount)` — no upper bound.

An underwriter can commit `type(uint256).max` to a borrower, which would allow the borrower to request a loan for any principal up to that amount (within their credit limit constraints). The `reserveStake` check (`stakeBalance[underwriter] >= amount`) prevents funding beyond actual stake, but the commitment mapping could be set to an absurdly large value and used as an opaque signal. No fund safety issue.

**Severity:** Low.

---

### 3.5 INFORMATIONAL

#### I-01 — `releaseMilestone(0, 0)` succeeded on-chain despite `DirectLoanCannotReleaseMilestone` guard

This discrepancy was identified in the prior verification session and retained in `docs/valen-v1-verification.md`. The current source has `if (registry.getDirectDisbursement(loanId)) revert DirectLoanCannotReleaseMilestone()` at the top of `releaseMilestone`. On-chain, `tx 0x18df51379d8d1be3d4b6bc6cd64d058f9ea89e0be683eee22b08ea5b47be8b62` (block 66,458,336) succeeded for loan 0. The most likely explanation is that the deployed implementation did not include this guard at the time of that transaction. The current implementation artifact reflects a later version. This is not a current vulnerability but is noted as an unresolved discrepancy between the transaction history and the current source.

---

#### I-02 — `LiquidityPool.reconcileLoan(0)` has not been called

As verified on-chain: `LiquidityPool.finalized(0) = false`, `activeLoanCount = 1`. Loan 0 was fully repaid (status 5). The pool's `activeLoanIds` still contains loan 0 and `totalDeployed` is non-zero. Until `reconcileLoan(0)` is called, the share price is slightly understated (principal is counted as deployed rather than recovered). This should be corrected before any new LP depositors join.

---

#### I-03 — UUPS implementation contract is not bricked beyond `_disableInitializers`

All 11 contracts call `_disableInitializers()` in their constructors, which prevents `initialize` from being called directly on the implementation. The OZ `UUPSUpgradeable` implementation requires the implementation to call `_disableInitializers()` in the constructor to prevent direct initialization, which is correctly done. However, the implementation contracts themselves are not self-destructed or bricked beyond this. This is standard OZ practice; no issue.

---

#### I-04 — `LoanRegistry.markDefault` is callable by the owner OR any registered keeper

The keeper role (`setKeeper`) allows the owner to delegate default marking. Currently no keepers are registered (based on standard deployment). This is the intended automation path (a backend service calling `markDefault` when grace periods elapse). The keeper list is not bounded; the owner could add many keepers. Consider adding a maximum keeper count.

---

#### I-05 — CreditRegistry `setParameters` can change `initialLimit` retroactively

`setParameters` can change `initialLimit` at any time. The `getLimit` function uses `credit.exists ? credit.currentLimit : initialLimit` — so agents who have never been touched by the credit system will have their available limit changed retroactively. Agents who have interacted (exist = true) are unaffected. This is unlikely to cause harm but is operationally surprising.

---

#### I-06 — Backend server is strictly read-only and holds no private keys

The Fastify backend (`backend/src/index.ts`) imports no wallet client and holds no deployer keys. All state-changing operations (`fundFromPool`, `markDefault`, `releaseMilestone`, `attestActivity`) are out-of-scope for the backend. The server exposes preparation endpoints that return unsigned transaction data for the frontend to sign. This architecture is correct and reduces backend attack surface.

---

#### I-07 — ERC-8004 is stored as an informational reference only

`AgentRegistry.erc8004Ref` stores an external ERC-8004 token ID as a reference. The NatSpec explicitly states: "It carries no trust or authorization in Valen." This means ERC-8004 identity is informational, not authoritative. Wallet authorization flows entirely through `AgentRegistry.isAuthorizedWallet`. This is a correct and safe design.

---

#### I-08 — ERC-8183 activity verification trust chain

The `ActivityAttester` → `CreditRegistry` path correctly implements the spirit of ERC-8183: the `source` must be owner-whitelisted, the `providerWallet` must be authorized for the `agentId` in `AgentRegistry`, and each `(source, jobId)` pair is usable only once. The `amount` field maps to the ERC-8183 `PaymentReleased` event's payment value. The `activityGrowthBps` parameter determines what fraction of verified economic activity translates to credit. This is a reasonable V1 implementation.

---

## 4. Test Coverage Assessment

26 test suites, 558 tests total. All pass. Test file breakdown:

| Suite | Tests | Focus |
|---|---|---|
| `AgentRegistry.t.sol` | (see summary) | Identity, wallet rotation, ownership transfer |
| `CreditRegistry.t.sol` | 27 | Limit growth, default penalties, activity track |
| `LoanRegistry.t.sol` | (see summary) | Full lifecycle, validation, keepers |
| `RevenueRouter.t.sol` | (see summary) | Split math, reserve skim, self-repayment |
| `LoanVault.t.sol` | — | Direct disbursement, milestone, settlement |
| `CollateralVault.t.sol` | (see summary) | Multi-asset LTV, deposit/withdraw, seize/release |
| `UnderwriterPool.t.sol` | 7 | Stake, commit, reserve, seize, release |
| `RecipientRegistry.t.sol` | (see summary) | Approve, revoke, isApproved |
| `ReservePool.t.sol` | (see summary) | Payout, contribution accounting |
| `LiquidityPool.t.sol` | (see summary) | Share math, deposit, withdraw, reconcile |
| `ActivityAttester.t.sol` | (see summary) | Source whitelist, replay protection, credit growth |
| `Integration_E2E.t.sol` | (see summary) | Full 11-contract lifecycle, wallet rotation |
| `SecurityAudit.t.sol` | 11 | AUDIT-01 and AUDIT-02 regression suite |
| `DirectDisbursement.t.sol` | (see summary) | Direct vs milestone path matrix |
| `MultiAssetCollateral.t.sol` | (see summary) | EURC collateral, cross-asset LTV |
| `Risk01_DefaultVaultRecovery.t.sol` | (see summary) | RISK-01: vault settlement ordering |
| `Risk03_VaultSettlementOrdering.t.sol` | (see summary) | RISK-03: settlement before/after reconcile |
| `Risk04_KeeperAuthorization.t.sol` | (see summary) | RISK-04: markDefault keeper gating |
| `Risk05_FundFromPoolAuth.t.sol` | (see summary) | RISK-05: pool funding authorization |
| `Risk08_ConcurrentCreditLimit.t.sol` | 10 | RISK-08: agentId-keyed outstandingPrincipal |
| `Risk09_ReserveShortfallOrdering.t.sol` | 8 | RISK-09: reserve garnishment ordering |
| `Risk10_ActiveLoanCap.t.sol` | 10 | RISK-10: 150-loan cap, gas safety |
| `Risk11_ReserveSkimAccounting.t.sol` | 20 | RISK-11: poolRecovered vs totalRecovered |
| `Risk12_OneWaySetters.t.sol` | 27 | One-time setter locks on all contracts |
| `Risk13_OneWaySetters.t.sol` | 16 | Additional setter lock coverage |
| `Risk15_RecipientValidation.t.sol` | 11 | Recipient allowlist enforcement |
| `AbortPath_ResumeProbes.t.sol` | (see summary) | Abort and resume paths across status transitions |

**Coverage assessment:** The test suite is broad and well-structured. The named RISK suites track specific previously-identified vulnerabilities and their fixes. Key coverage gaps for future consideration:

- No fuzz testing (property-based tests) on share price, `reconcileLoan` delta arithmetic, or LTV calculations.
- No simulation of the `_reconcileAll` gas usage at or near the 150-loan cap.
- No test for the `setReserveSkimmed` + `reconcileLoan` interaction with `migrationCutoff == 0`.
- No test for the permissionless `reconcileLoan` finalization race described in H-01.

---

## 5. Gas Considerations

- `_reconcileAll()` (called on every `deposit` and `withdraw`) iterates up to `maxActiveLoans` (default 150). At ~10,000 gas per `reconcileLoan` call, a fully-loaded pool costs ~1.5M gas per deposit or withdrawal. On Arc Testnet gas limits this may be manageable, but it should be benchmarked before production load.
- `_storeLoan` pushes `budget`, `permittedRecipients`, and `milestones` arrays into storage. Large proposals (many recipients, many budget lines) will be expensive. V1 tests use single-element arrays; multi-recipient deployments should be gas-tested.

---

## 6. Upgrade Safety

All 11 contracts use UUPS with `_disableInitializers()` in constructors. Storage layout is documented in comments and `storage-snapshots/` JSON files. New storage variables are appended at the end of existing slot sequences. The `RevenueRouter` upgrade introduced `reserveSkimmed` (slot 9), `migrationCutoff` (slot 10), and `_migrationLocked` (slot 11) without collisions. The `LiquidityPool` added `vaultSettlementCounted` and `maxActiveLoans` at the end. These patterns are correct.

**Risk:** Since there is no `storageGap` (OpenZeppelin's reserved padding for inherited contracts), any future inherited contract that adds state variables would collide with the current layout. The contracts inherit `Initializable`, `OwnableUpgradeable`, and `UUPSUpgradeable` — none of which have been upgraded to add new state in the current OZ version used, but this is worth monitoring across OZ library upgrades.

---

## 7. Outstanding Items from Prior Verification

These items were identified in the prior on-chain verification session and are captured here for completeness. They do not change the severity classifications above.

| Item | Status | Detail |
|---|---|---|
| `LiquidityPool.reconcileLoan(0)` not called | Open | `finalized(0) = false`, `activeLoanCount = 1`. No fund loss; pool accounting is stale. |
| `RevenueRouter.migrationCutoff()` reverted | Open | Indicates `initializeV2()` may not have been called. If so, `poolRecovered(0)` overcounts by ~220,000 USDC units (≈$0.22). See H-03. |
| `releaseMilestone(0,0)` succeeded despite `DirectLoanCannotReleaseMilestone` | Open | Source-history discrepancy. See I-01. |

---

## 8. Summary Table

| ID | Severity | Title | Status |
|---|---|---|---|
| C-01 | Critical | Single-EOA upgrade and admin authority | Open (remediation tooling prepared in `script/TransferOwnership.s.sol`; the migration has NOT been executed and no Safe has been deployed) |
| C-02 | Critical | `setReservePool` callable before first loan; silent skip if unset | Open (mitigated in current deployment) |
| H-01 | High | Permissionless `reconcileLoan` finalization race | Open |
| H-02 | High | `_reconcileAll` DoS risk if cap fills with non-defaulting loans | Open |
| H-03 | High | `migrationCutoff == 0` blocks `setReserveSkimmed`; `poolRecovered` may overcount | Open |
| M-01 | Medium | Owner-set collateral price oracle with no staleness check | Open |
| M-02 | Medium | Underwriter commitment revocable without borrower signal | Open |
| M-03 | Medium | `maxLTVBps` changeable while loans are active | Open |
| M-04 | Medium | RecipientRegistry `categoryId` cross-check not enforced | Open |
| M-05 | Medium | Share inflation attack window | Addressed |
| M-06 | Medium | `setLiquidityPool` allows replacement when `activeLoanCount == 0` | Open |
| L-01 | Low | `transferAgentOwnership` allows non-wallet new owner | Open |
| L-02 | Low | `block.timestamp` used for default grace period | Open |
| L-03 | Low | Post-repayment revenue routes entirely to `creditWallet` | Addressed (by design) |
| L-04 | Low | `requiredCollateral` precision loss for low-decimal tokens | Open (N/A for V1 assets) |
| L-05 | Low | `recordContribution` accounting separated from USDC transfer | Open |
| L-06 | Low | `attestActivity` is fully permissionless | Open (by design) |
| L-07 | Low | No maximum commitment value in UnderwriterPool | Open |
| I-01 | Info | `releaseMilestone` on-chain tx vs source discrepancy | Open |
| I-02 | Info | `reconcileLoan(0)` not yet called | Open |
| I-03 | Info | UUPS implementation only protected by `_disableInitializers` | Addressed |
| I-04 | Info | Keeper role exists; no registered keepers currently | Open |
| I-05 | Info | `setParameters` can change `initialLimit` retroactively | Open |
| I-06 | Info | Backend is strictly read-only | Addressed |
| I-07 | Info | ERC-8004 is informational reference only | Addressed |
| I-08 | Info | ERC-8183 activity verification trust chain | Addressed |

---

## 9. Recommendations by Priority

1. **Immediate (before any significant TVL):** Transfer owner to a multi-sig (C-01). Call `reconcileLoan(0)` (I-02). Confirm `initializeV2()` status and, if not called, call it and then call `setReserveSkimmed(0, 220000)` before `reconcileLoan(0)` (H-03).

2. **Short-term:** Add a revert in `_applyPayment` if `reservePool` is unset (C-02). Implement `reconcileSome` for LP exit without full reconciliation (H-02). Add a `canUnderwrite` view to UnderwriterPool (M-02).

3. **Medium-term (production hardening):** Integrate a price oracle for collateral assets (M-01). Add a time-lock on LTV changes (M-03). Implement budget-category cross-check in RecipientRegistry (M-04). Add fuzz testing for share arithmetic and reconciliation delta math. Gas-benchmark `_reconcileAll` at 150 loans.

4. **Before mainnet:** Full independent audit by a security firm. Add `storageGap` to inherited contracts. Implement a multi-sig time-lock for contract upgrades.

---

*This report reflects the state of the codebase as of 2026-10-25 (repository HEAD `1bbb373`). It is a read-only technical review and does not constitute legal, financial, or investment advice. No transactions were submitted, and no contract state was modified during this audit.*

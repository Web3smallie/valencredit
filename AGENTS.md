# Valen V1 — Agent and Operator Reference

This file is the authoritative record of deployed addresses, ownership state,
and operational procedures for the Valen V1 protocol on Arc Testnet.
It is maintained alongside the codebase and must be updated after any
ownership transfer, upgrade, or material configuration change.

---

## Network

| Parameter | Value |
|-----------|-------|
| Chain     | Arc Testnet |
| Chain ID  | 5042002 |
| RPC       | https://rpc.testnet.arc.io |
| Explorer  | https://explorer.testnet.arc.io |
| USDC      | 0x3600000000000000000000000000000000000000 (6 decimals) |

---

## Deployed Proxy Addresses (Arc Testnet)

All contracts are UUPS proxies (OZ v5.7.0).  
Current owner of all 11 proxies: **deployer EOA** `0xB0E8Ba6aFe21371AD4001e611224FC200FD10144`  
(Pending migration to Safe multisig — see Ownership below.)

| Contract | Proxy Address | Implementation Address |
|----------|--------------|----------------------|
| AgentRegistry | `0xeC74944752Fff0f53Af5b727F288f59435C0144e` | `0x797e0fcc4d05e2c606cc66c484418b602951cced` |
| CreditRegistry | `0x258B0678b30E2d32034389cfeCa7f58fE1CeB897` | `0xf400dadaf8b01d16f5da65a2769a6b6e60dee1cd` |
| LoanRegistry | `0x253B68c7a2D646561387Dc0958A6C176a30a6f8d` | `0xd47496361e5c485611718bd06065971691d2ba07` |
| RevenueRouter | `0xE0B9b39E72f73f2d85D77a1e24a2f319246de822` | `0x394d9f57f00f27b19b1549e23021efed9cd7be38` |
| LoanVault | `0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19` | `0xa698d80e5caf0b4b5033cd8091f1a37f98534537` |
| CollateralVault | `0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f` | `0x9c1b6819b32615ca4d28d41be2a10303425b9ba5` |
| UnderwriterPool | `0x23307d061dad8335995080518B73A839Ffe69E7A` | `0x49b018d11b869d7964c2c560c5dd233e64f2aa32` |
| RecipientRegistry | `0xf8E069B659CEAf9c68318041D727b5c482Ac6374` | `0xe10598c039dd26609e0758bf737a68c9fae15f54` |
| ReservePool | `0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD` | `0x9d488e961bdcb2fb00bfb7984605d3c00dae7dd7` |
| LiquidityPool | `0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061` | `0x828525794b195329e8f1ae501a61d7590df542c1` |
| ActivityAttester | `0x2660044E4A7316B65263ea1B23b80aAf09841196` | `0x6e119483041ff34b72db722b1c6cd2324b036dd4` |

---

## Ownership

### Current state
All 11 proxies owned by deployer EOA: `0xB0E8Ba6aFe21371AD4001e611224FC200FD10144`

### Planned multisig (C-01 remediation)
Target: 2-of-3 Safe multisig on Arc Testnet.

**Safe address:** `<TO BE FILLED IN — after Safe deployment and independent verification>`  
**Signer 1 (laptop wallet):** `<TO BE FILLED IN — public address only, never private key>`  
**Signer 2 (phone wallet):** `<TO BE FILLED IN — public address only, never private key>`  
**Signer 3 (sister's wallet):** `<TO BE FILLED IN — public address only, never private key>`  

Migration script: `script/TransferOwnership.s.sol`  
See that script's NatSpec for the full execution checklist.

### Migration transaction hashes
`<TO BE FILLED IN — after broadcast and on-chain confirmation>`  
Record at least one representative transferOwnership tx hash and block number here.

### Post-migration functional test
`<TO BE FILLED IN — Safe transaction hash for the RecipientRegistry.approveRecipient test call>`

---

## Safe Infrastructure on Arc Testnet

Canonical Safe v1.4.1 contracts verified deployed (confirmed via eth_getCode):

| Contract | Address | Code size |
|----------|---------|-----------|
| CREATE2 factory (Arachnid) | `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` | 78 bytes |
| SafeProxyFactory v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | 3,054 bytes |
| Safe singleton L2 v1.4.1 | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | 24,421 bytes |
| Safe singleton L1 v1.4.1 | `0x41675C099F32341bf84BFc5382aF534df5C7461a` | 23,579 bytes |
| CompatibilityFallbackHandler v1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | 5,637 bytes |
| MultiSend v1.4.1 | `0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526` | 629 bytes |
| MultiSendCallOnly v1.4.1 | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` | 410 bytes |
| SignMessageLib v1.4.1 | `0xd53cd0aB83D845Ac265BE939c57F53AD838012c9` | 966 bytes |
| CreateCall v1.4.1 | `0x9b35Af71d77eaf8d7e40252370304687390A1A52` | 1,099 bytes |

Use the **L2 singleton** (`0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`) when deploying
the Safe instance. Arc Testnet is an EVM L2; the L2 singleton emits the additional
events that Safe indexing infrastructure expects on L2 chains.

---

## Operational Procedures (Post-Migration)

### All onlyOwner calls require Safe transactions
Every `onlyOwner` function across all 11 contracts requires a 2-of-3 Safe
transaction after migration. Common operations include:

- `RecipientRegistry.approveRecipient / revokeRecipient` — vendor onboarding
- `ActivityAttester.setActivitySource` — ERC-8183 source authorization
- `CollateralVault.setAssetConfig` — collateral asset price updates
- `CreditRegistry.setParameters / setAuthorizedCaller` — credit model changes
- `LoanRegistry.setKeeper` — keeper registration (see below)

### fundFromPool — keeper path available
`LoanVault.fundFromPool` permits `msg.sender == owner() || registry.keepers(msg.sender)`.  
Register a keeper EOA once via a Safe transaction:
```
LoanRegistry.setKeeper(<keeperAddress>, true)
```
After that, the keeper EOA can call `fundFromPool` directly without Safe co-signing.

### releaseMilestone — Safe co-signing required
`LoanVault.releaseMilestone` for pool-funded loans checks:
```solidity
msg.sender == OwnableUpgradeable(liquidityPool).owner()
```
After migration this resolves to the Safe address. There is no keeper bypass for
this path. Milestone releases on pool-funded loans with `directDisbursement=false`
require a Safe transaction.

Note: all collateral-backed loans enforce `directDisbursement=true` at proposal
time (`CollateralizedLoanMustUseDirectDisbursement`), so the milestone path is
only reachable by unsecured or underwriter-backed pool loans.

### Upgrades
1. Build and validate the new implementation locally:
   ```
   forge build
   forge script script/UpgradeV4.s.sol --sig "validateImplementations()" --rpc-url https://rpc.testnet.arc.io
   ```
2. ABI-encode the `upgradeToAndCall(newImpl, calldata)` calldata:
   ```
   cast calldata "upgradeToAndCall(address,bytes)" <newImpl> <initCalldata>
   ```
3. Propose the encoded calldata as a Safe transaction targeting the proxy address.
4. Collect 2-of-3 signatures from the three signers.
5. Execute.

The existing upgrade scripts (`UpgradeV4.s.sol`, `UpgradeRevenueRouter.s.sol`)
cannot be broadcast directly via `--account valen-deployer` after migration
(the deployer is no longer the owner). Use them for local validation only;
execute upgrades through the Safe.

---

## Test Agent

| Parameter | Value |
|-----------|-------|
| Agent wallet | `0x786d491fb520f3d9d9c7e62156c879fe52d6921e` |
| Agent ID | 1 |
| Collateral token (EURC) | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| Loan 0 | principal=10000000 USDC, repaid (status=5) |

---

## Open Items

- `LiquidityPool.finalized(0)` is `false` and `activeLoanCount = 1`:
  `reconcileLoan(0)` has not been called. Call this (via Safe after migration)
  after confirming `RevenueRouter.initializeV2()` status (see verification report).
- `RevenueRouter.migrationCutoff()` call reverted in the verification session:
  `initializeV2()` status unconfirmed. Investigate before calling `setReserveSkimmed`.
  See `docs/valen-v1-verification.md` for full details.

---

## Audit

Full audit report: `docs/valen-v1-audit.md`  
V1 on-chain verification report: `docs/valen-v1-verification.md`

# VALEN

### Credit for AI Agents. Earned Through Economic Activity.

**The programmable credit protocol for the autonomous economy.**

[![Built on Arc](https://img.shields.io/badge/Built%20on-Arc-6554C0)](https://arc.network/)
[![Solidity](https://img.shields.io/badge/Solidity-Smart%20Contracts-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Toolchain-Foundry-orange)](https://getfoundry.sh/)
[![USDC](https://img.shields.io/badge/Settlement-USDC-2775CA)](https://www.circle.com/usdc)
[![ERC-8004](https://img.shields.io/badge/Identity-ERC--8004-blue)](https://eips.ethereum.org/EIPS/eip-8004)
[![ERC-8183](https://img.shields.io/badge/Commerce-ERC--8183-purple)](https://eips.ethereum.org/)

**Repository:** [Web3smallie/valencredit](https://github.com/Web3smallie/valencredit)

---

## The Problem: AI Agents Can Generate Value, but Can They Access Credit?

AI agents are evolving from tools that answer questions into autonomous economic actors that execute tasks, purchase services, interact with protocols, and generate revenue.

But financial infrastructure was not designed for them.

Traditional credit systems rely on human identities, conventional credit scores, and financial histories that autonomous software does not naturally possess.

A newly deployed agent might be capable of completing valuable work, receiving payments, and generating revenue. Yet its wallet does not automatically communicate that economic history to a lending protocol.

The result is a fundamental mismatch:

* **Economic capability does not automatically translate into creditworthiness.**
* **A wallet balance is not the same as a credit history.**
* **Verified revenue can be more informative than an arbitrary starting balance.**
* **Changing an operational wallet should not necessarily erase an agent's accumulated financial history.**
* **Lending to autonomous systems requires programmable rules, transparent accounting, and enforceable repayment mechanics.**

As more commerce moves toward autonomous execution, agents will need more than wallets.

They will need financial infrastructure that understands their identity, activity, obligations, and repayment history.

## The Solution: Valen

**Valen is a programmable credit and lending protocol for independently created AI agents.**

Valen connects persistent agent identity, verified economic activity, credit-limit management, programmable lending, milestone-based disbursement, and on-chain repayment into a unified financial system.

Instead of treating every new wallet as an entirely unknown borrower, Valen maintains credit history against a persistent Valen `agentId`.

An agent's credit profile can incorporate its repayment record and verified economic activity. That history informs its available credit, subject to protocol rules and risk controls.

The fundamental idea is simple:

> **An AI agent should be able to build financial credibility through what it demonstrably earns and repays.**

Valen does not create, own, or operate the agents that use it. It provides the financial infrastructure through which independently developed agents can access programmable credit.

### The Valen credit cycle

```text
      INDEPENDENT AI AGENT
                |
                v
       REGISTER IDENTITY
                |
                v
       ESTABLISH CREDIT PROFILE
                |
                v
       REQUEST PROGRAMMABLE LOAN
                |
                v
       VALIDATE CREDIT & TERMS
                |
                v
       FUND APPROVED LOAN
                |
                v
       EXECUTE ECONOMIC WORK
                |
                v
       GENERATE VERIFIABLE REVENUE
                |
                v
       REPAY THROUGH VALEN
                |
                v
       UPDATE CREDIT HISTORY
                |
                v
       INFORM FUTURE CREDIT DECISIONS
                |
                +--------------------+
                                     |
                                     v
                              NEXT CREDIT CYCLE
```

This is the foundation of an agent-native financial system in which credit capacity can respond to verifiable economic behavior rather than remain permanently tied to an initial wallet balance.

---

## Why Valen Is Different

### 1. Credit belongs to an agent identity, not merely a wallet

Wallets are operational accounts. They are not necessarily durable representations of an economic actor.

Valen introduces its own persistent `agentId` through `AgentRegistry`.

The registry associates an agent identity with its owner and authorized wallets. Credit records are scoped to the agent identity, allowing authorized wallet changes without automatically resetting the agent's financial history.

This separates two concepts that should not be confused:

* **Identity:** The persistent entity whose financial history is maintained.
* **Wallet:** An authorized address used to interact with the protocol.

Valen also integrates with ERC-8004, the Ethereum standard for AI agent identity, reputation, and validation.

ERC-8004 provides an external identity reference. Valen's own `agentId` remains distinct from the ERC-8004 token ID, so the two identity systems are not interchangeable.

This distinction allows Valen to maintain its own credit-accounting rules without making its internal credit history dependent on the transferability of an external identity NFT.

### 2. Economic activity can contribute to credit capacity

An agent's ability to complete paid work can provide evidence relevant to its financial profile.

Valen's activity-verification architecture integrates with ERC-8183, the Agentic Commerce Protocol.

ERC-8183's `PaymentReleased` event provides an on-chain signal that a provider received payment for completed work.

Valen's `ActivityAttester` is designed to accept activity attestations from authorized attesters, validate the approved source and agent-wallet relationship, prevent duplicate activity records, and record verified activity in the credit system.

The intended flow is:

```text
Agent completes paid work
          |
          v
ERC-8183 job reaches payment release
          |
          v
PaymentReleased event
          |
          v
Authorized activity attester
          |
          v
Validate approved source
          |
          v
Validate agent wallet authorization
          |
          v
Reject duplicate activity evidence
          |
          v
Record verified economic activity
          |
          v
Update agent credit profile
```

**Why this matters:** Credit decisions can incorporate evidence of economic performance, rather than relying exclusively on an agent's existing token balance.

An on-chain payment event is not, by itself, proof of profitability, future repayment, or freedom from fraud. Valen uses verified activity as one input into its credit model, not as a guarantee that every agent deserves a loan.

### 3. Credit capacity can evolve over time

Valen's credit model is designed to account for both repayment behavior and verified economic activity.

Its V1 design specifies:

* Credit history maintained against a persistent agent identity.
* Credit capacity informed by repayment performance.
* Activity-derived credit increases subject to protocol-defined limits.
* Exposure tracking to account for outstanding principal.
* Credit reductions in response to qualifying defaults.
* Persistent historical records of verified activity and repayments.

The implementation specification defines an activity-growth rate of 500 basis points, or 5%, and a maximum activity-derived credit increase of 500 USDC per event.

It also specifies a lifetime ceiling of 50,000 USDC for the activity-derived component.

These are protocol design parameters, not a promise that every agent will receive those amounts. Actual credit availability depends on the deployed implementation, the agent's state, and the applicable contract rules.

### 4. Lending is programmable and enforceable on-chain

Valen is not simply a system that assigns an agent a credit score.

It connects credit validation to actual lending operations.

A loan request specifies terms and conditions that the protocol can validate. The loan lifecycle is represented in contract state, while funding, collateral handling, milestone releases, and repayment are executed through dedicated components.

This creates a foundation for programmable credit facilities that can be integrated into agent applications and autonomous commerce workflows.

### 5. Revenue and repayment can follow explicit rules

Valen includes `RevenueRouter` to coordinate revenue-related repayment flows.

The design supports routing funds toward outstanding debt and returning surplus funds to the designated agent credit wallet according to the applicable repayment rules.

Rather than treating repayment as an informal promise, the protocol provides on-chain mechanisms for accounting and settlement.

Valen's credit model and repayment mechanics are designed to reinforce one another: repayment history becomes part of the agent's financial record, which can inform future credit decisions.

### 6. Multiple capital and risk-management components

Valen's architecture includes dedicated components for liquidity, collateral, underwriting, recipient validation, and reserves.

These include:

| Component           | Responsibility                                                                |
| ------------------- | ----------------------------------------------------------------------------- |
| `AgentRegistry`     | Maintains Valen agent identities and authorized wallets.                      |
| `CreditRegistry`    | Maintains credit records, limits, and relevant credit-history data.           |
| `LoanRegistry`      | Manages loan records, terms, and loan-state validation.                       |
| `LoanVault`         | Coordinates loan funding and milestone disbursement mechanics.                |
| `CollateralVault`   | Manages collateral associated with supported loan arrangements.               |
| `LiquidityPool`     | Supports pool-funded lending and liquidity accounting.                        |
| `UnderwriterPool`   | Provides underwriting-related protocol functionality.                         |
| `RecipientRegistry` | Controls which recipient addresses are approved for relevant loan operations. |
| `ReservePool`       | Supports reserve-related accounting and contribution flows.                   |
| `RevenueRouter`     | Coordinates revenue routing and loan repayment.                               |
| `ActivityAttester`  | Records authorized attestations of verified economic activity.                |

These components form the foundation for a modular lending protocol rather than placing every financial responsibility inside one oversized contract.

---

## How Valen Works

### Step 1 — An independent agent establishes its identity

An agent registers through `AgentRegistry` and receives a persistent Valen `agentId`.

The identity is associated with an owner and authorized wallet addresses.

The agent can use the identity to maintain a consistent credit record across supported wallet changes.

ERC-8004 is part of Valen's identity integration, but the Valen `agentId` remains the identifier used for Valen's internal credit history.

### Step 2 — Valen evaluates the agent's credit position

The credit system maintains the information needed to determine available credit under protocol rules.

Depending on the agent's history, the credit profile can incorporate:

* Current credit capacity.
* Verified economic activity.
* Repayment history.
* Outstanding exposure.
* Relevant default outcomes.

The credit registry and loan registry work together to ensure loan requests are evaluated against the applicable credit constraints.

### Step 3 — The agent requests a loan

The agent submits a loan proposal specifying the requested amount, repayment terms, relevant collateral information, recipient details, and milestone instructions supported by the protocol.

The protocol validates the proposal against its rules.

A request is not equivalent to an approved or funded loan: the relevant checks and funding operations must succeed.

### Step 4 — The loan is funded

Valen supports a lending architecture that includes pool-funded loans and dedicated loan-vault operations.

Where the required pool configuration and liquidity are available, the loan can be funded through the supported pool pathway.

Funding is recorded on-chain, providing an auditable record of the loan operation.

### Step 5 — Funds are released according to the loan structure

Valen includes milestone-based disbursement functionality.

Rather than assuming every loan must be disbursed in one unrestricted transfer, the protocol can represent approved milestones and release funds through its configured loan mechanics.

This provides a foundation for loans tied to specific work or operational requirements.

### Step 6 — The agent generates economic activity

An agent can operate independently of Valen and earn revenue through supported external services or commerce protocols.

Where the activity-verification path is configured and supported, ERC-8183 payment-release evidence can be submitted through authorized attestation mechanisms.

Valen does not need to own the agent or operate the marketplace where the agent earns revenue.

### Step 7 — Verified activity informs credit capacity

The authorized attestation process checks the relevant source and wallet authorization, applies duplicate-prevention rules, and records the accepted activity against the agent's identity.

The credit system can then account for that activity according to its configured growth rules and limits.

### Step 8 — The agent repays its loan

The agent can repay through the supported repayment flow.

`RevenueRouter` coordinates applicable repayment accounting, including routing funds toward the outstanding obligation and handling any surplus according to the protocol's rules.

Successful repayment contributes to the agent's financial history.

### Step 9 — The agent builds a financial track record

Over successive credit cycles, the agent's financial profile can reflect its verified activity, repayment behavior, and default history.

This creates the foundation for a system in which access to credit can become more responsive to demonstrated economic behavior.

---

## Architecture

Valen separates identity, credit evaluation, loan state, capital management, revenue routing, and activity verification into distinct contract responsibilities.

```text
                    EXTERNAL AI AGENT
                            |
                            v
                     AgentRegistry
                            |
                            v
                     CreditRegistry
                            ^
                            |
                      LoanRegistry
                            |
                            v
                        LoanVault
                       /         \
                      v           v
               LiquidityPool  CollateralVault
                      |
                      v
                 Loan Funding


EXTERNAL PAID WORK
        |
        v
ERC-8183 PaymentReleased
        |
        v
ActivityAttester <---- Approved Sources
        |
        v
CreditRegistry
        |
        v
Agent Credit Profile


AGENT REPAYMENT
        |
        v
RevenueRouter
        |
        +------> Outstanding Loan / Lender
        |
        +------> Agent Credit Wallet (applicable surplus)
        |
        v
Credit History Updates
```

### Architectural principles

**Persistent identity:** Credit history is associated with an agent identity rather than being inherently tied to one operational address.

**Explicit trust boundaries:** Activity attestation relies on authorized attesters and approved source contracts. The protocol's on-chain validation and duplicate-prevention mechanisms do not eliminate every off-chain trust assumption.

**Separation of responsibilities:** Identity, credit, loan state, liquidity, collateral, revenue routing, and activity verification are handled by distinct components.

**Programmable enforcement:** Financial operations are governed by smart-contract state and validation rules.

**Composable integrations:** ERC-8004 and ERC-8183 connect Valen to emerging standards for agent identity and agentic commerce.

**Auditable execution:** Relevant financial operations and accepted state changes can be inspected through on-chain transactions and events.

---

## Technology Stack

| Technology   | Role                                                                  |
| ------------ | --------------------------------------------------------------------- |
| Arc          | Blockchain settlement environment for Valen's deployment and testing. |
| Solidity     | Smart-contract implementation language.                               |
| Foundry      | Contract compilation, testing, deployment, and development tooling.   |
| USDC         | Stablecoin used in the lending and settlement design.                 |
| ERC-8004     | External agent identity, reputation, and validation standard.         |
| ERC-8183     | Agentic commerce standard and economic-activity evidence path.        |
| UUPS proxies | Upgradeable contract architecture used by the deployment.             |

### Why Arc?

Valen is designed around programmable financial operations that need clear settlement, transparent accounting, and integration with stablecoin-based applications.

Arc provides the environment in which Valen's smart contracts can coordinate those operations.

### Why USDC?

A stablecoin-denominated credit system makes loan amounts and repayment obligations easier to express in familiar monetary units than a system whose principal is denominated entirely in a volatile native asset.

The actual risk of a loan still depends on creditworthiness, collateral, liquidity, contract security, and repayment performance.

---

## Smart Contract Design

### AgentRegistry

Provides a persistent Valen identity for each registered agent.

Its responsibilities include:

* Registering agents.
* Maintaining agent ownership.
* Associating authorized wallets with an agent identity.
* Supporting authorized wallet changes.
* Maintaining the external ERC-8004 identity reference.

The Valen identity is separate from the external ERC-8004 token ID.

### CreditRegistry

Maintains the credit information used by the protocol.

Its design includes:

* Agent-scoped credit records.
* Credit-limit accounting.
* Repayment-history tracking.
* Verified activity contributions.
* Protocol-defined activity growth limits.
* Credit adjustments associated with qualifying default outcomes.

Credit availability is subject to the implemented rules and the agent's current financial state.

### LoanRegistry

Coordinates loan requests and records loan state.

It validates loan proposals against relevant credit and protocol requirements, maintains loan records, and connects the lending lifecycle to the other required components.

### LoanVault

Handles loan-related funding and disbursement operations.

It coordinates supported loan-funding pathways and milestone releases while interacting with the loan registry and relevant capital-management components.

### LiquidityPool

Supports pool-funded lending.

The pool's available liquidity, configuration, and accounting determine whether a proposed pool-funded loan can proceed.

### CollateralVault

Handles collateral associated with supported lending arrangements.

Collateral requirements and enforcement depend on the relevant loan terms and deployed contract rules.

### UnderwriterPool

Provides the underwriting-related functionality represented in Valen's contract architecture.

### RecipientRegistry

Maintains approval information for recipient addresses used in relevant loan operations.

This adds a protocol-level control to the destinations to which loan funds can be directed.

### ReservePool

Supports reserve-related accounting and contribution mechanisms within the lending architecture.

### RevenueRouter

Coordinates revenue routing and repayment.

Its responsibilities include handling supported repayment operations, routing funds according to applicable loan obligations, and coordinating credit-history updates when repayment conditions are satisfied.

### ActivityAttester

Connects verified external economic activity to Valen's credit system.

Its design includes:

* Authorized activity attestation.
* Approved-source validation.
* Agent-wallet authorization checks.
* Duplicate-attestation prevention.
* Recording accepted activity against an agent identity.

The trust model includes an authorized attester. The existence of a `PaymentReleased` event does not independently prove every aspect of an agent's economic performance.

---

## Deployment

Valen V1 has been deployed to Arc Testnet.

The following addresses were recovered from the project's saved deployment records. They are provided as deployment references and should be checked against the current chain state before use.

**Network:** Arc Testnet
**Chain ID:** `5042002`

| Contract          | Proxy address                                |
| ----------------- | -------------------------------------------- |
| AgentRegistry     | `0xeC74944752Fff0f53Af5b727F288f59435C0144e` |
| CreditRegistry    | `0x258B0678b30E2d32034389cfeCa7f58fE1CeB897` |
| LoanRegistry      | `0x253B68c7a2D646561387Dc0958A6C176a30a6f8d` |
| RevenueRouter     | `0xE0B9b39E72f73f2d85D77a1e24a2f319246de822` |
| LoanVault         | `0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19` |
| CollateralVault   | `0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f` |
| UnderwriterPool   | `0x23307d061dad8335995080518B73A839Ffe69E7A` |
| RecipientRegistry | `0xf8E069B659CEAf9c68318041D727b5c482Ac6374` |
| ReservePool       | `0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD` |
| LiquidityPool     | `0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061` |
| ActivityAttester  | `0x2660044E4A7316B65263ea1B23b80aAf09841196` |

**Important:** These are the addresses recovered from the October 7 deployment record. Verify the current proxy addresses, implementation versions, and configuration before integrating with them. Do not assume that historical addresses reflect subsequent upgrades or deployment changes.

---

## Getting Started

### Prerequisites

Install the following tools:

* Git
* Foundry
* Node.js and npm, if required by the scripts or auxiliary tooling
* An Arc Testnet RPC endpoint
* A funded Arc Testnet account for deployment and testing

### 1. Clone the repository

```bash
git clone https://github.com/Web3smallie/valencredit.git
cd valencredit
```

### 2. Install Foundry dependencies

```bash
forge install
```

If the repository already contains its dependencies, use the project's documented dependency setup rather than reinstalling them unnecessarily.

### 3. Configure the network

Inspect the repository's `foundry.toml` and deployment scripts to confirm that the `arc_testnet` RPC alias is configured.

A typical Foundry configuration uses an RPC endpoint such as:

```text
https://rpc.testnet.arc.network
```

Use your own environment configuration when appropriate. Never commit private keys, keystore passwords, or other secrets to GitHub.

### 4. Compile the contracts

```bash
forge build
```

### 5. Run the test suite

```bash
forge test
```

For more detailed output:

```bash
forge test -vvv
```

Review the actual test results and any environment-specific failures before reporting a test count or claiming that every test passes.

### 6. Inspect deployed contract state

Use Foundry's `cast` tool to query a verified deployment.

For example:

```bash
cast chain-id --rpc-url https://rpc.testnet.arc.network
```

To check a known contract's code:

```bash
cast code <CONTRACT_ADDRESS> \
  --rpc-url https://rpc.testnet.arc.network
```

To inspect a contract's state, use the relevant view function and ABI signature from the deployed implementation.

### 7. Deploy only when necessary

The deployment script is located at:

```text
script/Deploy.s.sol
```

Review the script and network configuration before broadcasting a deployment. Existing testnet deployments should be verified and reused where appropriate; a new deployment is not necessary simply to recover a historical transaction hash.

---

## Testing and Verification

Valen's functionality should be evaluated at multiple levels.

### Contract-level tests

Test individual components and their interactions, including:

* Agent registration and wallet authorization.
* Credit-limit validation.
* Loan proposal validation.
* Recipient approval.
* Pool liquidity and funding.
* Collateral operations.
* Milestone disbursement.
* Revenue routing.
* Repayment accounting.
* Activity attestation and duplicate prevention.
* Default and recovery behavior.
* Authorization boundaries and invalid transitions.

### Integration tests

Verify that the contracts are wired together correctly and that permissions, dependencies, and configuration support the intended flows.

A contract can compile successfully while still being misconfigured for production-like use. Deployment and integration verification therefore matter independently of compilation.

### End-to-end verification

A meaningful end-to-end test should demonstrate the relevant sequence of state changes and their transaction receipts.

For example:

1. Register an agent.
2. Configure the required recipient and liquidity settings.
3. Request a loan within the agent's available credit.
4. Fund the loan through a supported pathway.
5. Execute the relevant milestone release.
6. Repay the loan through the configured repayment flow.
7. Verify the resulting balances, loan status, and credit-history changes.

Where the activity-credit path is included, separately verify that accepted economic-activity evidence updates the intended agent's credit record and that duplicate evidence cannot be counted twice.

**Evidence matters:** Successful compilation, passing unit tests, deployment transactions, and successful end-to-end execution are different forms of verification. Report each accurately.

---

## Security and Risk Considerations

Valen handles financial operations through smart contracts. Its security assumptions and limitations must be understood before funds are put at risk.

### Authorization

Administrative operations and sensitive financial transitions must enforce the intended caller permissions.

### Credit-limit enforcement

Loan requests must respect the applicable credit limits and outstanding exposure constraints.

### Repayment integrity

Repayment calculations and loan-state transitions must prevent underpayment from being treated as full repayment and prevent a closed or settled loan from being paid twice.

### Default handling

Default, expiry, settlement, and recovery transitions must have explicit and mutually consistent rules. Funds must not become permanently inaccessible because one transition makes another required recovery operation impossible.

### Liquidity accounting

Pool-funded lending requires correct accounting for assets, outstanding loans, repayments, and recoveries.

### Activity verification

The attestation model depends on authorized attesters and approved activity sources. Administrative compromise or incorrect source configuration can undermine the reliability of accepted evidence.

Duplicate prevention helps stop the same activity record from being credited repeatedly, but does not independently prove that an underlying economic activity is profitable or free of fraud.

### Upgradeability

Upgradeable contracts introduce administrative trust and operational risk. Implementation changes should be reviewed, tested, and verified against the deployed proxy addresses.

### Testnet status

The listed deployment is for Arc Testnet. It should not be interpreted as evidence that Valen is ready for unrestricted mainnet lending.

**Valen should not be used to manage production funds until the deployed versions, access controls, loan-state transitions, liquidity accounting, and recovery paths have been independently reviewed and verified.**

---

## Current Scope

Valen's core scope is programmable lending for independent AI agents.

It is not intended to be:

* An AI agent marketplace.
* A service that creates or owns agents.
* A centralized directory of agent products.
* A general-purpose AI framework.
* A replacement for every identity or reputation standard.
* A guarantee that an agent will repay its debts.

Its purpose is to provide financial infrastructure that external agents can use as they participate in an increasingly autonomous economy.

---

## Roadmap

The following are potential development directions, not claims that every capability is already implemented.

### Phase 1 — Core programmable credit

* Persistent agent identity.
* Agent-scoped credit records.
* Loan proposal validation.
* Pool-funded lending.
* Collateral and milestone operations.
* Revenue routing and repayment.
* Credit-history updates.

### Phase 2 — Stronger economic-activity verification

* Production-grade indexing of ERC-8183 payment events.
* More robust verification of event provenance.
* Improved attester operations and monitoring.
* Expanded replay-prevention and audit tooling.
* More comprehensive end-to-end verification of activity-derived credit.

### Phase 3 — Risk and capital efficiency

* More sophisticated underwriting policies.
* Improved liquidity and reserve accounting.
* Better borrower and portfolio risk visibility.
* Expanded recovery and default-management mechanisms.
* Additional controls for lenders and capital providers.

### Phase 4 — Agent-native financial integrations

* Integration with more agentic commerce applications.
* Standardized interfaces for agent credit access.
* Programmable credit policies for different economic activities.
* Integrations with additional settlement and payment systems.
* Stronger verification mechanisms for cross-protocol activity.

The roadmap will depend on testing, security review, integration requirements, and demonstrated demand.

---

## Who Is Valen For?

**AI agent developers**

Give independently operated agents access to programmable financial infrastructure without requiring each application to invent its own credit ledger.

**Agentic commerce protocols**

Explore integrations in which verified payment activity can contribute to a persistent financial profile.

**Liquidity providers and underwriters**

Participate in a lending architecture with explicit loan records, funding mechanics, and accounting responsibilities, subject to the applicable risk and liquidity arrangements.

**Protocol developers**

Build on a modular credit architecture that separates identity, credit policy, lending, settlement, and activity verification.

**Researchers and ecosystem contributors**

Explore how on-chain economic behavior can inform credit allocation for autonomous software.

---

## The Bigger Vision

The next generation of AI agents will not simply retrieve information or generate content. They will transact, purchase services, execute work, and participate in economic systems.

Some will generate revenue before they have established a conventional financial history.

Others will operate through changing wallets, interact with multiple protocols, and need access to capital to execute larger tasks.

The financial system serving these agents will need to answer a new question:

**How should an autonomous economic actor earn access to credit?**

Valen's answer is to build the programmable infrastructure around persistent identity, verifiable economic activity, enforceable obligations, and a financial history that can evolve over time.

The objective is not to promise credit to every agent.

It is to create the foundations for a system in which access to credit can be governed by transparent rules and informed by demonstrated economic behavior.

**Agents need more than the ability to transact. They need a way to establish financial credibility.**

**Valen is building the credit layer for that future.**

---

## Contributing

Contributions that improve security, correctness, testing, documentation, and protocol interoperability are welcome.

Before proposing a substantial change:

1. Review the relevant contract and its access-control assumptions.
2. Understand the impact on loan-state transitions and storage layout.
3. Add tests for normal operation and failure cases.
4. Run the relevant Foundry tests.
5. Document any changes to configuration, deployment, or trust assumptions.

For changes involving upgradeable contracts, storage compatibility and upgrade ordering must be considered explicitly.

## License

See the repository's `LICENSE` file for the applicable license terms.

## Links

* **GitHub:** https://github.com/Web3smallie/valencredit
* **Arc Testnet Explorer:** https://explorer.testnet.arc.io/
* **Arc Testnet RPC:** https://rpc.testnet.arc.io
* **USDC:** https://www.circle.com/usdc
* **ERC-8004:** https://eips.ethereum.org/EIPS/eip-8004
* **Foundry:** https://getfoundry.sh/


---

### Valen

**Credit for AI agents. Earned through economic activity. Governed by programmable rules.**

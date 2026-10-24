// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Risk11 — RevenueRouter reserve-skim accounting
//
// Background (see docs or session notes for full analysis):
//   RevenueRouter._applyPayment deducts a reserveCut from lenderShare on
//   every NON-defaulted repayment and transfers it to the reserve pool.
//   Before this fix, totalRecovered included the reserve cut, so
//   poolRecovered (= totalRecovered - reserveRepaid) overcounted by
//   exactly that cut.  LiquidityPool.reconcileLoan therefore credited
//   more to idleLedger than physically arrived, leaving totalAssets >
//   USDC.balanceOf(pool) after reconcile.  The last depositor could not
//   fully withdraw.
//
//   The fix:
//   - reserveSkimmed[loanId] accumulates reserveCut on non-defaulted payments.
//   - poolRecovered = totalRecovered - reserveRepaid - reserveSkimmed.
//   - setReserveSkimmed(loanId, amount) allows the owner to record the
//     historical skim for loans repaid before the fix was deployed.
//
// Test numbering: 01-13 original design-review tests; 14-20 migration-lock tests.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool} from "../src/ReservePool.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCRisk11 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk11_ReserveSkimAccounting is Test {

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    AgentRegistry     agentReg;
    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditRegistry;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDCRisk11    usdc;

    address owner        = address(this);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address depositor    = address(0x11DE);
    address client       = address(0xC1E4);

    uint256 agentId;

    uint256 constant PRINCIPAL          = 100e6;    // 100 USDC
    uint256 constant TOTAL_DUE          = 115e6;    // 115 USDC (15% total)
    uint16  constant REPAY_RATE_BPS     = 5000;     // 50% split to repayment
    uint16  constant RESERVE_BPS        = 200;      // 2% skim
    uint256 constant POOL_DEPOSIT       = 200e6;    // depositor seeds the pool
    uint256 constant DEFAULT_GRACE      = 3 days;

    // Expected values derived from constants above:
    //   repaymentShare (full repay path) = TOTAL_DUE
    //   reserveCut     = TOTAL_DUE * RESERVE_BPS / 10000 = 115e6 * 2 / 100 = 2_300_000
    //   lenderShare    = TOTAL_DUE - reserveCut = 115e6 - 2_300_000 = 112_700_000
    uint256 constant RESERVE_CUT        = 2_300_000;  // 2.3 USDC
    uint256 constant LENDER_SHARE       = 112_700_000; // 112.7 USDC

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        usdc = new MockUSDCRisk11();

        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        creditRegistry = CreditRegistry(address(new ERC1967Proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2000e6, 2000, 25_000e6, 500, 50e6, 50_000e6))
        )));

        registry = LoanRegistry(address(new ERC1967Proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditRegistry), 1 days, 365 days, DEFAULT_GRACE, 10_000e6))
        )));

        router = RevenueRouter(address(new ERC1967Proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditRegistry), address(usdc)))
        )));

        vault = LoanVault(address(new ERC1967Proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize, (owner, address(registry), address(usdc)))
        )));

        collateralVault = CollateralVault(address(new ERC1967Proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize,
                (owner, address(usdc), address(registry), 6600))
        )));

        underwriterPool = UnderwriterPool(address(new ERC1967Proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize,
                (owner, address(usdc), address(registry)))
        )));

        recipientRegistry = RecipientRegistry(address(new ERC1967Proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        )));

        reservePool = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize,
                (owner, address(usdc), address(registry)))
        )));

        pool = LiquidityPool(address(new ERC1967Proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reservePool), address(vault)
            ))
        )));

        // Wire
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setReservePool(address(reservePool));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);
        reservePool.setAuthorizedContributor(address(router), true);
        registry.setAgentRegistry(address(agentReg));
        router.setAgentRegistry(address(agentReg));
        vault.setLiquidityPool(address(pool));
        recipientRegistry.approveRecipient(creditWallet, keccak256("COMPUTE"), "CW");

        // Seed credit so requestLoan passes the credit-limit check
        vm.prank(address(router));
        creditRegistry.recordRepayment(agentId, 5_000e6, false);

        // Pre-approve token spending for client
        usdc.mint(client, 10_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @notice Simulates the V2 reinitializer being called at upgrade time
    ///         with the router already having `existingLoans` loans recorded.
    ///         Sets migrationCutoff = registry.nextLoanId() at call time.
    ///         Call this AFTER creating any loans that should be eligible for
    ///         migration, and BEFORE creating loans that should NOT be eligible.
    function _simulateUpgrade() internal {
        router.initializeV2();
    }

    function _requestAndFundPoolLoan(bool directDisburse) internal returns (uint256 loanId) {
        // Set 2% reserve skim
        router.setReservePool(address(reservePool), RESERVE_BPS);

        // Owner seeds the pool via initializeLiquidity, then depositor adds more
        uint256 seedAmount = 10e6; // small seed by owner to open the pool
        usdc.mint(owner, seedAmount);
        usdc.approve(address(pool), seedAmount);
        pool.initializeLiquidity(seedAmount);

        // Depositor deposits
        usdc.mint(depositor, POOL_DEPOSIT);
        vm.startPrank(depositor);
        usdc.approve(address(pool), POOL_DEPOSIT);
        pool.deposit(POOL_DEPOSIT);
        vm.stopPrank();

        // Request loan
        uint256[] memory ms = new uint256[](1);
        ms[0] = PRINCIPAL;
        string[] memory descs = new string[](1);
        descs[0] = "full";
        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});

        ILoanRegistry.LoanProposal memory p = ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             PRINCIPAL,
            repaymentRateBps:      REPAY_RATE_BPS,
            totalRepaymentDue:     TOTAL_DUE,
            duration:              30 days,
            purpose:               "test",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      ms,
            milestoneDescriptions: descs,
            collateralAmount:      0,
            collateralAsset:       address(0),
            underwriter:           address(0),
            underwriterAmount:     0,
            directDisbursement:    directDisburse
        });
        vm.prank(borrower);
        loanId = registry.requestLoan(p);

        // Fund from pool
        vault.fundFromPool(loanId);
    }

    function _requestAndFundP2PLoan() internal returns (uint256 loanId, address p2pLender) {
        router.setReservePool(address(reservePool), RESERVE_BPS);

        p2pLender = address(0xFEED);
        usdc.mint(p2pLender, PRINCIPAL);
        vm.prank(p2pLender);
        usdc.approve(address(vault), PRINCIPAL);

        uint256[] memory ms = new uint256[](1);
        ms[0] = PRINCIPAL;
        string[] memory descs = new string[](1);
        descs[0] = "full";
        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});

        ILoanRegistry.LoanProposal memory p = ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             PRINCIPAL,
            repaymentRateBps:      REPAY_RATE_BPS,
            totalRepaymentDue:     TOTAL_DUE,
            duration:              30 days,
            purpose:               "test",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      ms,
            milestoneDescriptions: descs,
            collateralAmount:      0,
            collateralAsset:       address(0),
            underwriter:           address(0),
            underwriterAmount:     0,
            directDisbursement:    true
        });
        vm.prank(borrower);
        loanId = registry.requestLoan(p);

        vm.prank(p2pLender);
        vault.fundLoan(loanId);
    }

    // -------------------------------------------------------------------------
    // Test 01: Non-defaulted repayment correctly tracks reserveSkimmed
    // -------------------------------------------------------------------------
    function test_01_NonDefaultedRepayment_ReserveSkimTracked() public {
        uint256 loanId = _requestAndFundPoolLoan(true); // direct disbursement

        // Full repayment via payRevenue
        // repaymentShare = TOTAL_DUE * REPAY_RATE_BPS / 10000 = 115e6 * 5000 / 10000 = 57.5e6
        // But we need to pay enough for totalRecovered >= TOTAL_DUE.
        // repaymentShare per call = amount * 50% = payment * 0.5
        // To reach 115e6 totalRecovered, need 230e6 total payment.
        vm.prank(client);
        router.payRevenue(loanId, 230e6); // repaymentShare = 115e6; fully repays

        uint256 expectedReservecut = (TOTAL_DUE * RESERVE_BPS) / 10000; // 2_300_000
        assertEq(router.reserveSkimmed(loanId), expectedReservecut,
            "reserveSkimmed must equal the reserve cut taken on the repayment");
        assertEq(router.poolRecovered(loanId),
            router.totalRecovered(loanId) - router.reserveSkimmed(loanId),
            "poolRecovered = totalRecovered - reserveSkimmed (no garnishment)");
        assertEq(router.totalRecovered(loanId), TOTAL_DUE,
            "totalRecovered tracks the full debt reduction");
        // reserve pool received the skim
        assertEq(usdc.balanceOf(address(reservePool)), expectedReservecut,
            "reserve pool balance equals the skim");
    }

    // -------------------------------------------------------------------------
    // Test 02: Zero reserveBps — no skim, no effect on poolRecovered
    // -------------------------------------------------------------------------
    function test_02_ZeroReserveBps_NoSkim() public {
        // Wire reserve pool at 0% skim (no loans exist yet, so guard passes)
        router.setReservePool(address(reservePool), 0);

        // Seed pool: owner init then depositor
        uint256 seed02 = 10e6;
        usdc.mint(owner, seed02);
        usdc.approve(address(pool), seed02);
        pool.initializeLiquidity(seed02);

        usdc.mint(depositor, POOL_DEPOSIT);
        vm.startPrank(depositor);
        usdc.approve(address(pool), POOL_DEPOSIT);
        pool.deposit(POOL_DEPOSIT);
        vm.stopPrank();

        // Create and fund a pool loan
        uint256[] memory ms02b = new uint256[](1); ms02b[0] = PRINCIPAL;
        string[] memory descs02b = new string[](1); descs02b[0] = "full";
        address[] memory recipients02b = new address[](1); recipients02b[0] = creditWallet;
        ILoanRegistry.BudgetCategory[] memory budget02b = new ILoanRegistry.BudgetCategory[](1);
        budget02b[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});
        ILoanRegistry.LoanProposal memory p02b = ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet, principal: PRINCIPAL,
            repaymentRateBps: REPAY_RATE_BPS, totalRepaymentDue: TOTAL_DUE,
            duration: 30 days, purpose: "test", budget: budget02b,
            permittedRecipients: recipients02b, milestoneAmounts: ms02b,
            milestoneDescriptions: descs02b, collateralAmount: 0,
            collateralAsset: address(0), underwriter: address(0),
            underwriterAmount: 0, directDisbursement: true
        });
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(p02b);
        vault.fundFromPool(loanId);

        // Full repayment (50% split means 230e6 payment -> 115e6 repaymentShare == TOTAL_DUE)
        vm.prank(client);
        router.payRevenue(loanId, 230e6);

        assertEq(router.reserveSkimmed(loanId), 0, "no skim when reserveBps=0");
        assertEq(router.poolRecovered(loanId), router.totalRecovered(loanId),
            "poolRecovered == totalRecovered when skim=0");
        assertEq(usdc.balanceOf(address(reservePool)), 0, "no reserve balance");
    }

    // -------------------------------------------------------------------------
    // Test 03: Defaulted loan — no skim on garnishment path
    // -------------------------------------------------------------------------
    function test_03_DefaultedLoan_NoSkimOnGarnishment() public {
        registry.setKeeper(address(this), true);
        uint256 loanId = _requestAndFundPoolLoan(true);

        // Partial repayment before default (not enough to fully repay)
        vm.prank(client);
        router.payRevenue(loanId, 10e6); // small payment

        uint256 skimAfterPartial = router.reserveSkimmed(loanId);
        assertGt(skimAfterPartial, 0, "skim recorded on pre-default payment");

        // Default the loan
        vm.warp(block.timestamp + 31 days + DEFAULT_GRACE + 1);
        registry.markDefault(loanId);

        // Post-default garnishment payment
        vm.prank(client);
        router.payRevenue(loanId, 200e6);

        // reserveSkimmed must NOT increase after default
        assertEq(router.reserveSkimmed(loanId), skimAfterPartial,
            "reserveSkimmed does not change after default");
        // reserveRepaid should increase (RISK-09 garnishment)
        assertGt(router.reserveRepaid(loanId), 0,
            "reserveRepaid increases after default garnishment");
        // poolRecovered = totalRecovered - reserveRepaid - reserveSkimmed
        assertEq(router.poolRecovered(loanId),
            router.totalRecovered(loanId)
                - router.reserveRepaid(loanId)
                - router.reserveSkimmed(loanId),
            "poolRecovered formula correct across both deduction paths");
    }

    // -------------------------------------------------------------------------
    // Test 04: Partial repayments — skim accumulates per payment
    // -------------------------------------------------------------------------
    function test_04_PartialRepayments_SkimAccumulatesPerPayment() public {
        uint256 loanId = _requestAndFundPoolLoan(true);

        // Three partial payments each at REPAY_RATE_BPS = 50%
        // payment 1: amount=40e6 -> repaymentShare=20e6 -> reserveCut = 20e6 * 200/10000 = 400_000
        // payment 2: same -> cumulative skim = 800_000
        // payment 3: same -> cumulative skim = 1_200_000
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            router.payRevenue(loanId, 40e6);
        }

        uint256 expectedSkimPerPayment = (20e6 * RESERVE_BPS) / 10000; // 400_000 per payment
        assertEq(router.reserveSkimmed(loanId), expectedSkimPerPayment * 3,
            "skim accumulates linearly across partial payments");
        assertEq(router.poolRecovered(loanId),
            router.totalRecovered(loanId) - router.reserveSkimmed(loanId),
            "poolRecovered invariant holds after partial payments");
        // Reserve pool received all three skims
        assertEq(usdc.balanceOf(address(reservePool)), expectedSkimPerPayment * 3,
            "reserve pool balance matches cumulative skim");
    }

    // -------------------------------------------------------------------------
    // Test 05: Pre-default skim then default then garnishment — both paths active
    // -------------------------------------------------------------------------
    function test_05_PreDefaultSkim_ThenDefault_BothPathsActive() public {
        registry.setKeeper(address(this), true);
        uint256 loanId = _requestAndFundPoolLoan(true);

        // Pre-default partial payment (skim path)
        vm.prank(client);
        router.payRevenue(loanId, 20e6);
        uint256 skimAfterPreDefault = router.reserveSkimmed(loanId);
        assertGt(skimAfterPreDefault, 0, "pre-default skim non-zero");

        // Default
        vm.warp(block.timestamp + 31 days + DEFAULT_GRACE + 1);
        registry.markDefault(loanId);

        // Verify reserve payout occurred (only for unsecured loans with shortfall)
        uint256 reservePayout = reservePool.loanPayout(loanId);

        // Post-default garnishment
        if (reservePayout > 0) {
            usdc.mint(client, reservePayout);
            vm.prank(client);
            router.payRevenue(loanId, reservePayout * 2); // ensure enough to trigger garnishment
        }

        // Invariant: skim must not change after default
        assertEq(router.reserveSkimmed(loanId), skimAfterPreDefault,
            "reserveSkimmed frozen after default");
        // poolRecovered uses both deductions independently
        assertEq(router.poolRecovered(loanId),
            router.totalRecovered(loanId)
                - router.reserveRepaid(loanId)
                - router.reserveSkimmed(loanId),
            "poolRecovered = totalRecovered - reserveRepaid - reserveSkimmed");
        // Sanity: no negative result
        assertGe(int256(router.totalRecovered(loanId)),
            int256(router.reserveRepaid(loanId) + router.reserveSkimmed(loanId)),
            "deductions cannot exceed totalRecovered");
    }

    // -------------------------------------------------------------------------
    // Test 06: setReserveSkimmed — owner sets historical skim
    // -------------------------------------------------------------------------
    function test_06_Migration_SetReserveSkimmed_HistoricalLoan() public {
        // Simulate a historical loan where reserveSkimmed was not tracked.
        // The loan was fully repaid; set the skim retroactively.
        uint256 loanId = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId, 230e6); // fully repaid

        // Simulate the V2 upgrade after repayment: migrationCutoff = nextLoanId() = 1.
        // loanId 0 is now eligible (0 < 1).
        _simulateUpgrade();

        // Pretend reserveSkimmed was 0 at time of repayment (pre-fix simulation).
        // After fix, verify the owner can set it.
        uint256 historicalSkim = 220_000; // the verified amount for testnet loan 0
        // loanId != 0 here; set the skim for it anyway to test the setter.
        // reserveSkimmed was auto-set by the fix, so reset to 0 first to simulate
        // a pre-fix historical state (direct storage manipulation in test only).
        vm.store(address(router),
            keccak256(abi.encode(loanId, uint256(9))), // slot 9 = reserveSkimmed
            bytes32(0)
        );
        assertEq(router.reserveSkimmed(loanId), 0, "manually zeroed for migration test");

        router.setReserveSkimmed(loanId, historicalSkim);
        assertEq(router.reserveSkimmed(loanId), historicalSkim,
            "setReserveSkimmed correctly stores the value");
        assertEq(router.poolRecovered(loanId),
            router.totalRecovered(loanId) - historicalSkim,
            "poolRecovered reflects the migrated skim");
    }

    // -------------------------------------------------------------------------
    // Test 07: setReserveSkimmed — cannot overwrite an existing value
    // -------------------------------------------------------------------------
    function test_07_Migration_SetReserveSkimmed_SkimAlreadySet_Reverts() public {
        uint256 loanId = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId, 230e6);
        _simulateUpgrade(); // migrationCutoff = 1; loanId 0 eligible

        // Zero out for the test, then set once
        vm.store(address(router),
            keccak256(abi.encode(loanId, uint256(9))),
            bytes32(0)
        );
        router.setReserveSkimmed(loanId, 100_000);
        // Second call must revert
        vm.expectRevert(RevenueRouter.SkimAlreadySet.selector);
        router.setReserveSkimmed(loanId, 200_000);
    }

    // -------------------------------------------------------------------------
    // Test 08: setReserveSkimmed — amount > totalRecovered reverts
    // -------------------------------------------------------------------------
    function test_08_Migration_SetReserveSkimmed_ExceedsTotalRecovered_Reverts() public {
        uint256 loanId = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId, 230e6); // totalRecovered = TOTAL_DUE
        _simulateUpgrade(); // migrationCutoff = 1; loanId 0 eligible

        vm.store(address(router),
            keccak256(abi.encode(loanId, uint256(9))),
            bytes32(0)
        );
        vm.expectRevert(RevenueRouter.ExceedsTotalRecovered.selector);
        router.setReserveSkimmed(loanId, TOTAL_DUE + 1);
    }

    // -------------------------------------------------------------------------
    // Test 09: setReserveSkimmed — non-owner reverts
    // -------------------------------------------------------------------------
    function test_09_Migration_SetReserveSkimmed_NonOwner_Reverts() public {
        uint256 loanId = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId, 230e6);
        _simulateUpgrade(); // migrationCutoff = 1

        vm.prank(address(0xBAD));
        vm.expectRevert();
        router.setReserveSkimmed(loanId, 100_000);
    }

    // -------------------------------------------------------------------------
    // Test 10: reconcileLoan after skim — idleLedger correct, no overcount
    // -------------------------------------------------------------------------
    function test_10_ReconcileLoan_AfterSkim_CorrectIdleLedger() public {
        uint256 loanId = _requestAndFundPoolLoan(true);
        uint256 idleBefore = pool.idleLedger();
        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        // Full repayment
        vm.prank(client);
        router.payRevenue(loanId, 230e6);

        // poolRecovered = TOTAL_DUE - reserveCut
        uint256 expectedPoolRecovered = TOTAL_DUE - RESERVE_CUT;
        assertEq(router.poolRecovered(loanId), expectedPoolRecovered,
            "poolRecovered excludes reserve cut");

        // reconcile
        pool.reconcileLoan(loanId);

        // idleLedger must have increased by exactly what arrived at the pool
        uint256 principalPortion = PRINCIPAL;                    // = 100e6
        uint256 profitPortion    = expectedPoolRecovered - principalPortion; // = 12.7e6
        uint256 expectedDelta    = principalPortion + profitPortion;          // = expectedPoolRecovered

        assertEq(pool.idleLedger() - idleBefore, expectedDelta,
            "idleLedger delta equals poolRecovered (not totalRecovered)");
        assertEq(pool.totalDeployed(), 0, "totalDeployed zeroed after reconcile");

        // Key invariant: totalAssets must equal actual USDC balance
        uint256 actualBalance = usdc.balanceOf(address(pool));
        uint256 internalAssets = pool.totalAssets();

        // Expected: poolBalanceBefore was POOL_DEPOSIT (200e6)
        // pool received lenderShare = TOTAL_DUE - RESERVE_CUT = 112.7e6
        // pool had POOL_DEPOSIT - PRINCIPAL (deployed) + lenderShare
        //       = 200e6 - 100e6 + 112.7e6 = 212.7e6
        // poolBalanceBefore is read AFTER fundFromPool, so principal is already
        // disbursed from the pool.  After payRevenue, lenderShare returns.
        assertEq(actualBalance, poolBalanceBefore + LENDER_SHARE,
            "pool USDC balance = pre-repayment balance + lenderShare");
        assertEq(internalAssets, actualBalance,
            "totalAssets must equal actual USDC balance after reconcile");
    }

    // -------------------------------------------------------------------------
    // Test 11: reconcileLoan with zero reserveBps — exact balance match
    // -------------------------------------------------------------------------
    function test_11_ReconcileLoan_ZeroReserveBps_ExactBalanceMatch() public {
        // Use 0% skim to confirm baseline case is still correct
        // Set 0% reserve skim; no loans exist yet so setReservePool is callable
        router.setReservePool(address(reservePool), 0);

        // Seed the pool (owner init, then depositor deposit)
        uint256 seedAmount02 = 10e6;
        usdc.mint(owner, seedAmount02);
        usdc.approve(address(pool), seedAmount02);
        pool.initializeLiquidity(seedAmount02);

        usdc.mint(depositor, POOL_DEPOSIT);
        vm.startPrank(depositor);
        usdc.approve(address(pool), POOL_DEPOSIT);
        pool.deposit(POOL_DEPOSIT);
        vm.stopPrank();

        uint256[] memory ms02 = new uint256[](1); ms02[0] = PRINCIPAL;
        string[] memory descs02 = new string[](1); descs02[0] = "full";
        address[] memory recipients02 = new address[](1); recipients02[0] = creditWallet;
        ILoanRegistry.BudgetCategory[] memory budget02 = new ILoanRegistry.BudgetCategory[](1);
        budget02[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});
        ILoanRegistry.LoanProposal memory p02 = ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet, principal: PRINCIPAL,
            repaymentRateBps: REPAY_RATE_BPS, totalRepaymentDue: TOTAL_DUE,
            duration: 30 days, purpose: "test", budget: budget02,
            permittedRecipients: recipients02, milestoneAmounts: ms02,
            milestoneDescriptions: descs02, collateralAmount: 0,
            collateralAsset: address(0), underwriter: address(0),
            underwriterAmount: 0, directDisbursement: true
        });
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(p02);
        vault.fundFromPool(loanId);

        vm.prank(client);
        router.payRevenue(loanId, 230e6); // fully repays at 50% split, no skim
        pool.reconcileLoan(loanId);

        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)),
            "totalAssets == actual balance with zero reserveBps");
        assertEq(router.reserveSkimmed(loanId), 0,
            "no skim recorded when reserveBps=0");
    }

    // -------------------------------------------------------------------------
    // Test 12: Full share withdrawal succeeds after proper reconcile
    // -------------------------------------------------------------------------
    function test_12_FullWithdrawal_Succeeds_AfterSkimAdjustedReconcile() public {
        uint256 loanId = _requestAndFundPoolLoan(true);

        vm.prank(client);
        router.payRevenue(loanId, 230e6);
        pool.reconcileLoan(loanId);

        // Depositor burns all shares
        uint256 shares = pool.sharesOf(depositor);
        assertGt(shares, 0, "depositor has shares");

        // withdraw takes sharesToBurn directly
        uint256 amountOut = (shares * pool.totalAssets()) / pool.totalShares();
        assertLe(amountOut, usdc.balanceOf(address(pool)),
            "withdrawal amount must not exceed actual pool balance");

        vm.prank(depositor);
        pool.withdraw(shares);

        assertEq(pool.sharesOf(depositor), 0, "all shares burned");
    }

    // -------------------------------------------------------------------------
    // Test 13: poolRecovered invariant holds across all paths
    // -------------------------------------------------------------------------
    function test_13_PoolRecovered_Invariant_AllStages() public {
        registry.setKeeper(address(this), true);
        uint256 loanId = _requestAndFundPoolLoan(true);

        // Stage 1: before any payment
        assertEq(router.poolRecovered(loanId), 0, "stage 1: zero");

        // Stage 2: partial pre-default payment
        vm.prank(client);
        router.payRevenue(loanId, 20e6);
        _assertPoolRecoveredInvariant(loanId, "stage 2: partial");

        // Stage 3: another partial payment
        vm.prank(client);
        router.payRevenue(loanId, 20e6);
        _assertPoolRecoveredInvariant(loanId, "stage 3: second partial");

        // Stage 4: default
        vm.warp(block.timestamp + 31 days + DEFAULT_GRACE + 1);
        registry.markDefault(loanId);
        _assertPoolRecoveredInvariant(loanId, "stage 4: post-default");

        // Stage 5: post-default payment (garnishment path)
        vm.prank(client);
        router.payRevenue(loanId, 50e6);
        _assertPoolRecoveredInvariant(loanId, "stage 5: garnishment");
    }

    function _assertPoolRecoveredInvariant(uint256 loanId, string memory label) internal {
        uint256 totalRec = router.totalRecovered(loanId);
        uint256 repaid   = router.reserveRepaid(loanId);
        uint256 skimmed  = router.reserveSkimmed(loanId);
        uint256 deducted = repaid + skimmed;
        uint256 expected = totalRec > deducted ? totalRec - deducted : 0;
        assertEq(router.poolRecovered(loanId), expected,
            string.concat("poolRecovered invariant: ", label));
    }

    // =========================================================================
    // Tests 14-20: migration-lock hardening
    // =========================================================================

    // -------------------------------------------------------------------------
    // Test 14: lockMigration — owner locks, subsequent setReserveSkimmed reverts
    // -------------------------------------------------------------------------
    function test_14_LockMigration_OwnerCanLock() public {
        uint256 loanId = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId, 230e6);
        _simulateUpgrade(); // migrationCutoff = 1

        // Zero the skim slot so migration would otherwise succeed
        vm.store(address(router),
            keccak256(abi.encode(loanId, uint256(9))),
            bytes32(0)
        );

        // Lock migration
        router.lockMigration();

        // setReserveSkimmed must now revert MigrationLocked
        vm.expectRevert(RevenueRouter.MigrationLocked.selector);
        router.setReserveSkimmed(loanId, 220_000);
    }

    // -------------------------------------------------------------------------
    // Test 15: lockMigration — non-owner cannot lock
    // -------------------------------------------------------------------------
    function test_15_LockMigration_NonOwnerReverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        router.lockMigration();
    }

    // -------------------------------------------------------------------------
    // Test 16: lockMigration — calling twice does not revert (idempotent lock)
    // -------------------------------------------------------------------------
    function test_16_LockMigration_CalledTwice_NoRevert() public {
        router.lockMigration();
        router.lockMigration(); // must not revert; already locked is the same state
    }

    // -------------------------------------------------------------------------
    // Test 17: setReserveSkimmed — reverts for future loan (>= migrationCutoff)
    // -------------------------------------------------------------------------
    function test_17_Migration_FutureLoan_NotEligible_Reverts() public {
        // Create loan 0 BEFORE the simulated upgrade (eligible historical loan)
        uint256 loanId0 = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId0, 230e6);

        // Simulate upgrade: migrationCutoff = 1 (nextLoanId after loan 0)
        _simulateUpgrade();

        // Create loan 1 AFTER the simulated upgrade (auto-accumulates skim)
        // Use a direct setup to avoid double-setReservePool call
        uint256[] memory ms = new uint256[](1); ms[0] = PRINCIPAL;
        string[] memory descs = new string[](1); descs[0] = "full";
        address[] memory recs = new address[](1); recs[0] = creditWallet;
        ILoanRegistry.BudgetCategory[] memory budg = new ILoanRegistry.BudgetCategory[](1);
        budg[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});
        ILoanRegistry.LoanProposal memory p = ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet, principal: PRINCIPAL,
            repaymentRateBps: REPAY_RATE_BPS, totalRepaymentDue: TOTAL_DUE,
            duration: 30 days, purpose: "future-loan", budget: budg,
            permittedRecipients: recs, milestoneAmounts: ms,
            milestoneDescriptions: descs, collateralAmount: 0,
            collateralAsset: address(0), underwriter: address(0),
            underwriterAmount: 0, directDisbursement: true
        });
        vm.prank(borrower);
        uint256 loanId1 = registry.requestLoan(p);
        vault.fundFromPool(loanId1);

        // Repay loan 1 — reserveSkimmed auto-accumulates
        usdc.mint(client, 300e6);
        vm.prank(client);
        usdc.approve(address(router), 300e6);
        vm.prank(client);
        router.payRevenue(loanId1, 230e6);

        // Zero the skim for loanId1 to simulate attempt at manual override
        vm.store(address(router),
            keccak256(abi.encode(loanId1, uint256(9))),
            bytes32(0)
        );

        // Must revert: loanId1 >= migrationCutoff (1 >= 1)
        vm.expectRevert(RevenueRouter.LoanNotEligibleForMigration.selector);
        router.setReserveSkimmed(loanId1, 100_000);
    }

    // -------------------------------------------------------------------------
    // Test 18: setReserveSkimmed — reverts when migrationCutoff == 0 (not upgraded)
    // -------------------------------------------------------------------------
    function test_18_Migration_CutoffZero_NotEligible_Reverts() public {
        // Do NOT call _simulateUpgrade(); migrationCutoff stays 0
        uint256 loanId = _requestAndFundPoolLoan(true);
        vm.prank(client);
        router.payRevenue(loanId, 230e6);

        vm.store(address(router),
            keccak256(abi.encode(loanId, uint256(9))),
            bytes32(0)
        );

        // migrationCutoff == 0 means reinitializer never ran; must revert
        vm.expectRevert(RevenueRouter.LoanNotEligibleForMigration.selector);
        router.setReserveSkimmed(loanId, 220_000);
    }

    // -------------------------------------------------------------------------
    // Test 19: setReserveSkimmed — reverts for loan with no repayment
    // -------------------------------------------------------------------------
    function test_19_Migration_LoanHasNoRepayment_Reverts() public {
        // Request a loan but do NOT repay it — totalRecovered == 0
        uint256 loanId = _requestAndFundPoolLoan(true);
        _simulateUpgrade(); // migrationCutoff = 1

        // loanId 0 is eligible by ID, but totalRecovered == 0
        // Guard: LoanHasNoRepayment fires before LoanNotEligibleForMigration
        vm.expectRevert(RevenueRouter.LoanHasNoRepayment.selector);
        router.setReserveSkimmed(loanId, 1);
    }

    // -------------------------------------------------------------------------
    // Test 20: migrationCutoff stored correctly after initializeV2
    // -------------------------------------------------------------------------
    function test_20_InitializeV2_SetsMigrationCutoff() public {
        // Before upgrade
        assertEq(router.migrationCutoff(), 0, "cutoff is 0 before initializeV2");

        // Create loan 0
        _requestAndFundPoolLoan(true);
        // nextLoanId is now 1

        // Simulate upgrade
        _simulateUpgrade();
        assertEq(router.migrationCutoff(), 1,
            "migrationCutoff == nextLoanId at upgrade time");

        // initializeV2 cannot be called again (reinitializer(2) guard)
        vm.expectRevert();
        router.initializeV2();
    }

}

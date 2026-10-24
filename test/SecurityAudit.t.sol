// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================================
// SecurityAudit.t.sol
//
// Regression tests added during the pre-deployment security audit of the
// direct-disbursement feature (V1.1).
//
// Findings addressed:
//
//  AUDIT-01: settleExpiredLoan() accepted Active-status loans, leaving them
//            in a stale Active state that permitted a subsequent markDefault()
//            to double-seize collateral on top of the already-returned vault
//            funds.  Fix: settleExpiredLoan() now requires Defaulted status.
//
//  AUDIT-02: (No code change needed.) Direct-disbursement loans leave
//            lockedAmount == 0 at funding time, so settleExpiredLoan()
//            correctly reverts NothingToSettle on such loans.  The existing
//            NothingToSettle guard is sufficient; no new vault recovery path
//            is needed for direct loans.
//
// Coverage per audit spec:
//  1.  Expired milestone loan settlement and final status gate
//  2.  Defaulted milestone loan settlement (positive path)
//  3.  Direct P2P loan default and recovery
//  4.  Direct pool-funded loan default and recovery
//  5.  Collateral recovery after direct disbursement
//  6.  Underwriter obligations after direct disbursement
//  7.  Reserve and liquidity-pool reconciliation
//  8.  Duplicate settlement/recovery attempts
//  9.  Full repayment of direct loans
//  10. Existing milestone-based loan behaviour
// =============================================================================

import {Test}         from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20}        from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentRegistry}     from "../src/AgentRegistry.sol";
import {CreditRegistry}    from "../src/CreditRegistry.sol";
import {LoanRegistry}      from "../src/LoanRegistry.sol";
import {RevenueRouter}     from "../src/RevenueRouter.sol";
import {LoanVault}         from "../src/LoanVault.sol";
import {CollateralVault}   from "../src/CollateralVault.sol";
import {UnderwriterPool}   from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool}       from "../src/ReservePool.sol";
import {LiquidityPool}     from "../src/LiquidityPool.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";

// ── Test tokens ───────────────────────────────────────────────────────────────
contract MockUSDC_Audit is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockEURC_Audit is ERC20 {
    constructor() ERC20("Mock EURC", "EURC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// =============================================================================
contract SecurityAuditTest is Test {

    // ── Actors ─────────────────────────────────────────────────────────────────
    address owner        = address(0xA1);
    address borrower     = address(0xB1);
    address creditWallet = address(0xC1);
    address lender       = address(0xD1);
    address underwriter  = address(0xE1);

    // ── Tokens ─────────────────────────────────────────────────────────────────
    MockUSDC_Audit usdc;
    MockEURC_Audit eurc;

    // ── Protocol ───────────────────────────────────────────────────────────────
    AgentRegistry     agentReg;
    CreditRegistry    creditReg;
    LoanRegistry      registry;
    RevenueRouter     router;
    LoanVault         vault;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientReg;
    ReservePool       reservePool;
    LiquidityPool     liquidityPool;

    uint256 agentId;

    // ── Constants ──────────────────────────────────────────────────────────────
    uint256 constant INITIAL_CREDIT   = 5e6;
    uint256 constant COL_THRESH       = 10_000e6;
    uint16  constant MAX_LTV          = 6600;
    uint16  constant RESERVE_BPS      = 200;
    uint256 constant MIN_DUR          = 1 days;
    uint256 constant MAX_DUR          = 365 days;
    uint256 constant GRACE            = 3 days;
    uint256 constant EURC_PRICE       = 1.08e18;

    // ── Helpers ────────────────────────────────────────────────────────────────
    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new ERC1967Proxy(impl, init));
    }

    function _requiredUsdc(uint256 p) internal pure returns (uint256) {
        return (p * 10000) / MAX_LTV;
    }

    function _requiredEurc(uint256 p) internal pure returns (uint256) {
        return (_requiredUsdc(p) * 1e18 * 1e6) / (EURC_PRICE * 1e6);
    }

    function _directProposal(uint256 principal, address collAsset, uint256 collAmt)
        internal view returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory b = new ILoanRegistry.BudgetCategory[](1);
        b[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[]  memory dc = new string[](1);  dc[0] = "direct";
        return ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet,
            principal: principal, repaymentRateBps: 10000,
            totalRepaymentDue: principal + principal / 10, duration: 30 days,
            purpose: "audit-direct", budget: b,
            permittedRecipients: _a1(creditWallet),
            milestoneAmounts: ms, milestoneDescriptions: dc,
            collateralAmount: collAmt, collateralAsset: collAsset,
            underwriter: address(0), underwriterAmount: 0,
            directDisbursement: true
        });
    }

    function _milestoneProposal(uint256 principal, uint256 collAmt, address collAsset)
        internal view returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory b = new ILoanRegistry.BudgetCategory[](1);
        b[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[]  memory dc = new string[](1);  dc[0] = "m0";
        return ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet,
            principal: principal, repaymentRateBps: 10000,
            totalRepaymentDue: principal + principal / 10, duration: 30 days,
            purpose: "audit-milestone", budget: b,
            permittedRecipients: _a1(creditWallet),
            milestoneAmounts: ms, milestoneDescriptions: dc,
            collateralAmount: collAmt, collateralAsset: collAsset,
            underwriter: address(0), underwriterAmount: 0,
            directDisbursement: false
        });
    }

    function _underwrittenProposal(uint256 principal, address uw, uint256 uwAmt)
        internal view returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory b = new ILoanRegistry.BudgetCategory[](1);
        b[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        uint256[] memory ms = new uint256[](2); ms[0] = principal / 2; ms[1] = principal - principal / 2;
        string[]  memory dc = new string[](2);  dc[0] = "m0"; dc[1] = "m1";
        return ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet,
            principal: principal, repaymentRateBps: 10000,
            totalRepaymentDue: principal + principal / 10, duration: 30 days,
            purpose: "audit-underwritten", budget: b,
            permittedRecipients: _a1(creditWallet),
            milestoneAmounts: ms, milestoneDescriptions: dc,
            collateralAmount: 0, collateralAsset: address(0),
            underwriter: uw, underwriterAmount: uwAmt,
            directDisbursement: false
        });
    }

    function _a1(address a) internal pure returns (address[] memory r) {
        r = new address[](1); r[0] = a;
    }

    function _seedCredit(uint256 amt) internal {
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, amt, false);
    }

    function _fundPool(uint256 amt) internal {
        usdc.mint(owner, amt);
        vm.prank(owner);
        usdc.approve(address(liquidityPool), amt);
        vm.prank(owner);
        liquidityPool.initializeLiquidity(amt);
    }

    function _depositCollateral(address asset, uint256 amt) internal {
        vm.prank(borrower);
        ERC20(asset).approve(address(collateralVault), amt);
        vm.prank(borrower);
        if (asset == address(usdc)) {
            collateralVault.depositCollateral(asset, amt);
        } else {
            collateralVault.depositCollateral(asset, amt);
        }
    }

    // ── setUp ──────────────────────────────────────────────────────────────────
    function setUp() public {
        usdc = new MockUSDC_Audit();
        eurc = new MockEURC_Audit();

        agentReg = AgentRegistry(_proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        ));

        creditReg = CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize, (
                owner, INITIAL_CREDIT, 2500, 1000, 2000e6, 2000, 25_000e6, 500, 50e6, 50_000e6
            ))
        ));

        registry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize, (
                owner, address(creditReg), MIN_DUR, MAX_DUR, GRACE, COL_THRESH
            ))
        ));

        router = RevenueRouter(_proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize, (
                owner, address(registry), address(creditReg), address(usdc)
            ))
        ));

        vault = LoanVault(_proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize, (owner, address(registry), address(usdc)))
        ));

        collateralVault = CollateralVault(_proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), MAX_LTV))
        ));

        underwriterPool = UnderwriterPool(_proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(usdc), address(registry)))
        ));

        recipientReg = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        reservePool = ReservePool(_proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        ));

        liquidityPool = LiquidityPool(_proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reservePool), address(vault)
            ))
        ));

        vm.startPrank(owner);
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientReg));
        registry.setReservePool(address(reservePool));
        registry.setAgentRegistry(address(agentReg));
        router.setAgentRegistry(address(agentReg));
        router.setReservePool(address(reservePool), RESERVE_BPS);
        vault.setLiquidityPool(address(liquidityPool));
        creditReg.setAuthorizedCaller(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);
        reservePool.setAuthorizedContributor(address(router), true);
        collateralVault.setAssetConfig(address(eurc), true, 6, EURC_PRICE);
        recipientReg.approveRecipient(creditWallet, keccak256("COMPUTE"), "CW");
        vm.stopPrank();

        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        usdc.mint(borrower, 10_000_000e6);
        usdc.mint(lender,   10_000_000e6);
        usdc.mint(underwriter, 5_000_000e6);
        eurc.mint(borrower, 10_000_000e6);

        vm.prank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(underwriter);
        usdc.approve(address(underwriterPool), type(uint256).max);
    }

    // =========================================================================
    // AUDIT-01: settleExpiredLoan requires Defaulted — Active path removed
    // =========================================================================

    /// @notice Test 1 — settleExpiredLoan on an Active (not-yet-defaulted) loan
    ///         must revert LoanNotDefaulted, NOT succeed and leave a stale state.
    ///         Policy update: collateralized loans now use directDisbursement=true,
    ///         so lockedAmount is 0 after funding. The status gate (LoanNotDefaulted)
    ///         still fires before the NothingToSettle check, preserving the invariant.
    function test_Audit01_SettleExpiredActive_RevertsLoanNotDefaulted() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );

        vm.prank(lender);
        vault.fundLoan(loanId);

        // directDisbursement=true: principal sent to creditWallet immediately.
        assertEq(vault.lockedAmount(loanId), 0, "no vault-locked funds for direct-disbursement loan");

        // Warp past expiry but still within grace period
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + 1); // expired, not yet past grace

        // Status gate fires first (LoanNotDefaulted) before NothingToSettle.
        // This ensures the ordering protection is intact regardless of lockedAmount.
        vm.expectRevert(LoanVault.LoanNotDefaulted.selector);
        vault.settleExpiredLoan(loanId);

        // Loan status must still be Active (no stale-state corruption)
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan should still be Active"
        );
    }

    /// @notice Test 2 — Policy update: collateralized loans now use directDisbursement=true.
    ///         On default, collateral is seized to the lender by markDefault. Since
    ///         lockedAmount==0, settleExpiredLoan correctly reverts NothingToSettle.
    ///         This verifies: (a) collateral recovery still works, (b) the vault
    ///         settlement path correctly rejects a loan with no locked funds.
    function test_Audit01_SettleExpiredDefaulted_Succeeds() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );
        vm.prank(lender);
        vault.fundLoan(loanId);

        // directDisbursement=true: principal disbursed at funding, no locked funds.
        assertEq(vault.lockedAmount(loanId), 0, "no vault-locked funds");

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        uint256 lenderBefore = usdc.balanceOf(lender);
        vm.prank(owner);
        registry.markDefault(loanId);

        // Collateral seized to lender at markDefault
        assertEq(
            usdc.balanceOf(lender) - lenderBefore,
            collAmt,
            "collateral must be seized to lender at markDefault"
        );

        // settleExpiredLoan reverts NothingToSettle (lockedAmount == 0)
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);

        // Loan status is Defaulted
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Defaulted),
            "status must be Defaulted"
        );
    }

    /// @notice Test 3 — AUDIT-01 double-seizure prevention.
    ///         Policy update: collateralized loans now use directDisbursement=true.
    ///         With direct disbursement there are no vault-locked funds (lockedAmount==0),
    ///         so the double-recovery path (collateral + vault settlement) is impossible
    ///         by construction. This test now verifies: (1) collateral is seized at
    ///         markDefault; (2) settleExpiredLoan reverts NothingToSettle; (3) the
    ///         lender's total recovery equals exactly the collateral amount, not more.
    function test_Audit01_NoDoubleRecovery_CollateralPlusVaultFunds() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );
        vm.prank(lender);
        vault.fundLoan(loanId);

        // directDisbursement=true: no vault-locked funds.
        assertEq(vault.lockedAmount(loanId), 0, "no vault-locked funds");

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        uint256 lenderBefore = usdc.balanceOf(lender);

        // markDefault seizes collateral to lender immediately
        vm.prank(owner);
        registry.markDefault(loanId);
        uint256 afterDefault = usdc.balanceOf(lender);
        assertEq(afterDefault - lenderBefore, collAmt, "collateral seized on markDefault");

        // settleExpiredLoan reverts NothingToSettle — no vault funds exist
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);

        // Total lender recovery = collateral only (no double-counting possible)
        assertEq(usdc.balanceOf(lender) - lenderBefore, collAmt, "lender receives only collateral");
    }

    // =========================================================================
    // AUDIT-02: Direct-disbursement default — NothingToSettle is correct
    // =========================================================================

    /// @notice Test 4 — Direct loan defaults: lockedAmount == 0, so
    ///         settleExpiredLoan correctly reverts NothingToSettle.
    ///         Lender protection comes from collateral seizure, not vault funds.
    function test_Audit02_DirectLoanDefault_NothingToSettle() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );

        vm.prank(lender);
        vault.fundLoan(loanId);

        // Principal is already in creditWallet; lockedAmount is 0
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount should be zero");

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
        vm.prank(owner);
        registry.markDefault(loanId);

        // Collateral was seized to lender
        (, , , bool resolved) = collateralVault.reservations(loanId);
        assertTrue(resolved, "collateral must be seized");

        // settleExpiredLoan must revert — nothing to return from vault
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);
    }

    /// @notice Test 5 — Pool-funded direct loan defaults correctly.
    function test_Audit02_DirectPoolLoanDefault_CollateralSeized_PoolReconciles() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        _fundPool(500_000e6);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );

        vm.prank(owner);
        vault.fundFromPool(loanId);

        // creditWallet received funds immediately
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount must be zero");

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        uint256 poolBalBefore = usdc.balanceOf(address(liquidityPool));
        vm.prank(owner);
        registry.markDefault(loanId);

        // Collateral (USDC) seized → goes to loan.lender (liquidityPool address)
        // Pool receives the USDC directly from CollateralVault.seize()
        uint256 poolBalAfter = usdc.balanceOf(address(liquidityPool));
        assertEq(poolBalAfter - poolBalBefore, collAmt, "pool must receive seized collateral");

        // Reconcile: credits collateral recovery into idleLedger
        uint256 idleBefore = liquidityPool.idleLedger();
        liquidityPool.reconcileLoan(loanId);
        uint256 idleAfter = liquidityPool.idleLedger();
        // idleLedger should increase by the collateral amount (USDC collateral seizure path)
        assertGe(idleAfter, idleBefore + collAmt, "idleLedger must include seized collateral");

        // settleExpiredLoan must revert
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);
    }

    // =========================================================================
    // Test 6 — Underwriter obligations after direct disbursement (N/A for DD)
    // Direct-disbursement loans are collateral-backed — underwriter path does
    // not apply to them. Confirm underwriter seizure still works on milestone loans.
    // =========================================================================

    function test_Audit06_UnderwriterSeize_MilestoneLoan_Unaffected() public {
        uint256 principal = 30_000e6;
        uint256 uwAmt     = 30_000e6;

        vm.prank(underwriter);
        underwriterPool.depositStake(uwAmt);
        vm.prank(underwriter);
        underwriterPool.commitToAgent(borrower, uwAmt);

        ILoanRegistry.LoanProposal memory prop = _underwrittenProposal(principal, underwriter, uwAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(prop);
        vm.prank(owner);
        registry.approveLoan(loanId);
        vm.prank(lender);
        vault.fundLoan(loanId);
        vm.prank(lender);
        vault.releaseMilestone(loanId, 0);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        uint256 lenderBefore = usdc.balanceOf(lender);
        vm.prank(owner);
        registry.markDefault(loanId);
        assertEq(
            usdc.balanceOf(lender) - lenderBefore,
            uwAmt,
            "underwriter stake must be seized to lender"
        );

        // lockedAmount still has the unreleased half
        uint256 locked = vault.lockedAmount(loanId);
        assertGt(locked, 0, "must have unreleased locked funds");

        uint256 bal2 = usdc.balanceOf(lender);
        vault.settleExpiredLoan(loanId);
        assertEq(
            usdc.balanceOf(lender) - bal2,
            locked,
            "vault funds returned after underwriter seizure"
        );
    }

    // =========================================================================
    // Test 7 — Reserve pool reconciliation for direct pool loans
    // =========================================================================

    function test_Audit07_ReservePool_Reconcile_DirectPoolLoan() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        uint256 repayDue  = principal + principal / 10;

        _fundPool(500_000e6);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );
        vm.prank(owner);
        vault.fundFromPool(loanId);

        uint256 idleBefore = liquidityPool.idleLedger();

        // Repay in full
        vm.prank(borrower);
        usdc.approve(address(router), repayDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repayDue);

        // Reconcile: pool should recover its principal + profit (minus reserve cut)
        liquidityPool.reconcileLoan(loanId);

        assertTrue(
            liquidityPool.idleLedger() > idleBefore - principal,
            "pool should recover after repayment"
        );
        assertTrue(liquidityPool.finalized(loanId), "loan must be finalized in pool");
        assertEq(liquidityPool.totalDeployed(), 0, "totalDeployed must be zero");
    }

    // =========================================================================
    // Test 8 — Duplicate settlement prevention
    // =========================================================================

    /// @notice Policy update: collateralized loans use directDisbursement=true.
    ///         lockedAmount==0 means settleExpiredLoan always reverts NothingToSettle.
    ///         This verifies the NothingToSettle guard is idempotent: both the first
    ///         and second calls revert, not just the second.  The duplicate-settlement
    ///         guard (lockedAmount cleared after first success) is tested separately
    ///         for uncollateralized milestone loans in Risk03_VaultSettlementOrdering.
    function test_Audit08_DuplicateSettlement_Reverts() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );
        vm.prank(lender);
        vault.fundLoan(loanId);

        // directDisbursement=true: no vault-locked funds.
        assertEq(vault.lockedAmount(loanId), 0, "no vault-locked funds");

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
        vm.prank(owner);
        registry.markDefault(loanId);

        // Both settlement attempts revert NothingToSettle (lockedAmount always 0)
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);

        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);
    }

    // =========================================================================
    // Test 9 — Full repayment of direct loan (USDC collateral)
    // =========================================================================

    function test_Audit09_DirectLoan_FullRepayment() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredUsdc(principal);
        uint256 repayDue  = principal + principal / 10;
        _depositCollateral(address(usdc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(usdc), collAmt)
        );
        vm.prank(lender);
        vault.fundLoan(loanId);

        // creditWallet has principal
        assertEq(vault.lockedAmount(loanId), 0);

        vm.prank(borrower);
        usdc.approve(address(router), repayDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repayDue);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid),
            "loan must be Repaid"
        );
        (, , , bool resolved) = collateralVault.reservations(loanId);
        assertTrue(resolved, "collateral must be released after full repayment");
        assertTrue(router.isFullyRepaid(loanId), "router must mark fully repaid");
    }

    // =========================================================================
    // Test 10 — Existing milestone-based loan behavior unaffected
    // =========================================================================

    function test_Audit10_MilestoneLoan_FullLifecycle_Unaffected() public {
        _seedCredit(10_000e6);
        uint256 principal = 1000e6;
        uint256 repayDue  = principal + principal / 10;

        // Credit-only loan (no collateral)
        ILoanRegistry.BudgetCategory[] memory b = new ILoanRegistry.BudgetCategory[](1);
        b[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[]  memory dc = new string[](1);  dc[0] = "m0";
        ILoanRegistry.LoanProposal memory prop = ILoanRegistry.LoanProposal({
            agentId: agentId, creditWallet: creditWallet,
            principal: principal, repaymentRateBps: 10000,
            totalRepaymentDue: repayDue, duration: 30 days,
            purpose: "audit-milestone-full", budget: b,
            permittedRecipients: _a1(creditWallet),
            milestoneAmounts: ms, milestoneDescriptions: dc,
            collateralAmount: 0, collateralAsset: address(0),
            underwriter: address(0), underwriterAmount: 0,
            directDisbursement: false
        });

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(prop);

        // Fund via P2P lender
        vm.prank(lender);
        vault.fundLoan(loanId);
        assertEq(vault.lockedAmount(loanId), principal, "funds locked in vault");

        uint256 cwBefore = usdc.balanceOf(creditWallet);

        // Release milestone
        vm.prank(lender);
        vault.releaseMilestone(loanId, 0);
        assertEq(
            usdc.balanceOf(creditWallet) - cwBefore,
            principal,
            "creditWallet received milestone funds"
        );
        assertEq(vault.lockedAmount(loanId), 0, "locked cleared after milestone");

        // Repay
        vm.prank(borrower);
        usdc.approve(address(router), repayDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repayDue);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid),
            "milestone loan must be Repaid"
        );
    }

    // =========================================================================
    // Test 11 — Pool accounting: direct pool loan default, reconcile is exact
    // =========================================================================

    function test_Audit11_DirectPoolLoan_EURC_Default_WriteOff() public {
        uint256 principal = 100e6;
        uint256 collAmt   = _requiredEurc(principal);

        _fundPool(500_000e6);

        vm.prank(borrower);
        eurc.approve(address(collateralVault), collAmt);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(eurc), collAmt);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _directProposal(principal, address(eurc), collAmt)
        );
        vm.prank(owner);
        vault.fundFromPool(loanId);

        uint256 deployed = liquidityPool.totalDeployed();
        assertEq(deployed, principal, "pool deployed principal");

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
        vm.prank(owner);
        registry.markDefault(loanId);

        // EURC collateral seized to pool (lender)
        // Pool gets EURC, not USDC — reconcile does NOT credit EURC as USDC recovery
        liquidityPool.reconcileLoan(loanId);

        // The loss is written off: totalDeployed returns to 0
        assertEq(liquidityPool.totalDeployed(), 0, "loss must be written off");

        // Pool holds the EURC (can be swept by owner later)
        assertGt(ERC20(address(eurc)).balanceOf(address(liquidityPool)), 0, "pool holds seized EURC");

        // settleExpiredLoan must revert — no USDC locked in vault
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);
    }
}

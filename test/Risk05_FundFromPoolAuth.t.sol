// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-05 regression tests — fundFromPool() access control and
//                             lending-policy enforcement
//
// Original defect: LoanVault.fundFromPool() was permissionless.
//
// Phase 1 fix (pooled-lending transition):
//   - onlyOwner removed from fundFromPool(). Any caller may trigger
//     pool funding, including the Valen keeper or the agent itself.
//   - All on-chain eligibility checks (status, approval threshold,
//     liquidity, duplicate-funding, reentrancy) are preserved.
//   - fundLoan() (direct P2P path) remains permissionless and is
//     unaffected by the pool-funding path.
//
// Phase 2 fix (approved lending policy):
//   - Pool-funded milestone loans are now permitted.  The earlier
//     PoolLoanMustUseDirectDisbursement guard is removed.  Milestone
//     pool loans are secured by the callerIsPoolOwner check in
//     releaseMilestone(): only the pool owner can release milestones
//     on behalf of the pool, so a hostile caller cannot fund and
//     then refuse to release.
//   - Collateralized loans MUST use directDisbursement=true
//     (LoanRegistry.CollateralizedLoanMustUseDirectDisbursement).
//     This is enforced at requestLoan time, before any funds move.
//   - Unsecured loans (collateralAmount=0, underwriterAmount=0) may
//     use either disbursement mode at the agent's discretion.
//
// Uses ERC1967Proxy deployment to avoid MemoryOOG from 9-proxy setUp.
// -----------------------------------------------------------------

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy}      from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry}      from "../src/LoanRegistry.sol";
import {LoanVault}         from "../src/LoanVault.sol";
import {CreditRegistry}    from "../src/CreditRegistry.sol";
import {RevenueRouter}     from "../src/RevenueRouter.sol";
import {CollateralVault}   from "../src/CollateralVault.sol";
import {UnderwriterPool}   from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool}       from "../src/ReservePool.sol";
import {LiquidityPool}     from "../src/LiquidityPool.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";
import {AgentRegistry}     from "../src/AgentRegistry.sol";
import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_R05 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk05_FundFromPoolAuthTest is Test {

    AgentRegistry     agentReg;
    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDC_R05      usdc;

    address owner        = address(this);   // proxy owner == test contract
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address stranger     = address(0x57121);
    address directLender = address(0x1E4DE4);

    uint256 agentId;

    uint256 constant GRACE   = 3 days;
    uint256 constant CAT     = 10_000e6;
    uint16  constant MAX_LTV = 6600;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        usdc = new MockUSDC_R05();

        agentReg = AgentRegistry(_proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        ));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        creditReg = CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2_000_000e6, 2000, 25_000e6, 500, 50e6, 50_000e6))
        ));

        registry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, GRACE, CAT))
        ));

        router = RevenueRouter(_proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditReg), address(usdc)))
        ));

        vault = LoanVault(_proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize,
                (owner, address(registry), address(usdc)))
        ));

        collateralVault = CollateralVault(_proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize,
                (owner, address(usdc), address(registry), MAX_LTV))
        ));

        underwriterPool = UnderwriterPool(_proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize,
                (owner, address(usdc), address(registry)))
        ));

        recipientRegistry = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        reservePool = ReservePool(_proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize,
                (owner, address(usdc), address(registry)))
        ));

        pool = LiquidityPool(_proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reservePool), address(vault)
            ))
        ));

        // Wire everything
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setReservePool(address(reservePool));
        registry.setAgentRegistry(address(agentReg));
        vault.setLiquidityPool(address(pool));
        creditReg.setAuthorizedCaller(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);
        reservePool.setAuthorizedContributor(address(router), true);
        router.setReservePool(address(reservePool), 0);
        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Provider");
        // RISK-15: creditWallet must also be registry-approved
        recipientRegistry.approveRecipient(creditWallet, keccak256("COMPUTE"), "CreditWallet");

        // Seed borrower credit (agentId bridge populates credits[agentId])
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, 5_000e6, false);

        usdc.mint(directLender, 10_000_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(stranger, 10_000_000e6);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    /// Seeds the pool with `amount` USDC from owner.
    function _seedPool(uint256 amount) internal {
        usdc.mint(owner, amount);
        usdc.approve(address(pool), amount);
        pool.initializeLiquidity(amount);
    }

    /// Creates a minimal Requested (self-approved) loan and returns its id.
    function _requestLoan(uint256 principal) internal returns (uint256 loanId) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet; // RISK-15
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Full";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "RISK-05 test",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: 0,
            collateralAsset:       address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: false
        }));
        // Status should be Requested (within credit limit)
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must be Requested"
        );
    }

    /// Creates a PendingApproval loan (principal > CAT with collateral).
    function _requestPendingApprovalLoan() internal returns (uint256 loanId) {
        uint256 principal = CAT + 1e6; // over threshold → PendingApproval
        uint256 required  = collateralVault.requiredCollateral(principal);

        usdc.mint(borrower, required);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet; // RISK-15
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Full";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "pending approval",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: required,
            collateralAsset:       address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: false
        }));
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.PendingApproval),
            "loan must be PendingApproval"
        );
    }

    /// Creates a PendingApproval loan with directDisbursement = true.
    /// Principal must exceed CAT (10_000e6).  Caller must pre-seed the pool
    /// with sufficient liquidity before calling fundFromPool on the result.
    function _requestPendingApprovalDirectLoan() internal returns (uint256 loanId) {
        uint256 principal = CAT + 1e6; // above approval threshold
        uint256 required  = collateralVault.requiredCollateral(principal);

        usdc.mint(borrower, required);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Direct Full";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "pending approval direct",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: required,
            collateralAsset:       address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: true
        }));
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.PendingApproval),
            "loan must be PendingApproval"
        );
    }

    /// Creates a Requested loan with directDisbursement = true.
    function _requestDirectLoan(uint256 principal) internal returns (uint256 loanId) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Direct";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "RISK-05 direct disbursement test",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: 0,
            collateralAsset:       address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: true
        }));
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "direct loan must be Requested"
        );
    }

    // ================================================================
    // TEST 01: An unsecured milestone loan (directDisbursement=false)
    //          CAN be pool-funded by the owner (Phase 2 policy).
    //          lockedAmount is set; pool accounting is updated.
    // ================================================================
    function test_01_UnsecuredMilestoneLoanCanBePoolFunded() public {
        _seedPool(1_000e6);
        uint256 loanId    = _requestLoan(100e6); // directDisbursement=false, no collateral
        uint256 principal = registry.getLoan(loanId).principal;

        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        // Owner (authorized) pool-funds the milestone loan
        vault.fundFromPool(loanId);

        // Loan must be Active
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after fundFromPool"
        );
        // lockedAmount == principal (milestone mode)
        assertEq(vault.lockedAmount(loanId), principal, "lockedAmount must equal principal");
        // Pool accounting updated
        assertEq(pool.idleLedger(),    idleBefore - principal,     "idleLedger must decrease");
        assertEq(pool.totalDeployed(), deployedBefore + principal, "totalDeployed must increase");
        assertEq(pool.principalAdvanced(loanId), principal,        "principalAdvanced must be set");
        // Funds are in the vault, not yet at creditWallet
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore + principal, "vault holds locked funds");
        // Lender set to pool
        assertEq(registry.getLoan(loanId).lender, address(pool), "lender must be the pool");
    }

    // ================================================================
    // TEST 02: Any caller (owner) can pool-fund a direct-disbursement loan.
    //          Funds go straight to creditWallet; lockedAmount stays 0.
    // ================================================================
    function test_02_OwnerCanPoolFundDirectDisbursementLoan() public {
        _seedPool(1_000e6);
        uint256 loanId    = _requestDirectLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        uint256 idleBefore       = pool.idleLedger();
        uint256 deployedBefore   = pool.totalDeployed();
        uint256 walletBalBefore  = usdc.balanceOf(creditWallet);

        // Called from owner — must succeed
        vault.fundFromPool(loanId);

        // Loan must be Active
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after fundFromPool"
        );
        // Pool accounting updated
        assertEq(pool.idleLedger(),    idleBefore - principal,     "idleLedger must decrease");
        assertEq(pool.totalDeployed(), deployedBefore + principal, "totalDeployed must increase");
        // Direct disbursement: lockedAmount stays 0, funds at creditWallet
        assertEq(vault.lockedAmount(loanId), 0,                        "lockedAmount must be 0 (direct)");
        assertEq(usdc.balanceOf(creditWallet), walletBalBefore + principal, "creditWallet must receive principal");
        // Lender set to pool
        assertEq(registry.getLoan(loanId).lender, address(pool), "lender must be the pool");
    }

    // ================================================================
    // TEST 03: fundLoan remains permissionless (non-owner with USDC can fund)
    // ================================================================
    function test_03_FundLoanRemainsPermissionless() public {
        uint256 loanId    = _requestLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        // directLender is NOT the owner
        assertFalse(directLender == vault.owner(), "directLender must not be owner");

        vm.prank(directLender);
        vault.fundLoan(loanId);  // must succeed without reverting

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after direct-lender fundLoan"
        );
        assertEq(vault.lockedAmount(loanId), principal, "lockedAmount must equal principal");
        assertEq(registry.getLoan(loanId).lender, directLender, "lender must be directLender");
    }

    // ================================================================
    // TEST 04: fundFromPool rejects a PendingApproval loan (status gate preserved)
    // ================================================================
    function test_04_FundFromPoolRevertsForPendingApprovalLoan() public {
        _seedPool(1_000_000e6);
        // Collateralized loans must use directDisbursement=true (policy).
        // _requestPendingApprovalDirectLoan creates a collateral-backed
        // loan above the approval threshold with directDisbursement=true.
        uint256 loanId = _requestPendingApprovalDirectLoan();

        // Owner calls, but loan is PendingApproval → LoanNotFundable
        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundFromPool(loanId);

        // Status must remain PendingApproval
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.PendingApproval),
            "loan must remain PendingApproval"
        );
    }

    // ================================================================
    // TEST 05: Borrower (non-owner, non-keeper) is rejected by fundFromPool.
    //          Owner (authorized) can fund the same loan successfully.
    // ================================================================
    function test_05_BorrowerRejectedOwnerSucceedsForDirectLoan() public {
        _seedPool(1_000e6);
        uint256 loanId    = _requestDirectLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;
        uint256 walletBefore = usdc.balanceOf(creditWallet);

        // Borrower is not authorized — must revert NotAuthorized
        vm.prank(borrower);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        // Loan must remain Requested after the revert
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must remain Requested after unauthorized attempt"
        );

        // Owner funds the same loan — must succeed
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after owner-triggered fundFromPool"
        );
        assertEq(vault.lockedAmount(loanId), 0, "no milestone lock for direct loan");
        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal, "funds at creditWallet");
    }

    // ================================================================
    // TEST 06: Pool accounting integrity — both milestone and direct
    //          pool loans update accounting correctly; failed calls
    //          (e.g. PendingApproval status gate) leave pool untouched.
    // ================================================================
    function test_06_PoolAccountingIntegrity() public {
        _seedPool(1_000e6);
        uint256 milestoneLoanId = _requestLoan(50e6);        // directDisbursement=false
        uint256 directLoanId    = _requestDirectLoan(100e6); // directDisbursement=true

        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        // Milestone loan: owner funds successfully
        vault.fundFromPool(milestoneLoanId);
        assertEq(pool.idleLedger(),    idleBefore - 50e6,     "idleLedger after milestone fundFromPool");
        assertEq(pool.totalDeployed(), deployedBefore + 50e6, "totalDeployed after milestone fundFromPool");

        // Direct loan: owner funds — pool accounting updated again
        vault.fundFromPool(directLoanId);
        assertEq(pool.idleLedger(),    idleBefore - 150e6,     "idleLedger after direct fundFromPool");
        assertEq(pool.totalDeployed(), deployedBefore + 150e6, "totalDeployed after direct fundFromPool");

        // Status gate test: PendingApproval loan fails without touching pool.
        // Must use directDisbursement=true for collateral-backed loan (policy).
        uint256 pendingLoanId = _requestPendingApprovalDirectLoan();
        uint256 idleAfter     = pool.idleLedger();
        uint256 deployedAfter = pool.totalDeployed();

        // Owner calls; PendingApproval status gate fires before disbursement check
        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundFromPool(pendingLoanId);
        assertEq(pool.idleLedger(),    idleAfter,     "idleLedger unchanged after LoanNotFundable revert");
        assertEq(pool.totalDeployed(), deployedAfter, "totalDeployed unchanged after LoanNotFundable revert");
    }

    // ================================================================
    // TEST 07: fundLoan by a non-owner does not affect pool accounting
    // ================================================================
    function test_07_FundLoanDoesNotAffectPool() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestLoan(100e6);

        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        // directLender funds directly — pool must be untouched
        vm.prank(directLender);
        vault.fundLoan(loanId);

        assertEq(pool.idleLedger(),    idleBefore,     "pool idleLedger must not change on fundLoan");
        assertEq(pool.totalDeployed(), deployedBefore, "pool totalDeployed must not change on fundLoan");
        assertEq(pool.principalAdvanced(loanId), 0,    "principalAdvanced must be 0 for direct loan");
    }

    // ================================================================
    // TEST 08 (spec A): Stranger (ordinary EOA) is rejected by
    //                   fundFromPool — NotAuthorized.  Owner can fund
    //                   the same eligible Requested loan.
    // ================================================================
    function test_08_StrangerRejectedOwnerFundsEligibleRequestedDirectLoan() public {
        _seedPool(1_000e6);
        uint256 loanId    = _requestDirectLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;
        uint256 walletBefore = usdc.balanceOf(creditWallet);

        // Stranger must be rejected
        vm.prank(stranger);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        // Loan stays Requested
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must remain Requested after stranger rejection"
        );

        // Owner funds successfully
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after owner funding"
        );
        assertEq(vault.lockedAmount(loanId), 0,                            "no vault lock for direct");
        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal,   "creditWallet receives funds");
        assertEq(registry.getLoan(loanId).lender, address(pool),           "lender is pool");
        assertEq(pool.principalAdvanced(loanId), principal,                "pool records advance");
    }

    // ================================================================
    // TEST 09 (spec B): Stranger is rejected for an Approved loan;
    //                   owner can fund it successfully.
    //
    //  A loan needs manual approveLoan() only when principal > CAT
    //  (approval threshold).  We use _requestPendingApprovalDirectLoan()
    //  which creates a PendingApproval loan with directDisbursement=true,
    //  then the owner approves it so it transitions to Approved.
    // ================================================================
    function test_09_StrangerRejectedOwnerFundsApprovedDirectLoan() public {
        // Pool must cover CAT + 1e6 principal
        _seedPool(20_000_000e6);

        // Creates a PendingApproval loan (principal = CAT+1e6, directDisbursement=true)
        uint256 loanId = _requestPendingApprovalDirectLoan();

        // Owner approves the loan — transitions PendingApproval -> Approved
        registry.approveLoan(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Approved),
            "loan must be Approved before funding"
        );

        // Stranger is rejected even for an Approved loan
        vm.prank(stranger);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        // Status must still be Approved
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Approved),
            "loan must remain Approved after stranger rejection"
        );

        uint256 principal    = registry.getLoan(loanId).principal;
        uint256 walletBefore = usdc.balanceOf(creditWallet);

        // Owner funds the approved direct-disbursement loan
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after owner fundFromPool"
        );
        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal, "creditWallet receives funds");
        assertEq(vault.lockedAmount(loanId), 0, "no vault lock for direct disbursement");
        assertEq(registry.getLoan(loanId).lender, address(pool), "lender is pool");
    }

    // ================================================================
    // TEST 10 (spec C): PendingApproval loan cannot be pool-funded.
    //                   Stranger: NotAuthorized fires first.
    //                   Owner: LoanNotFundable fires (status gate).
    // ================================================================
    function test_10_PendingApprovalLoanCannotBePoolFunded() public {
        _seedPool(1_000_000e6);
        // Collateralized loans must use directDisbursement=true (policy).
        uint256 loanId = _requestPendingApprovalDirectLoan(); // collateral-backed, directDisbursement=true, PendingApproval

        // Stranger: NotAuthorized fires before the status gate
        vm.prank(stranger);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        // Owner: passes auth check but hits LoanNotFundable (status gate)
        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.PendingApproval),
            "status must remain PendingApproval"
        );
    }

    // ================================================================
    // TEST 11 (spec D): Direct-disbursement pool loan sends funds to
    //                   creditWallet immediately; no milestone release needed.
    // ================================================================
    function test_11_DirectDisbursementFundsReachCreditWallet() public {
        _seedPool(500e6);
        uint256 loanId    = _requestDirectLoan(200e6);
        uint256 principal = registry.getLoan(loanId).principal;

        uint256 vaultBalBefore  = usdc.balanceOf(address(vault));
        uint256 walletBalBefore = usdc.balanceOf(creditWallet);

        vault.fundFromPool(loanId);

        // creditWallet receives full principal
        assertEq(usdc.balanceOf(creditWallet), walletBalBefore + principal, "creditWallet balance");
        // Vault does not retain any of the principal
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore,            "vault holds nothing");
        // lockedAmount is zero — no milestone release path
        assertEq(vault.lockedAmount(loanId), 0,                             "lockedAmount is 0");

        // releaseMilestone must revert for a direct loan
        vm.expectRevert(LoanVault.DirectLoanCannotReleaseMilestone.selector);
        vault.releaseMilestone(loanId, 0);
    }

    // ================================================================
    // TEST 12 (spec E): Milestone pool loan (directDisbursement=false)
    //                   is accepted by owner (Phase 2 policy).
    //                   Collateral + milestone combination is still
    //                   blocked at requestLoan time.
    // ================================================================
    function test_12_MilestonePoolLoanPermittedOwnerCollateralStillBlocked() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestLoan(100e6); // directDisbursement=false, unsecured

        // Owner can fund
        vault.fundFromPool(loanId);
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "owner-funded milestone pool loan must be Active"
        );

        // Owner can fund a second fresh loan too
        uint256 loanId2 = _requestLoan(50e6);
        vault.fundFromPool(loanId2);
        assertEq(
            uint8(registry.getLoan(loanId2).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "owner-funded milestone pool loan must be Active"
        );

        // Collateral + milestone combination must revert at requestLoan
        uint256 principal = 100e6;
        uint256 required  = collateralVault.requiredCollateral(principal);
        usdc.mint(borrower, required);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Collateral milestone";

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CollateralizedLoanMustUseDirectDisbursement.selector);
        registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "collateral milestone must fail",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: required,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: false  // ← must revert
        }));
    }

    // ================================================================
    // TEST 13 (spec F): Double pool-funding still reverts with the
    //                   correct existing error.
    // ================================================================
    function test_13_DoubleFundFromPoolReverts() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestDirectLoan(100e6);

        vault.fundFromPool(loanId); // first call succeeds

        // Second call: loan is now Active → LoanNotFundable
        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundFromPool(loanId);
    }

    // ================================================================
    // TEST 14 (spec G): fundFromPool reverts when pool has insufficient
    //                   liquidity (pool accounting check preserved).
    // ================================================================
    function test_14_InsufficientLiquidityReverts() public {
        _seedPool(50e6); // only 50 USDC in pool
        uint256 loanId = _requestDirectLoan(100e6); // wants 100 USDC

        // Must revert — pool doesn't have enough
        vm.expectRevert();
        vault.fundFromPool(loanId);

        // Loan status unchanged
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must remain Requested after liquidity revert"
        );
    }

    // ================================================================
    // TEST 15 (spec H): Credit-limit check enforced for pool loans.
    //                   A second loan that would exceed credit limit reverts.
    // ================================================================
    function test_15_CreditLimitEnforcedForPoolLoans() public {
        // Actual credit limit in setUp:
        //   initialLimit = 5e6
        //   recordRepayment(agentId, 5_000e6, false)
        //     → increase = 5_000e6 * 2500 / 10_000 = 1_250e6
        //   currentLimit = 5e6 + 1_250e6 = 1_255e6
        //   activityLimit = 0
        //   getLimit(agentId) = 1_255e6
        //
        // Strategy: request and fund a loan for 1_200e6 (within limit).
        // Then try to request 100e6 more (total outstanding = 1_300e6 > 1_255e6).
        // requestLoan must revert ExceedsCreditLimit before the second loan exists.
        _seedPool(2_000e6);
        uint256 loan1 = _requestDirectLoan(1_200e6);
        vault.fundFromPool(loan1); // outstanding = 1_200e6; remaining = 55e6

        // Request 100e6 — would push outstanding to 1_300e6, exceeding 1_255e6 limit
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: 100e6});
        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = 100e6;
        string[] memory desc = new string[](1); desc[0] = "over limit";

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: 100e6,
            repaymentRateBps: 10000,
            totalRepaymentDue: (100e6 * 115) / 100,
            duration: 30 days,
            purpose: "over limit",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: 0,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: true
        }));

        // Confirm loan1 is still Active — the second revert did not affect it
        assertEq(
            uint8(registry.getLoan(loan1).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan1 must remain Active"
        );
    }

    // ================================================================
    // TEST 16 (spec I): P2P fundLoan (directDisbursement=false) is
    //                   fully unaffected by the pool-funding policy.
    // ================================================================
    function test_16_P2PFundLoanUnaffectedByPoolPolicy() public {
        // P2P milestone loan — directDisbursement=false
        uint256 loanId    = _requestLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        // directLender funds P2P — no pool involved
        vm.prank(directLender);
        vault.fundLoan(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "P2P loan must be Active"
        );
        // Milestone locked — directLender will release
        assertEq(vault.lockedAmount(loanId), principal, "milestone funds locked in vault");
        assertEq(registry.getLoan(loanId).lender, directLender, "lender is directLender, not pool");
        // Pool untouched
        assertEq(pool.principalAdvanced(loanId), 0, "pool did not advance anything");

        // P2P directDisbursement loan
        uint256 loanId2    = _requestDirectLoan(50e6);
        uint256 principal2 = registry.getLoan(loanId2).principal;
        uint256 walletBefore = usdc.balanceOf(creditWallet);

        vm.prank(directLender);
        vault.fundLoan(loanId2);

        assertEq(
            uint8(registry.getLoan(loanId2).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "P2P direct loan must be Active"
        );
        assertEq(vault.lockedAmount(loanId2), 0, "no lock for direct P2P loan");
        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal2, "creditWallet receives P2P direct funds");
        assertEq(pool.principalAdvanced(loanId2), 0, "pool still not involved");
    }

    // ================================================================
    // TEST 17 (Phase 2 A): Pool owner can release a milestone on a
    //          pool-funded milestone loan.  Stranger cannot.
    // ================================================================
    function test_17_PoolOwnerCanReleaseMilestoneOnPoolMilestoneLoan() public {
        _seedPool(500e6);
        uint256 loanId    = _requestLoan(100e6); // directDisbursement=false, no collateral
        uint256 principal = registry.getLoan(loanId).principal;

        vault.fundFromPool(loanId); // pool funds milestone loan

        assertEq(vault.lockedAmount(loanId), principal, "funds locked in vault");

        uint256 walletBefore = usdc.balanceOf(creditWallet);

        // Pool owner (owner == address(this)) releases the single milestone
        vault.releaseMilestone(loanId, 0);

        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal, "creditWallet received milestone");
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount drained after release");
        assertTrue(registry.getMilestones(loanId)[0].released, "milestone flagged as released");
    }

    // ================================================================
    // TEST 18 (Phase 2 B): Stranger cannot release a milestone on a
    //          pool-funded loan — NotLender reverts.
    // ================================================================
    function test_18_StrangerCannotReleaseMilestoneOnPoolLoan() public {
        _seedPool(500e6);
        uint256 loanId = _requestLoan(100e6);

        vault.fundFromPool(loanId);

        vm.prank(stranger);
        vm.expectRevert(LoanVault.NotLender.selector);
        vault.releaseMilestone(loanId, 0);

        // borrower (who owns the agentId but is not pool owner) also cannot
        vm.prank(borrower);
        vm.expectRevert(LoanVault.NotLender.selector);
        vault.releaseMilestone(loanId, 0);

        // Funds must remain locked
        assertEq(vault.lockedAmount(loanId), 100e6, "funds must remain locked");
    }

    // ================================================================
    // TEST 19 (Phase 2 C): settleExpiredLoan on a defaulted pool-funded
    //          milestone loan returns locked funds to the pool address
    //          and records settledDefaultAmount for reconcileLoan().
    // ================================================================
    function test_19_SettleExpiredPoolMilestoneLoanReturnsToPool() public {
        _seedPool(500e6);
        uint256 loanId    = _requestLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        vault.fundFromPool(loanId);

        // Fast-forward past expiry + grace period
        uint256 expiresAt = registry.getLoan(loanId).expiresAt;
        vm.warp(expiresAt + registry.defaultGracePeriod() + 1);

        uint256 poolBalBefore = usdc.balanceOf(address(pool));

        registry.markDefault(loanId);
        vault.settleExpiredLoan(loanId);

        // Locked funds must travel to the pool address (loan.lender)
        assertEq(usdc.balanceOf(address(pool)), poolBalBefore + principal, "pool must receive locked funds");
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount cleared");
        // settledDefaultAmount recorded for reconcileLoan
        assertEq(vault.settledDefaultAmount(loanId), principal, "settledDefaultAmount must equal principal");
    }

    // ================================================================
    // TEST 20 (Phase 2 D): reconcileLoan credits settledDefaultAmount
    //          into pool accounting exactly once (vaultSettlementCounted).
    // ================================================================
    function test_20_ReconcileLoanCreditsVaultSettlementExactlyOnce() public {
        _seedPool(500e6);
        uint256 loanId    = _requestLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        vault.fundFromPool(loanId);

        uint256 expiresAt = registry.getLoan(loanId).expiresAt;
        vm.warp(expiresAt + registry.defaultGracePeriod() + 1);
        registry.markDefault(loanId);
        vault.settleExpiredLoan(loanId);

        uint256 idleBefore = pool.idleLedger();

        // First reconcile: vaultSettlementCounted fires, credits settledDefaultAmount
        pool.reconcileLoan(loanId);

        assertEq(pool.idleLedger(), idleBefore + principal, "idleLedger must increase by settled amount");
        assertTrue(pool.vaultSettlementCounted(loanId), "vaultSettlementCounted must be set");

        // Second reconcile: vaultSettlementCounted prevents double-credit
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(), idleBefore + principal, "idleLedger must not change on second reconcile");
    }

    // ================================================================
    // TEST 21 (Phase 2 E): Collateralized loan with directDisbursement=true
    //          is accepted; with directDisbursement=false it is rejected
    //          at requestLoan (CollateralizedLoanMustUseDirectDisbursement).
    // ================================================================
    function test_21_CollateralizedLoanMustUseDirect() public {
        uint256 principal = 100e6;
        uint256 required  = collateralVault.requiredCollateral(principal);

        usdc.mint(borrower, required * 2);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required * 2);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Collateral test";

        // directDisbursement=false with collateral: must revert
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CollateralizedLoanMustUseDirectDisbursement.selector);
        registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "collateral milestone MUST fail",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: required,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: false
        }));

        // directDisbursement=true with collateral: must succeed
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "collateral direct - must succeed",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: required,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: true
        }));
        assertTrue(
            registry.getLoan(loanId).status == ILoanRegistry.LoanStatus.Requested ||
            registry.getLoan(loanId).status == ILoanRegistry.LoanStatus.PendingApproval,
            "collateral+direct loan must be created"
        );
        assertTrue(registry.getDirectDisbursement(loanId), "directDisbursement must be true");
    }

    // ================================================================
    // TEST 22 (Phase 2 F): Default-history restrictions intact for pool
    //          milestone loans.  A severe default zeros credit; a new
    //          unsecured loan for the same agent reverts ExceedsCreditLimit.
    // ================================================================
    function test_22_DefaultHistoryRestrictionsIntactForPoolMilestoneLoan() public {
        _seedPool(2_000e6);

        // Fund and default a pool milestone loan
        uint256 loanId = _requestLoan(100e6);
        vault.fundFromPool(loanId);

        uint256 expiresAt = registry.getLoan(loanId).expiresAt;
        vm.warp(expiresAt + registry.defaultGracePeriod() + 1);
        registry.markDefault(loanId);

        // Verify severe default zeroed the credit limit
        // (outstandingPrincipal was decremented in markDefault; zero recovered → severe)
        // getLimit now returns 0 + 0 = 0
        assertEq(creditReg.getLimit(agentId), 0, "credit limit must be 0 after severe default");

        // Requesting a new unsecured loan must fail ExceedsCreditLimit
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: 10e6});
        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = 10e6;
        string[] memory desc = new string[](1); desc[0] = "post-default";

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: 10e6,
            repaymentRateBps: 10000,
            totalRepaymentDue: 11e6,
            duration: 30 days,
            purpose: "post-default unsecured",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: 0,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: false
        }));
    }

    // ================================================================
    // TEST 23 (Phase 2 G): Collateral does not bypass default-history
    //          restrictions — after a severe default, a new collateral-
    //          backed loan is still accepted (collateral bypasses credit
    //          limit, not the ability to request a loan). Existing
    //          default-credit penalties remain in place.
    // ================================================================
    function test_23_CollateralBypassesCreditLimitNotDefaultHistory() public {
        _seedPool(2_000e6);

        // Fund and default an unsecured pool milestone loan → severe default
        uint256 loanId = _requestLoan(100e6);
        vault.fundFromPool(loanId);

        uint256 expiresAt = registry.getLoan(loanId).expiresAt;
        vm.warp(expiresAt + registry.defaultGracePeriod() + 1);
        registry.markDefault(loanId);

        assertEq(creditReg.getLimit(agentId), 0, "credit limit zeroed after severe default");

        // A new collateral-backed direct-disbursement loan is accepted even
        // with zero credit limit (collateral path skips the ExceedsCreditLimit check).
        uint256 principal2 = 50e6;
        uint256 required2  = collateralVault.requiredCollateral(principal2);

        usdc.mint(borrower, required2);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required2);

        ILoanRegistry.BudgetCategory[] memory budget2 = new ILoanRegistry.BudgetCategory[](1);
        budget2[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal2});
        address[] memory recipients2 = new address[](2);
        recipients2[0] = address(0xD00D);
        recipients2[1] = creditWallet;
        uint256[] memory ms2 = new uint256[](1); ms2[0] = principal2;
        string[] memory desc2 = new string[](1); desc2[0] = "Post-default collateral";

        vm.prank(borrower);
        uint256 loanId2 = registry.requestLoan(ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal2,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal2 * 115) / 100,
            duration: 30 days,
            purpose: "post-default collateral direct",
            budget: budget2,
            permittedRecipients: recipients2,
            milestoneAmounts: ms2,
            milestoneDescriptions: desc2,
            collateralAmount: required2,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: true
        }));

        // Loan must be created (credit history imposes credit-limit, not borrow eligibility,
        // and collateral bypasses the credit-limit check)
        assertTrue(
            registry.getLoan(loanId2).status == ILoanRegistry.LoanStatus.Requested ||
            registry.getLoan(loanId2).status == ILoanRegistry.LoanStatus.PendingApproval,
            "collateral-backed loan must be accepted after severe default"
        );
        // Credit limit remains 0 — default history is preserved
        assertEq(creditReg.getLimit(agentId), 0, "credit limit must remain 0 after new collateral loan");
    }

    // ================================================================
    // TEST 24: A registered LoanRegistry keeper CAN call fundFromPool.
    // ================================================================
    function test_24_RegisteredKeeperCanCallFundFromPool() public {
        _seedPool(500e6);
        address keeper = address(0xBEEF);
        registry.setKeeper(keeper, true);
        assertTrue(registry.keepers(keeper), "keeper must be registered");

        uint256 loanId    = _requestDirectLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;
        uint256 walletBefore = usdc.balanceOf(creditWallet);

        // Keeper (not owner) funds the loan
        vm.prank(keeper);
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after keeper-triggered fundFromPool"
        );
        assertEq(vault.lockedAmount(loanId), 0, "no vault lock for direct loan");
        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal, "creditWallet receives funds");
        assertEq(registry.getLoan(loanId).lender, address(pool), "lender is pool");
    }

    // ================================================================
    // TEST 25: An unregistered stranger is rejected with NotAuthorized.
    // ================================================================
    function test_25_UnregisteredStrangerRejectedNotAuthorized() public {
        _seedPool(500e6);
        uint256 loanId = _requestDirectLoan(100e6);

        assertFalse(registry.keepers(stranger), "stranger must not be a keeper");
        assertFalse(stranger == vault.owner(),  "stranger must not be the owner");

        vm.prank(stranger);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        // Loan unchanged
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must remain Requested"
        );
        assertEq(pool.principalAdvanced(loanId), 0, "pool must not have advanced anything");
    }

    // ================================================================
    // TEST 26: The borrower is rejected with NotAuthorized.
    // ================================================================
    function test_26_BorrowerRejectedNotAuthorized() public {
        _seedPool(500e6);
        uint256 loanId = _requestDirectLoan(100e6);

        assertFalse(registry.keepers(borrower), "borrower must not be a keeper");
        assertFalse(borrower == vault.owner(),  "borrower must not be the owner");

        vm.prank(borrower);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must remain Requested"
        );
    }

    // ================================================================
    // TEST 27: A revoked keeper is rejected with NotAuthorized.
    // ================================================================
    function test_27_RevokedKeeperRejectedNotAuthorized() public {
        _seedPool(500e6);
        address keeper = address(0xBEEF2);
        // Register and then revoke
        registry.setKeeper(keeper, true);
        assertTrue(registry.keepers(keeper), "keeper must be registered before revoke");
        registry.setKeeper(keeper, false);
        assertFalse(registry.keepers(keeper), "keeper must be revoked");

        uint256 loanId = _requestDirectLoan(100e6);

        vm.prank(keeper);
        vm.expectRevert(LoanVault.NotAuthorized.selector);
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must remain Requested after revoked-keeper attempt"
        );
    }

    // ================================================================
    // TEST 28: Owner always passes the keeper check, regardless of
    //          whether the owner address is also registered as a keeper.
    // ================================================================
    function test_28_OwnerAlwaysAuthorizedRegardlessOfKeeperState() public {
        _seedPool(500e6);
        // Confirm owner is not registered as a keeper (pure owner-path)
        assertFalse(registry.keepers(owner), "owner must not be pre-registered as a keeper");

        uint256 loanId    = _requestDirectLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;
        uint256 walletBefore = usdc.balanceOf(creditWallet);

        // Owner funds without keeper registration
        vault.fundFromPool(loanId);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after owner funding"
        );
        assertEq(usdc.balanceOf(creditWallet), walletBefore + principal, "creditWallet receives funds");

        // Now register owner as a keeper too (belt-and-suspenders)
        registry.setKeeper(owner, true);
        uint256 loanId2    = _requestDirectLoan(100e6);
        uint256 walletBefore2 = usdc.balanceOf(creditWallet);

        vault.fundFromPool(loanId2);

        assertEq(
            uint8(registry.getLoan(loanId2).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active when owner is also a keeper"
        );
        assertEq(usdc.balanceOf(creditWallet), walletBefore2 + 100e6, "creditWallet receives funds");
    }
}

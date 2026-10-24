// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";

contract LoanVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    ILoanRegistry public registry;
    IERC20 public usdc;
    address public liquidityPool;

    mapping(uint256 => uint256) public lockedAmount;
    /// @notice Records the amount recovered from the vault for a defaulted loan.
    ///         Set in settleExpiredLoan() when status == Defaulted so that
    ///         LiquidityPool.reconcileLoan() can credit it even after lockedAmount
    ///         has been cleared (RISK-01 fix).
    mapping(uint256 => uint256) public settledDefaultAmount;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    event LoanFundedInVault(uint256 indexed loanId, address indexed lender, uint256 amount);
    event MilestoneFundsReleased(uint256 indexed loanId, uint256 milestoneIndex, address indexed creditWallet, uint256 amount);
    event ExpiredLoanSettled(uint256 indexed loanId, address indexed lender, uint256 returnedAmount);
    event LiquidityPoolSet(address indexed liquidityPool);

    error ZeroAddress();
    error ReentrantCall();
    error LoanNotFundable();
    error LoanNotActive();
    error NotLender();
    error BadMilestoneIndex();
    error MilestoneAlreadyReleased();
    error InsufficientLockedFunds();
    error LoanNotExpired();
    error NothingToSettle();
    error LiquidityPoolAlreadySet();
    error ActiveLoansExist();
    error LiquidityPoolNotSet();
    error DirectLoanCannotReleaseMilestone();
    /// @notice Thrown when an address that is neither the owner nor a registered
    ///         LoanRegistry keeper attempts to call fundFromPool().
    error NotAuthorized();
    /// @notice Thrown when settleExpiredLoan is called on a loan that has not
    ///         yet been marked Defaulted. markDefault() must be called first,
    ///         after the grace period elapses, so that vault settlement cannot
    ///         leave the loan in a stale Active state where a subsequent
    ///         markDefault() would double-seize collateral.
    error LoanNotDefaulted();

    /// @notice Emitted when directDisbursement == true and the full principal is
    ///         sent to creditWallet immediately at funding time.
    event DirectDisbursementSent(uint256 indexed loanId, address indexed creditWallet, uint256 amount);

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() internal {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
    }

    function _nonReentrantAfter() internal {
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _registry, address _usdc) external initializer {
        if (_registry == address(0) || _usdc == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        registry = ILoanRegistry(_registry);
        usdc = IERC20(_usdc);
        _reentrancyStatus = _NOT_ENTERED;
    }

    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        if (liquidityPool != address(0) && ILiquidityPool(liquidityPool).activeLoanCount() > 0) revert ActiveLoansExist();
        if (_liquidityPool == address(0)) revert ZeroAddress();
        liquidityPool = _liquidityPool;
        emit LiquidityPoolSet(_liquidityPool);
    }

    /// @notice Direct P2P funding path — unchanged. A specific caller
    ///         funds a specific loan with their own USDC.
    function fundLoan(uint256 loanId) external nonReentrant {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Requested && loan.status != ILoanRegistry.LoanStatus.Approved) {
            revert LoanNotFundable();
        }

        emit LoanFundedInVault(loanId, msg.sender, loan.principal);

        usdc.safeTransferFrom(msg.sender, address(this), loan.principal);
        registry.markFunded(loanId, msg.sender);

        // Direct-disbursement path: transfer full principal to creditWallet
        // immediately, skipping per-milestone release. lockedAmount stays
        // zero so releaseMilestone cannot double-pay.
        if (registry.getDirectDisbursement(loanId)) {
            ILoanRegistry.LoanView memory funded = registry.getLoan(loanId);
            usdc.safeTransfer(funded.creditWallet, loan.principal);
            emit DirectDisbursementSent(loanId, funded.creditWallet, loan.principal);
        } else {
            lockedAmount[loanId] = loan.principal;
        }
    }

    /// @notice Pooled funding path. Restricted to the contract owner or a
    ///         registered LoanRegistry keeper. All eligibility requirements
    ///         are enforced entirely on-chain:
    ///           * Caller must be the owner or a registered keeper
    ///             (registry.keepers(msg.sender) == true).  Unauthorized
    ///             callers revert NotAuthorized().
    ///           * Loan must be Requested or Approved (PendingApproval loans
    ///             are blocked by the status check below).
    ///           * Both directDisbursement=true and directDisbursement=false
    ///             (milestone) loans are accepted.  Collateralized loans are
    ///             guaranteed to use directDisbursement=true by a guard in
    ///             LoanRegistry._validateProposal, so that path never produces
    ///             a collateral+milestone combination.  For milestone pool loans,
    ///             only the pool owner (the trusted Valen operator) can release
    ///             milestones via releaseMilestone(), so an unauthorized caller
    ///             cannot lock LP capital by funding and then refusing to release.
    ///           * Pool liquidity, duplicate-funding, and accounting checks
    ///             are enforced inside LiquidityPool.fundLoan().
    ///           * Reentrancy protected by nonReentrant.
    function fundFromPool(uint256 loanId) external nonReentrant {
        if (msg.sender != owner() && !registry.keepers(msg.sender)) revert NotAuthorized();
        if (liquidityPool == address(0)) revert LiquidityPoolNotSet();

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Requested && loan.status != ILoanRegistry.LoanStatus.Approved) {
            revert LoanNotFundable();
        }

        emit LoanFundedInVault(loanId, liquidityPool, loan.principal);

        ILiquidityPool(liquidityPool).fundLoan(loanId, loan.principal);
        registry.markFunded(loanId, liquidityPool);

        // Direct-disbursement path: LiquidityPool sent funds to LoanVault;
        // immediately forward them to creditWallet. lockedAmount stays zero.
        if (registry.getDirectDisbursement(loanId)) {
            ILoanRegistry.LoanView memory funded = registry.getLoan(loanId);
            usdc.safeTransfer(funded.creditWallet, loan.principal);
            emit DirectDisbursementSent(loanId, funded.creditWallet, loan.principal);
        } else {
            lockedAmount[loanId] = loan.principal;
        }
    }

    /// @notice Milestone attestation. For a P2P loan, only the actual
    ///         human/agent lender can attest. For a pool-funded loan
    ///         (loan.lender == liquidityPool), no EOA can ever literally
    ///         be that address — so the pool's own owner (the trusted
    ///         Valen backend) is permitted to attest on the pool's behalf.
    ///         This is the one authorization change pooled funding required.
    function releaseMilestone(uint256 loanId, uint256 milestoneIndex) external nonReentrant {
        // Direct-disbursement loans have no locked funds to release via milestones.
        if (registry.getDirectDisbursement(loanId)) revert DirectLoanCannotReleaseMilestone();

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Active) revert LoanNotActive();

        bool isPoolLoan = liquidityPool != address(0) && loan.lender == liquidityPool;
        bool callerIsPoolOwner = isPoolLoan && msg.sender == OwnableUpgradeable(liquidityPool).owner();
        if (msg.sender != loan.lender && !callerIsPoolOwner) revert NotLender();

        ILoanRegistry.Milestone[] memory milestones = registry.getMilestones(loanId);
        if (milestoneIndex >= milestones.length) revert BadMilestoneIndex();
        ILoanRegistry.Milestone memory milestone = milestones[milestoneIndex];
        if (milestone.released) revert MilestoneAlreadyReleased();
        if (lockedAmount[loanId] < milestone.amount) revert InsufficientLockedFunds();

        lockedAmount[loanId] -= milestone.amount;
        emit MilestoneFundsReleased(loanId, milestoneIndex, loan.creditWallet, milestone.amount);

        registry.markMilestoneReleased(loanId, milestoneIndex);
        usdc.safeTransfer(loan.creditWallet, milestone.amount);
    }

    function settleExpiredLoan(uint256 loanId) external nonReentrant {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (block.timestamp < loan.expiresAt) revert LoanNotExpired();
        // Only Defaulted loans may be settled from the vault.
        // Callers must invoke markDefault() first (after the grace period).
        // This prevents settleExpiredLoan() from leaving the loan in a
        // stale Active state, which would permit a subsequent markDefault()
        // to seize collateral on top of the already-returned vault funds.
        // Also accept Repaid loans that previously defaulted: post-default garnishment
        // can fully repay the debt (transitioning Defaulted -> Repaid via markRepaid)
        // before settleExpiredLoan() is called.  In that case lockedAmount may still be
        // non-zero and the lender is entitled to recover it.  registry.getWasDefaulted()
        // is the authoritative signal; it is set in markDefault() before any seizure.
        bool repaidAfterDefault =
            loan.status == ILoanRegistry.LoanStatus.Repaid &&
            registry.getWasDefaulted(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Defaulted && !repaidAfterDefault)
            revert LoanNotDefaulted();

        uint256 remaining = lockedAmount[loanId];
        if (remaining == 0) revert NothingToSettle();

        lockedAmount[loanId] = 0;
        // Record recovery amount so LiquidityPool.reconcileLoan() can credit it
        // into pool accounting (RISK-01). Always runs: settleExpiredLoan only
        // accepts Defaulted loans after the status-ordering fix.
        settledDefaultAmount[loanId] = remaining;
        emit ExpiredLoanSettled(loanId, loan.lender, remaining);

        usdc.safeTransfer(loan.lender, remaining);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
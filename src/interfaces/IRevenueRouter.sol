// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRevenueRouter {
    function totalRecovered(uint256 loanId) external view returns (uint256);
    /// @notice Amount of totalRecovered that physically reached the
    ///         lender/pool.  Excludes both post-default garnishment
    ///         clawbacks (reserveRepaid) and pre-default reserve skims
    ///         (reserveSkimmed).  Used by LiquidityPool.reconcileLoan.
    function poolRecovered(uint256 loanId) external view returns (uint256);
    function isFullyRepaid(uint256 loanId) external view returns (bool);
    /// @notice Cumulative non-defaulted reserve-skim amount for a loan.
    ///         Zero for loans repaid before this fix unless the owner
    ///         called setReserveSkimmed() for that loan.
    function reserveSkimmed(uint256 loanId) external view returns (uint256);
    /// @notice First loanId ineligible for historical migration.
    ///         Set once during the V2 reinitializer.  Zero means the
    ///         reinitializer has not yet run.
    function migrationCutoff() external view returns (uint256);
}
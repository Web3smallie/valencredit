// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades}        from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options}         from "openzeppelin-foundry-upgrades/Options.sol";
import {RevenueRouter}   from "../src/RevenueRouter.sol";

/// @notice Upgrades the RevenueRouter proxy to V2 (reserveSkimmed accounting fix).
///
/// =========================================================================
/// WHAT CHANGES IN V2
/// =========================================================================
///
///   New storage slots (appended after slot 9 — no existing slot moved):
///     Slot 10: migrationCutoff  (uint256) — set once by initializeV2()
///     Slot 11: _migrationLocked (bool)    — set by lockMigration()
///
///   New functions:
///     - initializeV2()          — reinitializer(2); records migrationCutoff
///                                 = registry.nextLoanId() at upgrade time.
///     - lockMigration()         — owner-only, irreversible; disables
///                                 setReserveSkimmed() permanently.
///
///   Modified functions:
///     - setReserveSkimmed()     — now enforces five ordered guards:
///         1. MigrationLocked          (after lockMigration())
///         2. LoanHasNoRepayment       (totalRecovered == 0)
///         3. LoanNotEligibleForMigration (loanId >= migrationCutoff)
///         4. SkimAlreadySet           (reserveSkimmed != 0)
///         5. ExceedsTotalRecovered    (amount > totalRecovered)
///     - poolRecovered()         — unchanged formula; NatSpec updated.
///
///   New errors: MigrationLocked, LoanHasNoRepayment, LoanNotEligibleForMigration
///   New event:  MigrationLockedEvent
///
/// =========================================================================
/// UPGRADE MECHANISM
/// =========================================================================
///
///   RevenueRouter is a UUPS proxy.  This script calls:
///     Upgrades.upgradeProxy(proxy, newImpl, initializeV2_calldata, opts)
///
///   upgradeProxy issues exactly TWO transactions:
///     (a) CREATE  — deploys new RevenueRouter implementation
///     (b) CALL    — calls upgradeToAndCall(newImpl, initializeV2_calldata)
///                   on the proxy.  The proxy atomically upgrades and calls
///                   initializeV2(), recording migrationCutoff.
///
///   The two transactions are sequential but NOT atomic.  If (a) succeeds
///   and (b) fails, the proxy remains on V1 (the deployed but unused
///   implementation is a sunk gas cost only).  In that state, run() is safe to
///   re-run: _preUpgradeChecks() passes (proxy still at V1 impl), and
///   initializeV2() uses reinitializer(2) so it will fire correctly.
///
///   If (b) succeeds (proxy is on V2), DO NOT re-run run() — _preUpgradeChecks()
///   will hard-revert because the proxy is no longer at the expected V1 impl.
///   Use resume() instead; it detects V2 is already live and does nothing.
///
/// =========================================================================
/// RELATIONSHIP TO V4 UPGRADE
/// =========================================================================
///
///   This script upgrades RevenueRouter ONLY.  UpgradeV4.s.sol upgrades
///   LoanRegistry, LoanVault, and LiquidityPool.  The two scripts are
///   independent and can be broadcast in either order.
///
///   Recommended sequencing:
///     1. UpgradeV4.s.sol          (LoanRegistry, LoanVault, LiquidityPool)
///     2. UpgradeRevenueRouter.s.sol (RevenueRouter to V2)
///     3. setReserveSkimmed(0, 220000) via cast send (see MANUAL STEPS below)
///     4. lockMigration()          via cast send (see MANUAL STEPS below)
///     5. reconcileLoan(0)         via LiquidityPool (see MANUAL STEPS below)
///
///   The V4 + RevenueRouter V2 upgrades can be broadcast in a single session.
///   Steps 3-5 must be executed AFTER the upgrade broadcast completes.
///
/// =========================================================================
/// PRE-UPGRADE CHECKLIST (run before broadcasting)
/// =========================================================================
///
///   1. Verify the proxy address below:
///        cast implementation 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///          --rpc-url arc_testnet
///      Expected current impl: 0x394D9f57F00f27B19b1549e23021Efed9CD7be38
///      If a different address is shown, update REVENUE_ROUTER_V1_IMPL below.
///
///   2. Confirm broadcaster is the proxy owner:
///        cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///          "owner()(address)" --rpc-url arc_testnet
///      Expected: 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144 (valen-deployer)
///
///   3. Confirm nextLoanId on-chain (becomes migrationCutoff after upgrade):
///        cast call 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d \
///          "nextLoanId()(uint256)" --rpc-url arc_testnet
///      Current value: 1 (only loan 0 exists).  migrationCutoff will be 1,
///      so only loanId 0 is eligible for migration.
///
/// =========================================================================
/// POST-UPGRADE VERIFICATION
/// =========================================================================
///
///   # Confirm implementation updated:
///   cast implementation 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///     --rpc-url arc_testnet
///   # (must differ from 0x394D9f57F00f27B19b1549e23021Efed9CD7be38)
///
///   # Confirm migrationCutoff was set:
///   cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///     "migrationCutoff()(uint256)" --rpc-url arc_testnet
///   # expected: 1
///
///   # Confirm V2 selector is live:
///   cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///     "migrationCutoff()(uint256)" --rpc-url arc_testnet
///   # expected: 1  (same call — proves ABI is live)
///
/// =========================================================================
/// MANUAL STEPS (after upgrade broadcast completes)
/// =========================================================================
///
///   Step A — Record historical reserve skim for loan 0:
///     cast send 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///       "setReserveSkimmed(uint256,uint256)" 0 220000 \
///       --account valen-deployer --rpc-url arc_testnet
///
///     Verify:
///       cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///         "reserveSkimmed(uint256)(uint256)" 0 --rpc-url arc_testnet
///       # expected: 220000
///
///       cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///         "poolRecovered(uint256)(uint256)" 0 --rpc-url arc_testnet
///       # expected: 10780000  (= 11000000 - 220000)
///
///   Step B — Lock migration (no further historical loans known):
///     cast send 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///       "lockMigration()" \
///       --account valen-deployer --rpc-url arc_testnet
///
///     Verify (must revert MigrationLocked):
///       cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \
///         "setReserveSkimmed(uint256,uint256)" 0 1 --rpc-url arc_testnet
///
///   Step C — Reconcile loan 0 (pool accounting cleanup):
///     cast send 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 \
///       "reconcileLoan(uint256)" 0 \
///       --account valen-deployer --rpc-url arc_testnet
///
///     Verify idleLedger after reconcile:
///       cast call 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 \
///         "idleLedger()(uint256)" --rpc-url arc_testnet
///       # expected: 20780000  (= 10000000 seed+deposit + 10780000 lenderShare)
///
///       cast call 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 \
///         "totalAssets()(uint256)" --rpc-url arc_testnet
///       # expected: 20780000  (must equal USDC.balanceOf(pool))
///
/// =========================================================================
/// HOW TO RUN
/// =========================================================================
///
///   Step 1 - Implementation-level validation (safe in any environment):
///     forge script script/UpgradeRevenueRouter.s.sol:UpgradeRevenueRouterScript \
///       --sig "validateImplementation()" --rpc-url arc_testnet
///
///   Step 2 - Dry-run (no broadcast, prints simulation output):
///     forge script script/UpgradeRevenueRouter.s.sol \
///       --rpc-url arc_testnet --account valen-deployer
///
///   Step 3 - Broadcast (irreversible - requires explicit approval):
///     forge script script/UpgradeRevenueRouter.s.sol \
///       --rpc-url arc_testnet --account valen-deployer --broadcast
///
///   Step 4 - Resume after partial failure (use INSTEAD of run() if the proxy
///             was already upgraded in a prior partial broadcast):
///     forge script script/UpgradeRevenueRouter.s.sol \
///       --sig "resume()" \
///       --rpc-url arc_testnet --account valen-deployer --broadcast
///
contract UpgradeRevenueRouterScript is Script {

    // -------------------------------------------------------------------------
    // Proxy address -- Arc Testnet
    // VERIFY against `cast implementation <proxy> --rpc-url arc_testnet`
    // before broadcasting.
    // -------------------------------------------------------------------------
    address constant REVENUE_ROUTER_PROXY  = 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822;

    // Known V1 implementation address for pre-upgrade assertion.
    // Update if a later V1 patch was deployed.
    address constant REVENUE_ROUTER_V1_IMPL = 0x394D9f57F00f27B19b1549e23021Efed9CD7be38;

    // -------------------------------------------------------------------------
    // Entry point: production upgrade
    // -------------------------------------------------------------------------
    function run() external {
        _preUpgradeChecks();

        vm.startBroadcast();

        // upgradeProxy issues two transactions:
        //   (a) CREATE: deploys new RevenueRouter implementation
        //   (b) CALL:   upgradeToAndCall(newImpl, initializeV2_calldata)
        //
        // initializeV2() uses reinitializer(2) so it can only be called once.
        // It records migrationCutoff = registry.nextLoanId() atomically with
        // the implementation swap.
        console.log("Upgrading RevenueRouter...");
        Upgrades.upgradeProxy(
            REVENUE_ROUTER_PROXY,
            "RevenueRouter.sol:RevenueRouter",
            abi.encodeCall(RevenueRouter.initializeV2, ()),
            _upgradeOpts()
        );
        console.log("  [OK] RevenueRouter proxy:  ", REVENUE_ROUTER_PROXY);
        console.log("  [OK] New implementation:   ",
            Upgrades.getImplementationAddress(REVENUE_ROUTER_PROXY));

        vm.stopBroadcast();

        _logPostUpgrade();
    }

    // -------------------------------------------------------------------------
    // Entry point: implementation-level validation only (no broadcast required)
    // -------------------------------------------------------------------------
    /// @notice Validates the V2 RevenueRouter implementation for upgrade safety
    ///         (constructor guards, _disableInitializers, selfdestruct, delegatecall)
    ///         WITHOUT storage layout comparison and WITHOUT broadcasting.
    ///
    ///         Run with:
    ///           forge script script/UpgradeRevenueRouter.s.sol:UpgradeRevenueRouterScript \
    ///             --sig "validateImplementation()" --rpc-url arc_testnet
    function validateImplementation() external {
        Options memory opts;
        Upgrades.validateImplementation("RevenueRouter.sol:RevenueRouter", opts);
        console.log("[OK] RevenueRouter V2 - implementation-level checks passed.");
        console.log("");
        console.log("NOTE: storage-layout comparison not performed here.");
        console.log("Slots 0-9 are unchanged; slots 10-11 are new safe appends.");
    }

    // -------------------------------------------------------------------------
    // Entry point: partial-failure recovery
    // -------------------------------------------------------------------------
    /// @notice Resumes after a partially-completed upgrade.
    ///
    ///         Use INSTEAD of run() when tx (b) (upgradeToAndCall) already
    ///         succeeded in a prior broadcast.  run() hard-reverts in that state
    ///         because the proxy is no longer at the expected V1 impl.
    ///
    ///         Per-proxy logic:
    ///           - V1 impl confirmed                → upgrades to V2 (same as run()).
    ///           - V2 confirmed (migrationCutoff callable) → skips with a log.
    ///           - Unknown impl                     → hard-aborts.
    ///
    ///         Run with:
    ///           forge script script/UpgradeRevenueRouter.s.sol \
    ///             --sig "resume()" \
    ///             --rpc-url arc_testnet --account valen-deployer --broadcast
    function resume() external {
        address impl = Upgrades.getImplementationAddress(REVENUE_ROUTER_PROXY);

        if (impl == REVENUE_ROUTER_V1_IMPL) {
            // Still on V1 — proceed exactly as run() does.
            console.log("[RESUME] RevenueRouter: at V1 impl, upgrading...");
            vm.startBroadcast();
            Upgrades.upgradeProxy(
                REVENUE_ROUTER_PROXY,
                "RevenueRouter.sol:RevenueRouter",
                abi.encodeCall(RevenueRouter.initializeV2, ()),
                _upgradeOpts()
            );
            vm.stopBroadcast();
            console.log("  [OK] RevenueRouter upgraded to V2:", Upgrades.getImplementationAddress(REVENUE_ROUTER_PROXY));
            _logPostUpgrade();
        } else if (_probeV2(REVENUE_ROUTER_PROXY)) {
            // V2 is already live — nothing to do.
            console.log("[RESUME] RevenueRouter: V2 already live, nothing to do. impl:", impl);
            console.log("Proceed with manual post-upgrade steps (setReserveSkimmed, lockMigration, reconcileLoan).");
        } else {
            revert(string(abi.encodePacked(
                "ABORT: RevenueRouter is at an unexpected impl address.\n",
                "  Current impl: ", _toHexString(impl), "\n",
                "  Expected V1:  0x394D9f57F00f27B19b1549e23021Efed9CD7be38\n",
                "  V2 probe:     failed (migrationCutoff() selector not found).\n",
                "Investigate before proceeding."
            )));
        }
    }

    // -------------------------------------------------------------------------
    // Internal: V2 selector probe
    // -------------------------------------------------------------------------
    /// @dev Probes RevenueRouter for V2 by calling migrationCutoff().
    ///      V1: reverts with empty data (selector does not exist).
    ///      V2: returns a uint256 (migrationCutoff value) — no revert.
    function _probeV2(address proxy) internal view returns (bool) {
        // migrationCutoff() → uint256: returns 32 bytes on V2, reverts (empty) on V1
        // (selector absent), and returns 0 bytes if proxy delegates to a non-contract.
        // We require at least 32 bytes of return data to confirm V2 is live.
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("migrationCutoff()")
        );
        return ok && data.length >= 32;
    }

    // -------------------------------------------------------------------------
    // Internal: upgrade options
    // -------------------------------------------------------------------------
    function _upgradeOpts() private pure returns (Options memory opts) {
        opts.referenceContract = "RevenueRouter.sol:RevenueRouter";
        // unsafeAllowRenames: false (default) — no variable was renamed in V2.
        // unsafeSkipStorageCheck: false (default) — storage check is active;
        //   V2 only appends migrationCutoff (slot 10) and _migrationLocked (slot 11).
        // unsafeSkipAllChecks: false (default) — all constructor/initializer
        //   checks run.
    }

    // -------------------------------------------------------------------------
    // Internal: pre-upgrade assertions
    // -------------------------------------------------------------------------
    function _preUpgradeChecks() internal view {
        address impl = Upgrades.getImplementationAddress(REVENUE_ROUTER_PROXY);

        if (impl != REVENUE_ROUTER_V1_IMPL) {
            revert(
                string(abi.encodePacked(
                    "ABORT: RevenueRouter proxy is not at expected V1 impl.\n",
                    "  Expected: 0x394D9f57F00f27B19b1549e23021Efed9CD7be38\n",
                    "  Actual:   use `cast implementation ",
                    _toHexString(REVENUE_ROUTER_PROXY),
                    " --rpc-url arc_testnet` to verify.\n",
                    "Update REVENUE_ROUTER_V1_IMPL if a later V1 patch is deployed."
                ))
            );
        }
        console.log("[OK] RevenueRouter proxy is at expected V1 impl: ", impl);
    }

    // -------------------------------------------------------------------------
    // Internal: post-upgrade log
    // -------------------------------------------------------------------------
    function _logPostUpgrade() internal pure {
        console.log("");
        console.log("=== REVENUE ROUTER V2 UPGRADE COMPLETE ===");
        console.log("");
        console.log("REQUIRED MANUAL STEPS (execute in order):");
        console.log("");
        console.log("A. Verify migrationCutoff was set (expect 1):");
        console.log("   cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \\");
        console.log("     \"migrationCutoff()(uint256)\" --rpc-url arc_testnet");
        console.log("");
        console.log("B. Set historical reserve skim for loan 0 (220000 USDC base units):");
        console.log("   cast send 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \\");
        console.log("     \"setReserveSkimmed(uint256,uint256)\" 0 220000 \\");
        console.log("     --account valen-deployer --rpc-url arc_testnet");
        console.log("");
        console.log("C. Verify poolRecovered(0) == 10780000:");
        console.log("   cast call 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \\");
        console.log("     \"poolRecovered(uint256)(uint256)\" 0 --rpc-url arc_testnet");
        console.log("");
        console.log("D. Lock migration (irreversible -- do after Step B is verified):");
        console.log("   cast send 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 \\");
        console.log("     \"lockMigration()\" --account valen-deployer --rpc-url arc_testnet");
        console.log("");
        console.log("E. Call reconcileLoan(0) on the LiquidityPool:");
        console.log("   cast send 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 \\");
        console.log("     \"reconcileLoan(uint256)\" 0 \\");
        console.log("     --account valen-deployer --rpc-url arc_testnet");
        console.log("");
        console.log("F. Verify totalAssets == USDC.balanceOf(pool) == 20780000:");
        console.log("   cast call 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 \\");
        console.log("     \"totalAssets()(uint256)\" --rpc-url arc_testnet");
        console.log("   cast call 0x3600000000000000000000000000000000000000 \\");
        console.log("     \"balanceOf(address)(uint256)\" \\");
        console.log("     0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 --rpc-url arc_testnet");
    }

    // -------------------------------------------------------------------------
    // Internal: address-to-hex helper
    // -------------------------------------------------------------------------
    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory b = abi.encodePacked(addr);
        bytes memory hexStr = new bytes(42);
        hexStr[0] = "0";
        hexStr[1] = "x";
        bytes memory hexChars = "0123456789abcdef";
        for (uint256 i = 0; i < 20; i++) {
            hexStr[2 + i * 2]     = hexChars[uint8(b[i]) >> 4];
            hexStr[3 + i * 2]     = hexChars[uint8(b[i]) & 0x0f];
        }
        return string(hexStr);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades}        from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options}         from "openzeppelin-foundry-upgrades/Options.sol";

/// @notice Upgrades LoanRegistry, LoanVault, and LiquidityPool proxies to V4.
///
/// =========================================================================
/// UPGRADE ORDERING
/// =========================================================================
///
///   1. LoanRegistry  (MUST be first)
///   2. LoanVault
///   3. LiquidityPool
///
///   LoanVault V4 and LiquidityPool V4 call `registry.getWasDefaulted(loanId)`,
///   a function that does not exist in the V3 LoanRegistry implementation.
///   Upgrading LoanRegistry first prevents a selector-not-found revert if either
///   of the other two upgrades is called before LoanRegistry is live on V4.
///
/// =========================================================================
/// TRANSACTION COUNT - NOT ATOMIC
/// =========================================================================
///
///   Each `Upgrades.upgradeProxy` call issues TWO transactions:
///     (a) CREATE  - deploys the new implementation contract
///     (b) CALL    - calls upgradeToAndCall on the proxy
///
///   This script upgrades THREE proxies, so the broadcast sends SIX transactions
///   in total.  They are sequential but NOT atomic.  A failure mid-sequence
///   leaves the remaining proxies on their previous implementations.
///
///   Partial-failure recovery:
///     - The already-upgraded proxies remain on their new implementations.
///       UUPS proxies have no rollback; each upgrade is permanent.
///     - The deployed-but-unused implementation contract from a failed CREATE
///       is a sunk gas cost; it poses no security risk.
///     - DO NOT re-run run() after partial success.  run() calls
///       _preUpgradeChecks(), which hard-reverts if any proxy is no longer at
///       its expected V3 impl — including a proxy that was already upgraded to
///       V4 in a prior partial run.  Re-running run() in a partial state will
///       abort before issuing any transactions.
///     - Instead, use resume() after fixing the root cause (gas, key, network).
///       resume() inspects each proxy independently:
///         - V3 impl confirmed     → upgrades that proxy to V4.
///         - V4 confirmed (by selector probe) → skips with a log message.
///         - Unknown impl          → hard-aborts; requires manual investigation.
///     - Check which proxies were upgraded before calling resume():
///         cast implementation <PROXY> --rpc-url arc_testnet
///
/// =========================================================================
/// WHAT CHANGES IN V4
/// =========================================================================
///
///   LoanRegistry V4
///   - New storage slot 17: `wasDefaulted` mapping(uint256 => bool)  [safe append]
///   - New error: CollateralizedLoanMustUseDirectDisbursement
///   - New errors: ZeroPrincipal, TotalRepaymentBelowPrincipal, ZeroRepaymentRate
///   - New function: getWasDefaulted(uint256) external view returns (bool)
///   - markDefault now sets wasDefaulted[loanId] = true
///   - Policy guard in _validateProposal: collateral + directDisbursement:false reverts
///   - ILoanRegistry now exposes keepers(address) view
///
///   LoanVault V4
///   - Storage unchanged (slots 0-5 identical to V3)
///   - fundFromPool: owner-or-registered-keeper access control (was onlyOwner)
///   - settleExpiredLoan: accepts Defaulted OR (Repaid AND wasDefaulted);
///     reverts LoanNotDefaulted instead of V3's LoanNotActive for invalid status
///   - New error: NotAuthorized
///   - New error: LoanNotDefaulted (replaces LoanNotActive for settleExpiredLoan gate)
///   - Removed: PoolLoanMustUseDirectDisbursement error and guard
///
///   LiquidityPool V4
///   - Storage unchanged (slots 0-21 identical)
///   - reconcileLoan: vaultSettlementCounted block now covers Repaid+wasDefaulted
///   - sweepToken: CannotSweepPoolToken guard prevents sweeping the pool's USDC
///
/// =========================================================================
/// NO REINITIALIZER REQUIRED
/// =========================================================================
///
///   wasDefaulted defaults to false for all existing loans, which is the correct
///   initial value (no V3 loan was marked default via the new codepath).
///
/// =========================================================================
/// PRE-UPGRADE CHECKLIST (run before broadcasting)
/// =========================================================================
///
///   1. Verify proxy addresses below match live testnet.
///      Expected current (pre-V4) implementations:
///        LoanRegistry: 0xd47496361e5C485611718BD06065971691D2ba07
///        LoanVault:    0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537
///        LiquidityPool: 0x828525794b195329e8F1aE501A61d7590df542c1
///
///      Verification command (run per proxy before broadcasting):
///        cast implementation <PROXY_ADDRESS> --rpc-url arc_testnet
///
///   2. Confirm the broadcaster address will be the proxy owner.
///      Expected owner: 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144 (valen-deployer)
///        cast call <PROXY> "owner()(address)" --rpc-url arc_testnet
///
///   3. Build a clean V4 build-info for storage validation (see validateWithReference).
///
///   4. Run validateImplementations() before broadcasting.
///
/// =========================================================================
/// POST-UPGRADE VERIFICATION
/// =========================================================================
///
///   After broadcasting, run ALL of the following and confirm expected output:
///
///   # Confirm implementation slots updated:
///   cast implementation <LOAN_REGISTRY_PROXY>  --rpc-url arc_testnet
///   cast implementation <LOAN_VAULT_PROXY>     --rpc-url arc_testnet
///   cast implementation <LIQUIDITY_POOL_PROXY> --rpc-url arc_testnet
///
///   # Confirm V4 selectors are live:
///   cast call <LOAN_REGISTRY_PROXY> "getWasDefaulted(uint256)(bool)" 0 --rpc-url arc_testnet
///   # expected: false
///
///   cast call <LOAN_VAULT_PROXY> "fundFromPool(uint256)" 0 --rpc-url arc_testnet
///   # expected: revert NotAuthorized (selector not-found on V3 is replaced by auth revert)
///
///   # Confirm keeper gate is live (unauthorized call must revert):
///   cast call <LOAN_VAULT_PROXY> "fundFromPool(uint256)" 1 \
///     --from 0x0000000000000000000000000000000000000001 --rpc-url arc_testnet
///   # expected: revert NotAuthorized
///
/// =========================================================================
/// HOW TO RUN
/// =========================================================================
///
///   Step 1 - Implementation-level validation (safe in any environment):
///     forge script script/UpgradeV4.s.sol:UpgradeV4Script \
///       --sig "validateImplementations()" --rpc-url arc_testnet
///
///   Step 2 - Storage-layout validation (requires clean V4-only build-info):
///     forge clean && forge build
///     forge script script/UpgradeV4.s.sol:UpgradeV4Script \
///       --sig "validateWithReference()" --rpc-url arc_testnet
///     # Alternatively, use the pre-built V3 reference snapshot:
///     # previous-builds/out/build-info must exist (run: cd previous-builds && forge build)
///     forge script script/UpgradeV4.s.sol:UpgradeV4Script \
///       --sig "validateWithReference()" --rpc-url arc_testnet
///
///   Step 3 - Dry-run (no broadcast, prints simulation output):
///     forge script script/UpgradeV4.s.sol \
///       --rpc-url arc_testnet --account valen-deployer
///
///   Step 4 - Broadcast (irreversible - requires explicit approval):
///     forge script script/UpgradeV4.s.sol \
///       --rpc-url arc_testnet --account valen-deployer --broadcast
///
///   Step 5 - Resume after partial failure (use INSTEAD of run() if any proxy
///             was already upgraded in a prior partial broadcast):
///     forge script script/UpgradeV4.s.sol \
///       --sig "resume()" \
///       --rpc-url arc_testnet --account valen-deployer --broadcast
///
contract UpgradeV4Script is Script {

    // -------------------------------------------------------------------------
    // Proxy addresses -- Arc Testnet
    // VERIFY each against `cast implementation <proxy> --rpc-url arc_testnet`
    // before broadcasting.
    // -------------------------------------------------------------------------
    address constant LOAN_REGISTRY_PROXY  = 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d;
    address constant LOAN_VAULT_PROXY     = 0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19;
    address constant LIQUIDITY_POOL_PROXY = 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061;

    // Known pre-upgrade implementation addresses for pre-upgrade assertions.
    // These must match the live chain state.  If they do not, the pre-upgrade
    // check reverts and stops the broadcast before any state change.
    address constant LOAN_REGISTRY_V3_IMPL      = 0xd47496361e5C485611718BD06065971691D2ba07;
    address constant LOAN_VAULT_V3_IMPL         = 0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537;
    // LiquidityPool pre-V4 impl — verified from live Arc Testnet via
    //   cast implementation 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 --rpc-url arc_testnet
    // This is the post-V2 impl (vaultSettlementCounted + maxActiveLoans appended).
    // V3 and V4 LiquidityPool have identical public ABIs from a non-owner caller,
    // so impl-address comparison is the only reliable pre/post-V4 discriminator for
    // the "needs upgrade" branch.  The selector probe (_probePoolV4) handles skip
    // detection after the upgrade has already been applied.
    address constant LIQUIDITY_POOL_PRE_V4_IMPL = 0x828525794b195329e8F1aE501A61d7590df542c1;

    // Owner of all three proxies — used by _probePoolV4 to reach the V4-unique
    // CannotSweepPoolToken guard (which is only reachable as owner, before the
    // onlyOwner modifier passes control to the sweep logic).
    address constant PROXY_OWNER = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144;

    // -------------------------------------------------------------------------
    // Options helpers
    // -------------------------------------------------------------------------

    /// @dev Options for upgradeProxy calls.
    ///      referenceContract is set to match the V3 contract names so the OZ
    ///      upgrade validator can locate the prior storage layout in the build-info
    ///      directory.  On a clean V4-only build (forge clean && forge build) the
    ///      validator finds a single entry per name and succeeds.  On a build-info
    ///      directory that contains both V3 and V4 artifacts (e.g. the working-tree
    ///      sandbox), validateWithReference() will fail with "multiple contracts"
    ///      until a clean build is performed.
    ///
    ///      For the broadcast run, perform `forge clean && forge build` first to
    ///      ensure a single build-info entry per contract name.
    function _upgradeOpts(string memory refContract) private pure returns (Options memory opts) {
        opts.referenceContract = refContract;
        // unsafeAllowRenames: false (default) -- no variable was renamed in V4.
        // unsafeSkipStorageCheck: false (default) -- storage check is intentionally
        //   active; V4 only appends a new mapping at slot 17 in LoanRegistry.
        // unsafeSkipAllChecks: false (default) -- all constructor/initializer checks run.
    }

    /// @dev Options for validateImplementation (no referenceContract needed --
    ///      implementation-only checks do not require a storage layout comparison).
    function _implOpts() private pure returns (Options memory opts) {
        // All fields left at default (false/"").
    }

    /// @dev Options for validateWithReference using the pre-built V3 build-info
    ///      snapshot in previous-builds/out/build-info.
    function _refOpts(string memory refContract) private pure returns (Options memory opts) {
        // The directory short name is the last path segment of referenceBuildInfoDir.
        // For "previous-builds/out/build-info" the short name is "build-info".
        // The referenceContract must be prefixed with "<shortName>:" per Options.sol docs.
        opts.referenceBuildInfoDir = "previous-builds/out/build-info";
        opts.referenceContract = string(abi.encodePacked("build-info:", refContract));
    }

    // -------------------------------------------------------------------------
    // Entry point: production upgrade
    // -------------------------------------------------------------------------
    function run() external {
        _preUpgradeChecks();

        vm.startBroadcast();

        // --- Step 1: LoanRegistry (MUST be first) ----------------------------
        // LoanVault V4 and LiquidityPool V4 call getWasDefaulted(), which does
        // not exist in V3 LoanRegistry.  Upgrading LoanRegistry first prevents
        // a selector-not-found revert in the other two contracts' new code paths.
        console.log("Upgrading LoanRegistry...");
        Upgrades.upgradeProxy(
            LOAN_REGISTRY_PROXY,
            "LoanRegistry.sol:LoanRegistry",
            "",
            _upgradeOpts("LoanRegistry.sol:LoanRegistry")
        );
        console.log("  [OK] LoanRegistry proxy:   ", LOAN_REGISTRY_PROXY);
        console.log("  [OK] New implementation:   ", Upgrades.getImplementationAddress(LOAN_REGISTRY_PROXY));

        // --- Step 2: LoanVault -----------------------------------------------
        console.log("Upgrading LoanVault...");
        Upgrades.upgradeProxy(
            LOAN_VAULT_PROXY,
            "LoanVault.sol:LoanVault",
            "",
            _upgradeOpts("LoanVault.sol:LoanVault")
        );
        console.log("  [OK] LoanVault proxy:      ", LOAN_VAULT_PROXY);
        console.log("  [OK] New implementation:   ", Upgrades.getImplementationAddress(LOAN_VAULT_PROXY));

        // --- Step 3: LiquidityPool -------------------------------------------
        console.log("Upgrading LiquidityPool...");
        Upgrades.upgradeProxy(
            LIQUIDITY_POOL_PROXY,
            "LiquidityPool.sol:LiquidityPool",
            "",
            _upgradeOpts("LiquidityPool.sol:LiquidityPool")
        );
        console.log("  [OK] LiquidityPool proxy:  ", LIQUIDITY_POOL_PROXY);
        console.log("  [OK] New implementation:   ", Upgrades.getImplementationAddress(LIQUIDITY_POOL_PROXY));

        vm.stopBroadcast();

        _logPostUpgrade();
    }

    // -------------------------------------------------------------------------
    // Entry point: implementation-level validation only (no broadcast required)
    // -------------------------------------------------------------------------
    /// @notice Validates all three V4 implementation contracts for upgrade safety
    ///         (constructor guards, _disableInitializers, selfdestruct, delegatecall)
    ///         WITHOUT storage layout comparison and WITHOUT broadcasting.
    ///
    ///         This check runs cleanly in any environment (no clean build required).
    ///         It does NOT validate storage layout compatibility -- use
    ///         validateWithReference() for that.
    ///
    ///         Run with:
    ///           forge script script/UpgradeV4.s.sol:UpgradeV4Script \
    ///             --sig "validateImplementations()" --rpc-url arc_testnet
    function validateImplementations() external {
        Options memory opts = _implOpts();

        Upgrades.validateImplementation("LoanRegistry.sol:LoanRegistry", opts);
        console.log("[OK] LoanRegistry V4 - implementation-level checks passed.");

        Upgrades.validateImplementation("LoanVault.sol:LoanVault", opts);
        console.log("[OK] LoanVault V4   - implementation-level checks passed.");

        Upgrades.validateImplementation("LiquidityPool.sol:LiquidityPool", opts);
        console.log("[OK] LiquidityPool V4 - implementation-level checks passed.");

        console.log("");
        console.log("NOTE: storage-layout comparison not performed here.");
        console.log("Run validateWithReference() after building the V3 reference snapshot.");
    }

    // -------------------------------------------------------------------------
    // Entry point: full storage-layout validation with V3 reference
    // -------------------------------------------------------------------------
    /// @notice Validates storage layout compatibility for all three contracts,
    ///         comparing V4 against the V3 source snapshot in
    ///         previous-builds/out/build-info.
    ///
    ///         PREREQUISITES:
    ///           1. Build the V3 reference snapshot:
    ///                cd previous-builds && forge build
    ///              The V3 sources are already extracted to previous-builds/src/.
    ///           2. Run from the project root (not inside previous-builds/).
    ///
    ///         Run with:
    ///           forge script script/UpgradeV4.s.sol:UpgradeV4Script \
    ///             --sig "validateWithReference()" --rpc-url arc_testnet
    ///
    ///         If this fails with "referenceBuildInfoDir not found", run:
    ///           cd previous-builds && forge build && cd ..
    ///         then re-run.
    function validateWithReference() external {
        _validateWithRefOpts("LoanRegistry.sol:LoanRegistry");
        console.log("[OK] LoanRegistry V4 - storage layout compatible with V3.");

        _validateWithRefOpts("LoanVault.sol:LoanVault");
        console.log("[OK] LoanVault V4   - storage layout compatible with V3.");

        _validateWithRefOpts("LiquidityPool.sol:LiquidityPool");
        console.log("[OK] LiquidityPool V4 - storage layout compatible with V3.");
    }

    function _validateWithRefOpts(string memory contractName) private {
        Options memory opts = _refOpts(contractName);
        Upgrades.validateUpgrade(contractName, opts);
    }

    // -------------------------------------------------------------------------
    // Internal: pre-upgrade assertions
    // -------------------------------------------------------------------------
    /// @dev Reads the ERC-1967 implementation slot of each proxy and hard-reverts
    ///      if the current implementation is not the expected V3 address.
    ///
    ///      Rationale: a warning-only check would silently proceed even if the
    ///      proxy address constant is misconfigured or the proxy was already
    ///      upgraded by another transaction.  A hard revert guarantees that the
    ///      operator verifies the state before any transaction is broadcast.
    ///
    ///      If the proxy has legitimately been upgraded to a V3 patch release
    ///      not captured in the constants above, update the V3_IMPL constants
    ///      before broadcasting.
    function _preUpgradeChecks() internal view {
        address regImpl   = Upgrades.getImplementationAddress(LOAN_REGISTRY_PROXY);
        address vaultImpl = Upgrades.getImplementationAddress(LOAN_VAULT_PROXY);
        address poolImpl  = Upgrades.getImplementationAddress(LIQUIDITY_POOL_PROXY);

        if (regImpl != LOAN_REGISTRY_V3_IMPL) {
            revert(
                string(abi.encodePacked(
                    "ABORT: LoanRegistry proxy is not at expected V3 impl.\n",
                    "  Expected: 0xd47496361e5C485611718BD06065971691D2ba07\n",
                    "  Actual:   use `cast implementation ",
                    _toHexString(LOAN_REGISTRY_PROXY),
                    " --rpc-url arc_testnet` to verify.\n",
                    "Update LOAN_REGISTRY_V3_IMPL if a later V3 patch is deployed."
                ))
            );
        }
        console.log("[OK] LoanRegistry proxy is at expected V3 impl:   ", regImpl);

        if (vaultImpl != LOAN_VAULT_V3_IMPL) {
            revert(
                string(abi.encodePacked(
                    "ABORT: LoanVault proxy is not at expected V3 impl.\n",
                    "  Expected: 0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537\n",
                    "  Actual:   use `cast implementation ",
                    _toHexString(LOAN_VAULT_PROXY),
                    " --rpc-url arc_testnet` to verify.\n",
                    "Update LOAN_VAULT_V3_IMPL if a later V3 patch is deployed."
                ))
            );
        }
        console.log("[OK] LoanVault proxy is at expected V3 impl:       ", vaultImpl);

        if (poolImpl != LIQUIDITY_POOL_PRE_V4_IMPL) {
            revert(
                string(abi.encodePacked(
                    "ABORT: LiquidityPool proxy is not at expected pre-V4 impl.\n",
                    "  Expected: 0x828525794b195329e8F1aE501A61d7590df542c1\n",
                    "  Actual:   use `cast implementation ",
                    _toHexString(LIQUIDITY_POOL_PROXY),
                    " --rpc-url arc_testnet` to verify.\n",
                    "Update LIQUIDITY_POOL_PRE_V4_IMPL if a later pre-V4 patch was deployed."
                ))
            );
        }
        console.log("[OK] LiquidityPool proxy is at expected pre-V4 impl:", poolImpl);
    }

    // -------------------------------------------------------------------------
    // Entry point: partial-failure recovery
    // -------------------------------------------------------------------------
    /// @notice Resumes a partially-completed V4 upgrade.
    ///
    ///         Use this entry point INSTEAD of run() when at least one proxy was
    ///         already upgraded in a previous partial broadcast.  run() will abort
    ///         in that state because _preUpgradeChecks() hard-reverts on any impl
    ///         that is not the expected V3 address.
    ///
    ///         Per-proxy logic (in V4 ordering: Registry → Vault → Pool):
    ///           1. If the proxy is at the known V3 impl address → upgrade to V4.
    ///           2. If the V4 selector probe confirms V4 is live  → skip (already done).
    ///           3. Anything else                                 → hard-abort.
    ///              The operator must investigate before proceeding.
    ///
    ///         LiquidityPool has no fixed V3 impl constant (prior post-V2 patch
    ///         was applied without recording the impl address).  It uses only the
    ///         V4 selector probe and the unconditional upgrade fallback.
    ///
    ///         Run with:
    ///           forge script script/UpgradeV4.s.sol \
    ///             --sig "resume()" \
    ///             --rpc-url arc_testnet --account valen-deployer --broadcast
    function resume() external {
        bool anyUpgraded = false;

        vm.startBroadcast();

        // --- LoanRegistry ---------------------------------------------------
        {
            address impl = Upgrades.getImplementationAddress(LOAN_REGISTRY_PROXY);
            if (impl == LOAN_REGISTRY_V3_IMPL) {
                console.log("[RESUME] LoanRegistry: at V3 impl, upgrading...");
                Upgrades.upgradeProxy(
                    LOAN_REGISTRY_PROXY,
                    "LoanRegistry.sol:LoanRegistry",
                    "",
                    _upgradeOpts("LoanRegistry.sol:LoanRegistry")
                );
                console.log("  [OK] LoanRegistry upgraded to V4:", Upgrades.getImplementationAddress(LOAN_REGISTRY_PROXY));
                anyUpgraded = true;
            } else if (_probeRegistryV4(LOAN_REGISTRY_PROXY)) {
                console.log("[RESUME] LoanRegistry: V4 already live, skipping. impl:", impl);
            } else {
                revert(string(abi.encodePacked(
                    "ABORT: LoanRegistry is at an unexpected impl address.\n",
                    "  Current impl: ", _toHexString(impl), "\n",
                    "  Expected V3:  0xd47496361e5C485611718BD06065971691D2ba07\n",
                    "  V4 probe:     failed (getWasDefaulted selector not found).\n",
                    "Investigate before proceeding."
                )));
            }
        }

        // --- LoanVault ------------------------------------------------------
        {
            address impl = Upgrades.getImplementationAddress(LOAN_VAULT_PROXY);
            if (impl == LOAN_VAULT_V3_IMPL) {
                console.log("[RESUME] LoanVault: at V3 impl, upgrading...");
                Upgrades.upgradeProxy(
                    LOAN_VAULT_PROXY,
                    "LoanVault.sol:LoanVault",
                    "",
                    _upgradeOpts("LoanVault.sol:LoanVault")
                );
                console.log("  [OK] LoanVault upgraded to V4:", Upgrades.getImplementationAddress(LOAN_VAULT_PROXY));
                anyUpgraded = true;
            } else if (_probeVaultV4(LOAN_VAULT_PROXY)) {
                console.log("[RESUME] LoanVault: V4 already live, skipping. impl:", impl);
            } else {
                revert(string(abi.encodePacked(
                    "ABORT: LoanVault is at an unexpected impl address.\n",
                    "  Current impl: ", _toHexString(impl), "\n",
                    "  Expected V3:  0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537\n",
                    "  V4 probe:     failed (NotAuthorized selector not found).\n",
                    "Investigate before proceeding."
                )));
            }
        }

        // --- LiquidityPool --------------------------------------------------
        // V3 and V4 LiquidityPool have identical public ABIs from a non-owner
        // perspective (same selectors, same auth errors for non-owner callers).
        // The only ABI-visible V4 distinction is CannotSweepPoolToken(), which
        // is only reachable by the owner.  _probePoolV4 impersonates the owner
        // (vm.prank) and staticcalls sweepToken(usdc, address(this)):
        //   V4: reverts CannotSweepPoolToken() before touching state → probe true.
        //   V3: passes auth, attempts emit TokenSwept (state change) under
        //       staticcall → EVM staticcall violation → empty revert → probe false.
        //   Unknown impl: empty revert or ok=true → probe false → abort.
        {
            address impl = Upgrades.getImplementationAddress(LIQUIDITY_POOL_PROXY);
            if (impl == LIQUIDITY_POOL_PRE_V4_IMPL) {
                console.log("[RESUME] LiquidityPool: at pre-V4 impl, upgrading...");
                Upgrades.upgradeProxy(
                    LIQUIDITY_POOL_PROXY,
                    "LiquidityPool.sol:LiquidityPool",
                    "",
                    _upgradeOpts("LiquidityPool.sol:LiquidityPool")
                );
                console.log("  [OK] LiquidityPool upgraded:", Upgrades.getImplementationAddress(LIQUIDITY_POOL_PROXY));
                anyUpgraded = true;
            } else if (_probePoolV4(LIQUIDITY_POOL_PROXY)) {
                console.log("[RESUME] LiquidityPool: V4 already live, skipping. impl:", impl);
            } else {
                revert(string(abi.encodePacked(
                    "ABORT: LiquidityPool is at an unexpected impl address.\n",
                    "  Current impl: ", _toHexString(impl), "\n",
                    "  Expected pre-V4: 0x828525794b195329e8F1aE501A61d7590df542c1\n",
                    "  V4 probe:     failed (CannotSweepPoolToken not reachable as owner).\n",
                    "Investigate before proceeding."
                )));
            }
        }

        vm.stopBroadcast();

        if (!anyUpgraded) {
            console.log("");
            console.log("[RESUME] All three proxies are already on V4.  Nothing to do.");
            console.log("If this is unexpected, verify impl addresses with cast implementation.");
        } else {
            _logPostUpgrade();
        }
    }

    // -------------------------------------------------------------------------
    // Internal: V4 selector probes
    // -------------------------------------------------------------------------
    // Each probe staticcalls a function that exists ONLY on V4 (not V3) and
    // checks whether the call reverts with a recognizable revert (any revert
    // except the Solidity fallback-not-found 0x selector revert).  A V3 proxy
    // will revert because the selector does not exist in its dispatch table and
    // the fallback returns an empty revert; a V4 proxy will either return data
    // or revert with a named error — both are distinguishable from a missing
    // selector.
    //
    // Note: these probes require the Foundry vm cheatcode (vm.load) and are
    // safe to call inside a broadcast block (staticcall — no state change).

    /// @dev Probes LoanRegistry for V4 by calling getWasDefaulted(0).
    ///      V3: reverts with empty data (selector not found).
    ///      V4: returns false (0x00...00) — no revert.
    function _probeRegistryV4(address proxy) internal view returns (bool) {
        // getWasDefaulted(uint256) → bool: returns 32 bytes on V4, reverts (empty)
        // on V3 (selector absent), and returns 0 bytes if proxy delegates to a
        // non-contract address — we treat 0 bytes as "not V4".
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("getWasDefaulted(uint256)", uint256(0))
        );
        return ok && data.length >= 32;
    }

    /// @dev Probes LoanVault for V4 by calling fundFromPool(0) from address(this).
    ///      V3: reverts OwnableUnauthorizedAccount (0x118cdaa7) — fundFromPool had
    ///          onlyOwner in V3; address(this) is not owner so it reverts with the
    ///          OZ OwnableUnauthorizedAccount error.
    ///      V4: reverts NotAuthorized (0xea8e4eb5) — fundFromPool switched from
    ///          onlyOwner to an owner-or-keeper check that uses the custom error.
    ///      EOA impl: staticcall to a non-contract target returns ok=true, 0 bytes.
    ///          The EVM DELEGATECALL to a non-contract succeeds silently.  We treat
    ///          ok=true as "not V4" because fundFromPool is state-mutating and any
    ///          real contract will always revert under staticcall.
    ///      Unknown contract: reverts with unrecognized selector → data.length < 4
    ///          or data.length >= 4 with non-NotAuthorized selector → returns false.
    function _probeVaultV4(address proxy) internal view returns (bool) {
        // fundFromPool is state-mutating; a staticcall to it will always revert
        // on any real contract (state change denied or auth check).  A non-contract
        // address (EOA) causes the EVM to return ok=true with 0 bytes — we must
        // NOT treat that as V4.  Therefore ok=true is "not V4" here.
        //
        // Selector table:
        //   NotAuthorized()                      = 0xea8e4eb5  (V4 — probe passes)
        //   OwnableUnauthorizedAccount(address)  = 0x118cdaa7  (V3 — probe fails)
        //   Non-contract (EOA)                   = ok=true     (probe fails)
        //   Unknown contract / empty revert      = data < 4   (probe fails)
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("fundFromPool(uint256)", uint256(0))
        );
        if (ok) return false; // DELEGATECALL to non-contract (EOA): not V4
        // V4 NotAuthorized(): bytes4(keccak256("NotAuthorized()")) = 0xea8e4eb5
        if (data.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            return sel == bytes4(keccak256("NotAuthorized()"));
        }
        return false;
    }

    /// @dev Probes LiquidityPool for V4 by calling sweepToken(usdc, recipient)
    ///      impersonating the proxy owner (vm.prank).
    ///
    ///      Background: V3 and V4 LiquidityPool have identical public ABIs from a
    ///      non-owner caller — both have sweepToken(address,address) with onlyOwner,
    ///      so a non-owner staticcall returns OwnableUnauthorizedAccount on both
    ///      versions.  The only ABI-visible V4 distinction is the CannotSweepPoolToken
    ///      guard, which fires ONLY when called as the owner with token == usdc.
    ///
    ///      Probe mechanics (owner call via vm.prank, then staticcall):
    ///        V4: onlyOwner passes; token == usdc → revert CannotSweepPoolToken()
    ///            selector = bytes4(keccak256("CannotSweepPoolToken()")) = 0x5df0d80e
    ///            The revert happens BEFORE any state change → staticcall succeeds in
    ///            delivering the revert data.
    ///        V3: onlyOwner passes; no CannotSweepPoolToken guard; reaches
    ///            IERC20(usdc).balanceOf(...) (view — ok), then `if (bal > 0)` (bal is
    ///            likely > 0 on testnet, but even with bal==0 the emit fires).
    ///            emit TokenSwept(...)  ← LOG opcode = state change → EVM staticcall
    ///            protection kicks in and reverts with empty data.
    ///            Even if bal == 0 and the emit branch is skipped, the function returns
    ///            void (no return value) so ok=true with 0 bytes → probe returns false.
    ///        Unknown contract: empty revert (no selector) → data.length < 4 → false.
    ///        EOA impl: DELEGATECALL to non-contract → ok=true, 0 bytes → false.
    ///
    ///      vm.prank is a Foundry cheatcode available inside forge script — it sets
    ///      msg.sender for the next external call only and does not broadcast a tx.
    ///      It is safe to use inside a view-like probe within a broadcast block.
    function _probePoolV4(address proxy) internal returns (bool) {
        // Impersonate the proxy owner so onlyOwner passes and the probe reaches
        // the V4-unique CannotSweepPoolToken guard.
        address usdc = 0x3600000000000000000000000000000000000000;
        vm.prank(PROXY_OWNER);
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("sweepToken(address,address)", usdc, address(this))
        );
        // EOA impl or V3 with bal==0 (emit skipped): ok=true, 0 bytes → not V4.
        if (ok) return false;
        // CannotSweepPoolToken(): bytes4(keccak256("CannotSweepPoolToken()")) = 0x5df0d80e
        if (data.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            return sel == bytes4(keccak256("CannotSweepPoolToken()"));
        }
        // data.length < 4: empty revert (unknown contract, V3 with LOG staticcall
        // violation, or unknown error) → not V4.
        return false;
    }

    // -------------------------------------------------------------------------
    // Internal: post-upgrade log
    // -------------------------------------------------------------------------
    function _logPostUpgrade() internal pure {
        console.log("");
        console.log("=== V4 UPGRADE COMPLETE ===");
        console.log("");
        console.log("REQUIRED MANUAL STEPS:");
        console.log("");
        console.log("1. Verify implementation slots (all three must show new addresses):");
        console.log("   cast implementation 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d --rpc-url arc_testnet");
        console.log("   cast implementation 0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19 --rpc-url arc_testnet");
        console.log("   cast implementation 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 --rpc-url arc_testnet");
        console.log("");
        console.log("2. Confirm V4 selectors are live:");
        console.log("   cast call 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d 'getWasDefaulted(uint256)(bool)' 0 --rpc-url arc_testnet");
        console.log("   -- expected: false");
        console.log("");
        console.log("3. Update backend/src/routes/prepare.ts:");
        console.log("   - Switch LoanRegistryDeployedAbi -> LoanRegistryAbi");
        console.log("   - Remove directDisbursement rejection guard (lines 60-65)");
        console.log("   - Add collateral+directDisbursement policy validation");
        console.log("");
        console.log("4. Update backend/src/abis/LoanVault.ts:");
        console.log("   - Add LoanNotDefaulted error entry");
        console.log("   - Add NotAuthorized error entry");
        console.log("   - Retain LoanNotActive (still used by fundLoan/releaseMilestone)");
        console.log("");
        console.log("5. Register keeper:");
        console.log("   cast send 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d 'setKeeper(address,bool)' <KEEPER_ADDR> true");
        console.log("   --account valen-deployer --rpc-url arc_testnet");
    }

    // -------------------------------------------------------------------------
    // Internal: address-to-hex helper (avoids console.log type mismatch)
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


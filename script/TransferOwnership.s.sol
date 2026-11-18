// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

// =============================================================================
// TransferOwnership.s.sol
// =============================================================================
//
// PURPOSE
// -------
// Transfers ownership of all 11 Valen UUPS proxy contracts from the deployer
// EOA to a 2-of-3 Safe multisig, remediating audit finding C-01
// (Single EOA Controls the Entire Protocol).
//
// All contracts use OwnableUpgradeable (OZ v5.7.0), which implements
// SINGLE-STEP ownership transfer.  transferOwnership(newOwner) takes effect
// immediately in the same transaction; no acceptOwnership() call from the
// new owner is required.
//
// PREREQUISITES (must be completed before filling in any address constant)
// -------------------------------------------------------------------------
//   1. Deploy a Safe on Arc Testnet using:
//        - SafeProxyFactory v1.4.1: 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
//        - Safe L2 singleton v1.4.1: 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
//        - CompatibilityFallbackHandler: 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
//        - Threshold: 2, Owners: [SIGNER_1, SIGNER_2, SIGNER_3]
//
//   2. Verify the deployed Safe independently (see SAFE VERIFICATION below).
//
//   3. Fill in SAFE_ADDRESS, SIGNER_1, SIGNER_2, SIGNER_3 below.
//
//   4. Run preflightChecks() WITHOUT --broadcast:
//        forge script script/TransferOwnership.s.sol \
//          --sig "preflightChecks()" \
//          --rpc-url https://rpc.testnet.arc.io
//      All checks must pass before broadcasting.
//
//   5. Dry-run WITHOUT --broadcast to inspect calldata:
//        forge script script/TransferOwnership.s.sol \
//          --rpc-url https://rpc.testnet.arc.io \
//          --account valen-deployer
//
//   6. Spot-check calldata encoding for at least two proxies:
//        cast calldata "transferOwnership(address)" <SAFE_ADDRESS>
//      Selector must be 0xf2fde38b; next 32 bytes must be the Safe address.
//
//   7. Confirm deployer EOA holds sufficient Arc Testnet USDC for gas
//      (~300,000 gas total for 11 transactions at current gas price).
//
// SAFE VERIFICATION
// -----------------
// Before filling in SAFE_ADDRESS, confirm ALL of the following on-chain.
// Steps (a)–(e) are manual; steps (f)–(g) are also checked by preflightChecks().
//
//   a) Safe has contract code:
//        cast code <SAFE> --rpc-url https://rpc.testnet.arc.io
//        Expected: non-empty bytecode
//
//   b) Confirm the Safe was deployed FROM the canonical SafeProxyFactory:
//        Look up the deployment transaction on https://explorer.testnet.arc.io
//        and confirm the creating contract is SafeProxyFactory v1.4.1:
//        0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
//        This is the strongest provenance check available and cannot be
//        replicated within the script itself (requires log queries).
//
//   c) Inspect the contract source on the explorer and confirm it matches
//        the canonical Safe proxy source (github.com/safe-global/safe-smart-account).
//        This is the only way to obtain bytecode-level proof.
//
//   d) Threshold is exactly 2:
//        cast call <SAFE> "getThreshold()(uint256)" --rpc-url ...
//        Expected: 2
//
//   e) Owner count is exactly 3 and owners match the three signers:
//        cast call <SAFE> "getOwners()(address[])" --rpc-url ...
//        Expected: array containing exactly SIGNER_1, SIGNER_2, SIGNER_3
//
//   f) Slot-0 raw storage holds the L2 v1.4.1 singleton (checked by script):
//        cast storage <SAFE> 0 --rpc-url ...
//        Expected (right-padded): 0x00000000000000000000000029fcB43b46531BcA003ddC8FCB67FFE91900C762
//
//   g) masterCopy() ABI return agrees with slot 0 (checked by script):
//        cast call <SAFE> "masterCopy()(address)" --rpc-url ...
//        Expected: 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
//
//      WHAT THE SCRIPT CHECKS AND WHAT IT CANNOT PROVE
//      The script's preflightChecks() checks (f) and (g) independently and
//      asserts they agree.  Together they confirm slot 0 and the ABI both
//      report the expected singleton.  They do NOT prove the contract is
//      genuine Safe bytecode — a purpose-built contract could satisfy both.
//      Manual steps (b) and (c) are the authoritative proof of authenticity.
//
//      WHAT CANNOT BE CHECKED WITHOUT A DEPLOYED SAFE INSTANCE
//      The singleton at 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762 on Arc
//      Testnet was verified via eth_getCode (24,421 bytes) in the audit session.
//      Until a Safe proxy is deployed, checks (f) and (g) cannot run.
//
// BROADCAST COMMAND (only after all prerequisites pass)
// -----------------------------------------------------
//   forge script script/TransferOwnership.s.sol \
//     --rpc-url https://rpc.testnet.arc.io \
//     --account valen-deployer \
//     --broadcast
//
// PARTIAL FAILURE RECOVERY
// ------------------------
// If the broadcast fails partway (RPC timeout, gas, nonce gap):
//   1. Do NOT re-run run() -- its preflight requires ALL proxies to be at
//      DEPLOYER, which will fail for any already-transferred proxy.
//   2. Run verifyTransfer() (read-only) to see which proxies transferred.
//   3. Run resume() dry-run first (no --broadcast), then broadcast.
//      resume() skips already-transferred proxies, transfers remaining
//      deployer-owned proxies, and aborts on any unexpected owner.
//
// POST-MIGRATION FUNCTIONAL TEST
// --------------------------------
// After verifyTransfer() confirms all 11 proxies, execute ONE owner-gated
// Safe transaction to confirm the Safe can call protocol functions:
//   - Propose RecipientRegistry.approveRecipient(<testAddr>, 0x0, "test")
//   - Collect 2-of-3 signatures
//   - Execute, then verify on-chain with cast call
//   - Optionally revoke the test recipient to leave the registry clean
//
// OPERATIONAL NOTES POST-MIGRATION
// ---------------------------------
// - All onlyOwner functions across 11 contracts require Safe transactions.
// - fundFromPool: the deployer may register a keeper via LoanRegistry.setKeeper
//   (one Safe tx) to allow an EOA to call fundFromPool without Safe co-signing.
// - releaseMilestone (pool-funded milestone loans): requires the Safe as caller.
//   No keeper bypass exists for this path. This affects only pool loans with
//   directDisbursement=false; all collateral-backed loans use directDisbursement=true.
// - Upgrades: build/validate locally as before; ABI-encode upgradeToAndCall
//   calldata and propose as a Safe transaction.
//
// =============================================================================

/// @dev Minimal interface for OpenZeppelin OwnableUpgradeable (v5.x).
///      transferOwnership is single-step in OZ v5: the new owner is set
///      immediately; no acceptOwnership() call is required.
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @dev Minimal interface for Safe v1.3.x / v1.4.x proxy contracts.
///      masterCopy() returns the singleton address (stored at slot 0 of the
///      proxy).  getThreshold() and getOwners() are standard Safe functions.
///
///      LIMITATION: These three functions can be implemented by any contract.
///      Passing all three checks does not prove the address is genuine Safe code.
///      The script adds a raw slot-0 cross-check (vm.load) independent of the ABI,
///      but bytecode-level proof requires manual inspection on the explorer.
///      See SAFE VERIFICATION in the file header for the full manual checklist.
interface ISafe {
    function masterCopy() external view returns (address);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

contract TransferOwnershipScript is Script {

    // =========================================================================
    // ADDRESS CONSTANTS — fill in AFTER the Safe is deployed and verified.
    // =========================================================================
    // ALL FOUR of these are intentional address(0) placeholders.
    // preflightChecks() reverts immediately if any is still address(0).
    // Do not fill these in until Phase A of the execution checklist is complete.

    /// @dev The deployed 2-of-3 Safe proxy address.  Set after Safe deployment.
    address constant SAFE_ADDRESS = address(0);

    /// @dev Signer 1 — laptop wallet.  Set to the verified public address.
    address constant SIGNER_1 = address(0);

    /// @dev Signer 2 — phone wallet.  Set to the verified public address.
    address constant SIGNER_2 = address(0);

    /// @dev Signer 3 — sister's independently controlled wallet.  Set to
    ///      the verified public address (confirmed in person or by simultaneous
    ///      display, never via a text channel where it could be altered).
    address constant SIGNER_3 = address(0);

    // =========================================================================
    // FIXED CONSTANTS — do not change these.
    // =========================================================================

    /// @dev Current owner of all 11 proxies (deployer EOA, Arc Testnet).
    address constant DEPLOYER = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144;

    /// @dev Expected Safe L2 singleton (v1.4.1) on Arc Testnet.
    ///      Verified deployed at this address via eth_getCode (24,421 bytes).
    address constant EXPECTED_SAFE_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    // =========================================================================
    // PROXY ADDRESS CONSTANTS
    // All 11 proxy addresses verified on-chain against DEPLOYER as owner().
    // Sources: on-chain eth_call + upgrade scripts UpgradeV4.s.sol and
    //          UpgradeRevenueRouter.s.sol.
    // =========================================================================
    address constant AGENT_REGISTRY   = 0xeC74944752Fff0f53Af5b727F288f59435C0144e;
    address constant CREDIT_REGISTRY  = 0x258B0678b30E2d32034389cfeCa7f58fE1CeB897;
    address constant LOAN_REGISTRY    = 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d;
    address constant REVENUE_ROUTER   = 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822;
    address constant LOAN_VAULT       = 0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19;
    address constant COLLATERAL_VAULT = 0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f;
    address constant UNDERWRITER_POOL = 0x23307d061dad8335995080518B73A839Ffe69E7A;
    address constant RECIPIENT_REG    = 0xf8E069B659CEAf9c68318041D727b5c482Ac6374;
    address constant RESERVE_POOL     = 0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD;
    address constant LIQUIDITY_POOL   = 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061;
    address constant ACTIVITY_ATTESTER = 0x2660044E4A7316B65263ea1B23b80aAf09841196;

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /// @dev Returns the list of all 11 proxy addresses in deployment order.
    function _proxies() internal pure returns (address[11] memory) {
        return [
            AGENT_REGISTRY,
            CREDIT_REGISTRY,
            LOAN_REGISTRY,
            REVENUE_ROUTER,
            LOAN_VAULT,
            COLLATERAL_VAULT,
            UNDERWRITER_POOL,
            RECIPIENT_REG,
            RESERVE_POOL,
            LIQUIDITY_POOL,
            ACTIVITY_ATTESTER
        ];
    }

    /// @dev Human-readable name for each proxy (same order as _proxies()).
    function _proxyName(uint256 i) internal pure returns (string memory) {
        if (i == 0)  return "AgentRegistry";
        if (i == 1)  return "CreditRegistry";
        if (i == 2)  return "LoanRegistry";
        if (i == 3)  return "RevenueRouter";
        if (i == 4)  return "LoanVault";
        if (i == 5)  return "CollateralVault";
        if (i == 6)  return "UnderwriterPool";
        if (i == 7)  return "RecipientRegistry";
        if (i == 8)  return "ReservePool";
        if (i == 9)  return "LiquidityPool";
        if (i == 10) return "ActivityAttester";
        return "Unknown";
    }

    /// @dev Returns true if `needle` is present in `haystack`.
    function _contains(address[] memory haystack, address needle)
        internal pure returns (bool)
    {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    // -------------------------------------------------------------------------
    // preflightChecks()
    // -------------------------------------------------------------------------
    // Run WITHOUT --broadcast before any ownership transfer.
    // Reverts immediately on the first failed check with a descriptive message.
    // All checks must pass before run() is called.
    //
    //   forge script script/TransferOwnership.s.sol \
    //     --sig "preflightChecks()" \
    //     --rpc-url https://rpc.testnet.arc.io
    // -------------------------------------------------------------------------
    function preflightChecks() external view {
        _checkSafe();
        _checkProxies();
        console.log("");
        console.log("[OK] All preflight checks passed. Safe to broadcast run().");
    }

    // -------------------------------------------------------------------------
    // run()
    // -------------------------------------------------------------------------
    // Transfers ownership of all 11 proxies to SAFE_ADDRESS.
    // Performs all preflight checks before any transaction is sent.
    // If ANY check fails, the script aborts before vm.startBroadcast().
    //
    // DO NOT re-run after a partial failure -- use resume() instead.
    //
    //   forge script script/TransferOwnership.s.sol \
    //     --rpc-url https://rpc.testnet.arc.io \
    //     --account valen-deployer \
    //     --broadcast
    // -------------------------------------------------------------------------
    function run() external {
        // All checks run before any transaction is submitted.
        _checkSafe();
        _checkProxies();

        console.log("");
        console.log("All preflight checks passed. Broadcasting 11 transferOwnership calls...");
        console.log("");

        vm.startBroadcast();
        _transferAll();
        vm.stopBroadcast();

        console.log("");
        console.log("Broadcast complete. Verifying post-transfer state...");
        _assertAllTransferred();
    }

    // -------------------------------------------------------------------------
    // resume()
    // -------------------------------------------------------------------------
    // Recovery entry point for use ONLY after a partial failure in run().
    // Scans all 11 proxies independently before broadcasting anything:
    //   - owner == SAFE_ADDRESS  -> skip (already transferred)
    //   - owner == DEPLOYER      -> queue for transfer
    //   - owner == anything else -> ABORT (unexpected state, investigate first)
    //
    // If all 11 are already at SAFE_ADDRESS, exits cleanly with no broadcast.
    //
    //   forge script script/TransferOwnership.s.sol \
    //     --sig "resume()" \
    //     --rpc-url https://rpc.testnet.arc.io \
    //     --account valen-deployer \
    //     --broadcast
    // -------------------------------------------------------------------------
    function resume() external {
        // Safe checks must still pass -- if the Safe itself has changed, abort.
        _checkSafe();

        address[11] memory p = _proxies();
        bool[11] memory needsTransfer;
        uint256 pendingCount;
        uint256 doneCount;

        // ---------------------------------------------------------------
        // Phase 1: SCAN — read every proxy owner before any transaction.
        // Abort immediately on any unexpected owner.
        // This mirrors the harness resume() in test/TransferOwnership.t.sol.
        // ---------------------------------------------------------------
        console.log("Phase 1: scanning all proxy owners (no transactions yet)...");
        console.log("");

        for (uint256 i = 0; i < 11; i++) {
            address current = IOwnable(p[i]).owner();
            string memory name = _proxyName(i);

            if (current == SAFE_ADDRESS) {
                console.log("  [SKIP]    ", name, "already at Safe");
                doneCount++;
            } else if (current == DEPLOYER) {
                console.log("  [PENDING] ", name, "will be transferred");
                needsTransfer[i] = true;
                pendingCount++;
            } else {
                // Unexpected owner: abort before any transaction is broadcast.
                revert(string(abi.encodePacked(
                    "ABORT: ", name, " has unexpected owner ",
                    _toHexString(current),
                    ". Manual investigation required before proceeding.",
                    " Do not re-run until the unexpected owner is understood."
                )));
            }
        }

        console.log("");
        console.log("Summary: already transferred =", doneCount);
        console.log("Summary: pending transfer    =", pendingCount);

        if (pendingCount == 0) {
            console.log("");
            console.log("[OK] Migration already complete. No broadcast needed.");
            return;
        }

        // ---------------------------------------------------------------
        // Phase 2: TRANSFER — broadcast only after scan passes cleanly.
        // ---------------------------------------------------------------
        console.log("Phase 2: broadcasting pending transferOwnership calls, count =", pendingCount);
        console.log("");

        vm.startBroadcast();
        for (uint256 i = 0; i < 11; i++) {
            if (needsTransfer[i]) {
                IOwnable(p[i]).transferOwnership(SAFE_ADDRESS);
                console.log("  Transferred:", _proxyName(i));
            }
        }
        vm.stopBroadcast();

        console.log("");
        console.log("Broadcast complete. Verifying post-transfer state...");
        _assertAllTransferred();
    }

    // -------------------------------------------------------------------------
    // verifyTransfer()
    // -------------------------------------------------------------------------
    // Read-only verification of post-migration state.
    // Reads owner() for all 11 proxies and asserts each equals SAFE_ADDRESS.
    // This is a confirmed on-chain result, not a simulation.
    //
    // Run after broadcast:
    //   forge script script/TransferOwnership.s.sol \
    //     --sig "verifyTransfer()" \
    //     --rpc-url https://rpc.testnet.arc.io
    //
    // A passing result here is confirmed on-chain state.  Cross-check by
    // inspecting OwnershipTransferred events on https://explorer.testnet.arc.io
    // for each proxy address.  The functional test (approveRecipient via Safe)
    // must also pass before declaring the migration complete.
    // -------------------------------------------------------------------------
    function verifyTransfer() external view {
        require(SAFE_ADDRESS != address(0), "SAFE_ADDRESS not set");
        _assertAllTransferred();
    }

    // =========================================================================
    // INTERNAL IMPLEMENTATION
    // =========================================================================

    /// @dev Validates the Safe address and its configuration.
    ///      Checks (in order):
    ///        A. SAFE_ADDRESS is not a placeholder
    ///        B. All three signer constants are not placeholders
    ///        C. Safe has contract code (is not an EOA)
    ///        D1. Raw slot-0 storage equals EXPECTED_SAFE_SINGLETON (independent of ABI)
    ///        D2. masterCopy() ABI return equals EXPECTED_SAFE_SINGLETON (cross-check)
    ///        E. Safe threshold is exactly 2
    ///        F. Safe owner list is exactly {SIGNER_1, SIGNER_2, SIGNER_3}
    ///
    ///      WHAT THESE CHECKS PROVE AND DO NOT PROVE
    ///      ------------------------------------------
    ///      Checks D1 + D2 together confirm that:
    ///        - Slot 0 of the proxy holds the expected singleton address.
    ///        - The ABI call masterCopy() also returns that address.
    ///      A genuine SafeProxy v1.4.1 stores its singleton at slot 0 and exposes
    ///      it via masterCopy().  Both returning the correct value is strong evidence
    ///      of correct deployment, but it is not bytecode-level proof.
    ///
    ///      A sophisticated attacker who controls the SAFE_ADDRESS could deploy a
    ///      contract that returns correct values from all calls in this function.
    ///      The defence against this is the MANUAL verification checklist in the
    ///      file header (explorer code inspection, factory deployment tx confirmation)
    ///      BEFORE filling in the SAFE_ADDRESS constant.  These on-chain checks are
    ///      a gate for operator error, not a substitute for manual pre-flight review.
    ///
    ///      SLOT-0 CHECK REQUIRES --rpc-url
    ///      vm.load performs eth_getStorageAt against the live chain when this
    ///      script is run with --rpc-url.
    ///
    ///      TEST COVERAGE OF THIS FUNCTION
    ///      Because SAFE_ADDRESS and the signer constants are address(0)
    ///      compile-time constants, no local test can run this function past
    ///      check A.  Checks C, D1, D2, E and F in this contract are NOT
    ///      executed by any test; the harness in test/TransferOwnership.t.sol
    ///      mirrors C, D2, E and F (not D1) with separate code.  Checks D1/D2
    ///      first execute against a real Safe during the live dry-run
    ///      (preflightChecks() with --rpc-url) after the constants are filled in.
    function _checkSafe() internal view {
        // A. SAFE_ADDRESS placeholder guard
        require(
            SAFE_ADDRESS != address(0),
            "ABORT: SAFE_ADDRESS is address(0). Fill in after Safe deployment and verification."
        );

        // B. Signer placeholder guards
        require(
            SIGNER_1 != address(0),
            "ABORT: SIGNER_1 is address(0). Fill in the verified signer address."
        );
        require(
            SIGNER_2 != address(0),
            "ABORT: SIGNER_2 is address(0). Fill in the verified signer address."
        );
        require(
            SIGNER_3 != address(0),
            "ABORT: SIGNER_3 is address(0). Fill in the verified signer address."
        );

        // C. Safe must be a contract
        require(
            SAFE_ADDRESS.code.length > 0,
            "ABORT: SAFE_ADDRESS has no contract code. Verify the address and network."
        );

        // D1. Raw slot-0 cross-check (independent of ABI).
        //     SafeProxy v1.3.x / v1.4.x stores the singleton address at storage
        //     slot 0 verbatim.  vm.load reads this via eth_getStorageAt — it does
        //     not go through the contract's ABI and cannot be spoofed by a
        //     masterCopy() override alone.  A contract that correctly returns
        //     EXPECTED_SAFE_SINGLETON from slot 0 AND from masterCopy() is
        //     consistent with genuine Safe proxy bytecode.
        bytes32 slot0 = vm.load(SAFE_ADDRESS, bytes32(0));
        address singletonFromSlot = address(uint160(uint256(slot0)));
        require(
            singletonFromSlot == EXPECTED_SAFE_SINGLETON,
            string(abi.encodePacked(
                "ABORT: Slot-0 singleton mismatch. Expected ",
                _toHexString(EXPECTED_SAFE_SINGLETON),
                " but slot 0 contains ",
                _toHexString(singletonFromSlot),
                ". The address is not a SafeProxy v1.4.1 or was deployed with the wrong singleton."
            ))
        );
        console.log("  [OK] Slot-0 singleton (raw storage):", singletonFromSlot);

        // D2. ABI cross-check: masterCopy() must agree with slot-0.
        //     masterCopy() (selector 0xa619486e) is the canonical Safe-published
        //     interface for reading the singleton on v1.3.x / v1.4.x proxies.
        //     Both D1 and D2 must pass; disagreement between them indicates a
        //     non-standard proxy that should be investigated before proceeding.
        address singletonFromABI = ISafe(SAFE_ADDRESS).masterCopy();
        require(
            singletonFromABI == EXPECTED_SAFE_SINGLETON,
            string(abi.encodePacked(
                "ABORT: masterCopy() singleton mismatch. Expected ",
                _toHexString(EXPECTED_SAFE_SINGLETON),
                " (L2 v1.4.1) but got ",
                _toHexString(singletonFromABI),
                ". Confirm the Safe was deployed on Arc Testnet with the L2 singleton."
            ))
        );
        require(
            singletonFromSlot == singletonFromABI,
            "ABORT: Slot-0 and masterCopy() disagree on singleton address. Non-standard proxy, do not proceed."
        );
        console.log("  [OK] masterCopy() singleton (ABI):  ", singletonFromABI);

        // E. Threshold must be exactly 2
        uint256 threshold = ISafe(SAFE_ADDRESS).getThreshold();
        require(
            threshold == 2,
            string(abi.encodePacked(
                "ABORT: Safe threshold is ",
                _uintToString(threshold),
                " but must be exactly 2."
            ))
        );
        console.log("  [OK] Safe threshold:  ", threshold);

        // F. Owner list must be exactly {SIGNER_1, SIGNER_2, SIGNER_3}.
        //    Checks: length == 3, each approved signer present, no other addresses.
        address[] memory owners = ISafe(SAFE_ADDRESS).getOwners();
        require(
            owners.length == 3,
            string(abi.encodePacked(
                "ABORT: Safe has ",
                _uintToString(owners.length),
                " owners but must have exactly 3."
            ))
        );
        require(
            _contains(owners, SIGNER_1),
            "ABORT: SIGNER_1 not found in Safe owner list."
        );
        require(
            _contains(owners, SIGNER_2),
            "ABORT: SIGNER_2 not found in Safe owner list."
        );
        require(
            _contains(owners, SIGNER_3),
            "ABORT: SIGNER_3 not found in Safe owner list."
        );
        // No unexpected addresses: every element must be one of the three signers.
        // This fires when the owner list contains all three approved signers but
        // also includes an address not in the approved set (caught by length check
        // for >3 owners, but also by this loop for any unexpected element).
        for (uint256 i = 0; i < owners.length; i++) {
            require(
                owners[i] == SIGNER_1 || owners[i] == SIGNER_2 || owners[i] == SIGNER_3,
                string(abi.encodePacked(
                    "ABORT: Safe owner list contains unexpected address ",
                    _toHexString(owners[i]),
                    ". Owner list must be exactly {SIGNER_1, SIGNER_2, SIGNER_3}."
                ))
            );
        }
        console.log("  [OK] Safe owners:     SIGNER_1, SIGNER_2, SIGNER_3 (all present, no extras)");

        console.log("  [OK] Safe address:    ", SAFE_ADDRESS);
    }

    /// @dev Asserts that all 11 proxies are currently owned by DEPLOYER and
    ///      have contract code.
    function _checkProxies() internal view {
        address[11] memory p = _proxies();
        for (uint256 i = 0; i < 11; i++) {
            string memory name = _proxyName(i);

            require(
                p[i].code.length > 0,
                string(abi.encodePacked("ABORT: ", name, " has no code at address ", _toHexString(p[i])))
            );

            address current = IOwnable(p[i]).owner();
            require(
                current == DEPLOYER,
                string(abi.encodePacked(
                    "ABORT: ", name, " owner is ", _toHexString(current),
                    " but expected DEPLOYER ", _toHexString(DEPLOYER),
                    ". All proxies must be at DEPLOYER before run(). Use resume() if partially transferred."
                ))
            );
            console.log("  [OK]", name, "owner == DEPLOYER");
        }
    }

    /// @dev Issues transferOwnership(SAFE_ADDRESS) for all 11 proxies.
    ///      Must be called within a vm.startBroadcast()/vm.stopBroadcast() block.
    function _transferAll() internal {
        address[11] memory p = _proxies();
        for (uint256 i = 0; i < 11; i++) {
            IOwnable(p[i]).transferOwnership(SAFE_ADDRESS);
            console.log("  Transferred:", _proxyName(i));
        }
    }

    /// @dev Reads owner() for all 11 proxies and asserts each equals SAFE_ADDRESS.
    ///      Reverts with a descriptive message if any proxy is not yet transferred.
    function _assertAllTransferred() internal view {
        address[11] memory p = _proxies();
        bool allOk = true;
        for (uint256 i = 0; i < 11; i++) {
            address current = IOwnable(p[i]).owner();
            string memory name = _proxyName(i);
            if (current == SAFE_ADDRESS) {
                console.log("  [OK]", name, "owner == SAFE_ADDRESS");
            } else {
                console.log("  [FAIL]", name, "-- unexpected owner:");
                console.log("         current:", current);
                console.log("         expected: SAFE_ADDRESS");
                allOk = false;
            }
        }
        require(allOk, "ABORT: One or more proxies did not transfer. See log above.");
        console.log("");
        console.log("[OK] All 11 proxies confirmed at SAFE_ADDRESS.");
        console.log("");
        console.log("NOTE: verifyTransfer() output above is on-chain confirmed state,");
        console.log("      not a simulation. Cross-check OwnershipTransferred events on");
        console.log("      https://explorer.testnet.arc.io for each proxy address.");
        console.log("      Migration is not complete until the functional Safe test also");
        console.log("      passes (approveRecipient via 2-of-3 Safe transaction).");
    }

    // =========================================================================
    // STRING UTILITIES
    // =========================================================================

    /// @dev Converts an address to a lowercase hex string with 0x prefix.
    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory data = abi.encodePacked(addr);
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(42);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            result[2 + i * 2]     = hexChars[uint8(data[i]) >> 4];
            result[2 + i * 2 + 1] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
    }

    /// @dev Converts a uint256 to its decimal string representation.
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

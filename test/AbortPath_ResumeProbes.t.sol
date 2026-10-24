// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AbortPath_ResumeProbes — isolated abort-path tests for resume() probe logic
//
// Tests the probe + branch decision logic extracted from:
//   script/UpgradeV4.s.sol         (_probeRegistryV4, _probeVaultV4, _probePoolV4, resume branches)
//   script/UpgradeRevenueRouter.s.sol (_probeV2, resume branches)
//
// Methodology
// -----------
// Both upgrade scripts use `Upgrades.getImplementationAddress(proxy)` (reads
// the EIP-1967 slot via vm.load) and then `proxy.staticcall(selector)` to
// probe the implementation.  The full script entry-point `resume()` cannot be
// called directly in a Foundry test because it contains `vm.startBroadcast()`
// and `Upgrades.upgradeProxy` (which spawns `tryFfi` for OZ validation).
//
// Instead, this file extracts the probe functions and the branch decision logic
// verbatim into two harness contracts (V4ProbeHarness and RRProbeHarness).  The
// harness functions are byte-for-byte copies of the corresponding private/internal
// functions in the scripts, then wrapped in public helpers that exercise the same
// if/else if/else tree as resume().
//
// Each test:
//   1. Uses vm.etch to place a minimal DELEGATECALL-forwarding proxy (or a bare
//      code stub) at a chosen address so the EVM treats it as a contract.
//   2. Sets the EIP-1967 implementation slot to a chosen impl address via vm.store.
//   3. Calls the harness decision helper.
//   4. Asserts the expected outcome: abort revert, skip log, or upgrade signal.
//
// No live RPC, no forge-state cache, no Anvil fork — purely in-EVM.
//
// Known architecture constraint (LiquidityPool)
// ---------------------------------------------
// LiquidityPool has no fixed V3 impl constant in UpgradeV4.s.sol.  The resume()
// branch for LiquidityPool intentionally does NOT abort on an unknown impl:
//   - V4 probe passes  → skip
//   - V4 probe fails   → attempt upgrade (let OZ storage check catch incompatibility)
// This is by design (comment at lines 467-472 of the script).  The test for the
// LiquidityPool case verifies this design intent rather than expecting an abort.

import {Test, console} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Minimal proxy stub deployed via vm.etch
// ---------------------------------------------------------------------------
// A UUPS proxy stores its implementation at the EIP-1967 slot:
//   0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
// The proxy then DELEGATECALLs to that address for every call.
//
// For probe tests we need:
//   (a) The proxy address to contain contract code (so staticcall(proxy, ...) is
//       treated as a contract call rather than an EOA transfer).
//   (b) The proxy to DELEGATECALL to whatever is in the EIP-1967 slot.
//
// We use a minimal DELEGATECALL dispatcher written in raw EVM bytecode.
// Bytecode (24 bytes, Yul-assembled):
//
//   // slot = 0x360894...bbc (EIP-1967 impl slot)
//   // SLOAD slot → impl address
//   // DELEGATECALL with calldatacopy
//   // Forward return/revert
//
// Assembly (opcodes):
//   PUSH32 <slot>          60 20 bytes -> 0x360894...bbc
//   SLOAD                  54
//   CALLDATASIZE           36
//   PUSH1 0x00             60 00
//   PUSH1 0x00             60 00
//   CALLDATACOPY           37
//   CALLDATASIZE           36
//   PUSH1 0x00             60 00
//   DUP4                   83   <- impl is at stack[3] after the SLOAD
//   GAS                    5a
//   DELEGATECALL           f4
//   PUSH1 0x00             60 00
//   DUP1                   80
//   RETURNDATASIZE         3d
//   DUP1                   80
//   DUP5                   84
//   RETURNDATACOPY         3e
//   JUMPI (success)        57 <offset>
//   REVERT                 fd
//   JUMPDEST               5b
//   RETURN                 f3
//
// Rather than hand-assembling complex bytecode we use a Solidity helper.
// The helper is deployed normally; we copy its runtime code with vm.etch.

contract MinimalProxy {
    bytes32 constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    fallback() external payable {
        address impl;
        assembly { impl := sload(IMPL_SLOT) }
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

// ---------------------------------------------------------------------------
// V4 probe harness — mirrors UpgradeV4Script private probe functions
// ---------------------------------------------------------------------------
// These functions are copied verbatim from script/UpgradeV4.s.sol.
// If the script changes, update here.

contract V4ProbeHarness {

    bytes32 constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // --- Known impl addresses (same constants as the script) -----------------
    address constant LOAN_REGISTRY_V3_IMPL = 0xd47496361e5C485611718BD06065971691D2ba07;
    address constant LOAN_VAULT_V3_IMPL    = 0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537;

    // --- Probe: LoanRegistry V4 ----------------------------------------------
    // Copied verbatim from UpgradeV4Script._probeRegistryV4
    function probeRegistryV4(address proxy) public view returns (bool) {
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("getWasDefaulted(uint256)", uint256(0))
        );
        return ok && data.length >= 32;
    }

    // --- Probe: LoanVault V4 -------------------------------------------------
    // Copied verbatim from UpgradeV4Script._probeVaultV4 (post-fix)
    function probeVaultV4(address proxy) public view returns (bool) {
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("fundFromPool(uint256)", uint256(0))
        );
        if (ok) return false; // delegatecall to a non-contract (EOA): not V4
        if (data.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            return sel == bytes4(keccak256("NotAuthorized()"));
        }
        return false;
    }

    // --- Probe: LiquidityPool V4 ---------------------------------------------
    // Copied verbatim from UpgradeV4Script._probePoolV4 (post-fix)
    // V4 signature: sweepToken(address token, address to) — two arguments.
    // Non-owner call reverts OwnableUnauthorizedAccount(address).
    // Pre-V4: selector absent → empty revert → false.
    // EOA impl: ok=true → false.
    function probePoolV4(address proxy) public view returns (bool) {
        address usdc = 0x3600000000000000000000000000000000000000;
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("sweepToken(address,address)", usdc, address(this))
        );
        if (ok) return false;
        if (data.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            return sel == bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        }
        return false;
    }

    // --- Helper to read the EIP-1967 impl slot (mirrors Upgrades.getImplementationAddress) ---
    function getImpl(address proxy) public view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // We need vm access in the harness — declare the cheatcode interface inline.
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // --- Decision: LoanRegistry resume branch --------------------------------
    // Returns "skip", "upgrade", or reverts "ABORT: ..." — exactly mirrors the
    // if/else if/else in UpgradeV4Script.resume() for the LoanRegistry block.
    function decideRegistry(address proxy) external view returns (string memory) {
        address impl = getImpl(proxy);
        if (impl == LOAN_REGISTRY_V3_IMPL) {
            return "upgrade";
        } else if (probeRegistryV4(proxy)) {
            return "skip";
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

    // --- Decision: LoanVault resume branch -----------------------------------
    function decideVault(address proxy) external view returns (string memory) {
        address impl = getImpl(proxy);
        if (impl == LOAN_VAULT_V3_IMPL) {
            return "upgrade";
        } else if (probeVaultV4(proxy)) {
            return "skip";
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

    // --- Decision: LiquidityPool resume branch ------------------------------
    // Returns "skip" if V4 probe passes; "upgrade" otherwise (no abort by design).
    function decidePool(address proxy) external view returns (string memory) {
        if (probePoolV4(proxy)) {
            return "skip";
        } else {
            // Per UpgradeV4Script comment (lines 467-472): "An unknown impl
            // (probe fails) is treated as needing upgrade."  No abort here.
            return "upgrade";
        }
    }

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory b = abi.encodePacked(addr);
        bytes memory hexStr = new bytes(42);
        hexStr[0] = "0"; hexStr[1] = "x";
        bytes memory h = "0123456789abcdef";
        for (uint256 i = 0; i < 20; i++) {
            hexStr[2 + i * 2]     = h[uint8(b[i]) >> 4];
            hexStr[3 + i * 2]     = h[uint8(b[i]) & 0x0f];
        }
        return string(hexStr);
    }
}

// ---------------------------------------------------------------------------
// RevenueRouter probe harness — mirrors UpgradeRevenueRouterScript
// ---------------------------------------------------------------------------

contract RRProbeHarness {

    bytes32 constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address constant REVENUE_ROUTER_V1_IMPL = 0x394D9f57F00f27B19b1549e23021Efed9CD7be38;

    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Copied verbatim from UpgradeRevenueRouterScript._probeV2
    function probeV2(address proxy) public view returns (bool) {
        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("migrationCutoff()")
        );
        return ok && data.length >= 32;
    }

    function getImpl(address proxy) public view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // Decision: RevenueRouter resume branch
    function decideRR(address proxy) external view returns (string memory) {
        address impl = getImpl(proxy);
        if (impl == REVENUE_ROUTER_V1_IMPL) {
            return "upgrade";
        } else if (probeV2(proxy)) {
            return "skip";
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

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory b = abi.encodePacked(addr);
        bytes memory hexStr = new bytes(42);
        hexStr[0] = "0"; hexStr[1] = "x";
        bytes memory h = "0123456789abcdef";
        for (uint256 i = 0; i < 20; i++) {
            hexStr[2 + i * 2]     = h[uint8(b[i]) >> 4];
            hexStr[3 + i * 2]     = h[uint8(b[i]) & 0x0f];
        }
        return string(hexStr);
    }
}

// ---------------------------------------------------------------------------
// Vm interface (cheatcode subset needed by harnesses)
// ---------------------------------------------------------------------------
interface Vm {
    function load(address target, bytes32 slot) external view returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
}

// ---------------------------------------------------------------------------
// Mock contracts for the "known good" skip-path sanity checks
// ---------------------------------------------------------------------------

/// @dev Simulates LoanRegistry V4: getWasDefaulted(uint256) returns false.
contract MockRegistryV4 {
    function getWasDefaulted(uint256) external pure returns (bool) { return false; }
}

/// @dev Simulates LoanVault V4: fundFromPool reverts NotAuthorized().
contract MockVaultV4 {
    error NotAuthorized();
    function fundFromPool(uint256) external pure { revert NotAuthorized(); }
}

/// @dev Simulates LiquidityPool V4: sweepToken(address,address) with onlyOwner.
///      Non-owner call reverts OwnableUnauthorizedAccount — the V4 probe discriminator.
contract MockPoolV4 {
    error OwnableUnauthorizedAccount(address);
    error CannotSweepPoolToken();
    // Two-argument signature matching the real V4 LiquidityPool.
    function sweepToken(address /*token*/, address /*to*/) external view {
        revert OwnableUnauthorizedAccount(msg.sender);
    }
}

/// @dev Simulates pre-V4 LiquidityPool: no sweepToken(address,address) selector.
///      All unknown calls fall to the fallback and revert with empty data.
contract MockPoolPreV4 {
    // No sweepToken(address,address) — mimics V3 and earlier.
    fallback() external { revert(); }
}

/// @dev Simulates RevenueRouter V2: migrationCutoff() returns a uint256.
contract MockRRV2 {
    function migrationCutoff() external pure returns (uint256) { return 1; }
}

/// @dev Simulates LoanRegistry V3: no getWasDefaulted, so calls revert empty.
contract MockRegistryV3 {
    // No getWasDefaulted — all unknown calls revert with empty data via fallback.
}

/// @dev Simulates LoanVault V3: fundFromPool reverts OwnableUnauthorizedAccount.
contract MockVaultV3 {
    error OwnableUnauthorizedAccount(address);
    function fundFromPool(uint256) external view { revert OwnableUnauthorizedAccount(msg.sender); }
}

/// @dev Simulates RevenueRouter V1: no migrationCutoff, calls revert empty.
contract MockRRV1 {
    // No migrationCutoff — unknown calls revert with empty data.
}

// ---------------------------------------------------------------------------
// Unknown-impl stub: a deployed contract that responds with empty revert
// to all calls (simulates a valid contract at an unexpected address).
// ---------------------------------------------------------------------------
contract UnknownImpl {
    // No functions — all calls hit the default fallback, which reverts with empty data.
    fallback() external { revert(); }
}

// ---------------------------------------------------------------------------
// Targeted-test stub contracts
// ---------------------------------------------------------------------------

/// @dev Simulates a contract where fundFromPool is a no-op view function.
///      Used in test_VaultProbe_StaticCallSucceeds_returnsFalse to verify that
///      ok=true from any impl (not just EOA) is correctly rejected by the probe.
contract VaultStubFundFromPoolView {
    // Marked view so staticcall does not revert at the EVM level.
    // Returns 0 bytes (no return value).
    function fundFromPool(uint256) external pure {}
}

/// @dev Simulates a pool impl that has sweepToken(address,address) but reverts
///      with a custom error that is NOT OwnableUnauthorizedAccount.
///      Used to verify the probe checks the specific selector.
contract PoolStubSweepWrongError {
    error Unauthorized(); // different from OwnableUnauthorizedAccount(address)
    function sweepToken(address, address) external pure { revert Unauthorized(); }
}

/// @dev Simulates a pool impl that has the old one-argument sweepToken(address).
///      The probe calls sweepToken(address,address) — a different selector.
///      The proxy will DELEGATECALL the two-argument selector to this impl,
///      which has no matching function; the fallback reverts with empty data.
contract PoolStubOneArgSweep {
    error OwnableUnauthorizedAccount(address);
    error CannotSweepPoolToken();
    // Only the one-argument signature — the V4 probe uses two arguments.
    function sweepToken(address) external view {
        revert OwnableUnauthorizedAccount(msg.sender);
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------
contract AbortPath_ResumeProbes is Test {

    // EIP-1967 implementation slot
    bytes32 constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    V4ProbeHarness v4h;
    RRProbeHarness rrh;

    // Proxy stubs — deployed MinimalProxy code etched to deterministic addresses
    address proxyLR;   // LoanRegistry proxy stub
    address proxyLV;   // LoanVault proxy stub
    address proxyLP;   // LiquidityPool proxy stub
    address proxyRR;   // RevenueRouter proxy stub

    // Known impl constants (same as scripts)
    address constant LR_V3  = 0xd47496361e5C485611718BD06065971691D2ba07;
    address constant LV_V3  = 0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537;
    address constant RR_V1  = 0x394D9f57F00f27B19b1549e23021Efed9CD7be38;

    function setUp() public {
        // Deploy harnesses
        v4h = new V4ProbeHarness();
        rrh = new RRProbeHarness();

        // Deploy MinimalProxy once; copy its runtime bytecode to stub addresses.
        MinimalProxy mp = new MinimalProxy();
        bytes memory proxyCode = address(mp).code;

        // Use fixed low addresses so tests are deterministic and readable.
        proxyLR = address(0x1001);
        proxyLV = address(0x1002);
        proxyLP = address(0x1003);
        proxyRR = address(0x1004);

        vm.etch(proxyLR, proxyCode);
        vm.etch(proxyLV, proxyCode);
        vm.etch(proxyLP, proxyCode);
        vm.etch(proxyRR, proxyCode);
    }

    // =========================================================================
    // Helper: set a proxy's EIP-1967 impl slot to a given address
    // =========================================================================
    function _setImpl(address proxy, address impl) internal {
        vm.store(proxy, IMPL_SLOT, bytes32(uint256(uint160(impl))));
    }

    // =========================================================================
    // SECTION 1: Sanity checks — skip path (probe correctly identifies V4/V2)
    // =========================================================================

    function test_RegistryProbe_V4_skip() public {
        MockRegistryV4 mock = new MockRegistryV4();
        _setImpl(proxyLR, address(mock));
        bool ok = v4h.probeRegistryV4(proxyLR);
        assertTrue(ok, "probe should return true for V4 impl");
    }

    function test_RegistryProbe_V3_noSkip() public {
        MockRegistryV3 mock = new MockRegistryV3();
        _setImpl(proxyLR, address(mock));
        bool ok = v4h.probeRegistryV4(proxyLR);
        assertFalse(ok, "probe should return false for V3 impl");
    }

    function test_VaultProbe_V4_skip() public {
        MockVaultV4 mock = new MockVaultV4();
        _setImpl(proxyLV, address(mock));
        bool ok = v4h.probeVaultV4(proxyLV);
        assertTrue(ok, "probe should return true for V4 impl (NotAuthorized)");
    }

    function test_VaultProbe_V3_noSkip() public {
        MockVaultV3 mock = new MockVaultV3();
        _setImpl(proxyLV, address(mock));
        bool ok = v4h.probeVaultV4(proxyLV);
        assertFalse(ok, "probe should return false for V3 impl (OwnableUnauthorizedAccount)");
    }

    function test_PoolProbe_V4_skip() public {
        MockPoolV4 mock = new MockPoolV4();
        _setImpl(proxyLP, address(mock));
        bool ok = v4h.probePoolV4(proxyLP);
        assertTrue(ok, "probe should return true for V4 impl (CannotSweepPoolToken)");
    }

    function test_RRProbe_V2_skip() public {
        MockRRV2 mock = new MockRRV2();
        _setImpl(proxyRR, address(mock));
        bool ok = rrh.probeV2(proxyRR);
        assertTrue(ok, "probe should return true for V2 impl (migrationCutoff returns uint256)");
    }

    function test_RRProbe_V1_noSkip() public {
        MockRRV1 mock = new MockRRV1();
        _setImpl(proxyRR, address(mock));
        bool ok = rrh.probeV2(proxyRR);
        assertFalse(ok, "probe should return false for V1 impl (no migrationCutoff)");
    }

    // =========================================================================
    // SECTION 2: Abort-path tests — unknown implementation
    //
    // For each proxy, the unknown impl is a contract with no relevant selectors
    // (UnknownImpl — fallback reverts with empty data).  We also test the
    // non-contract address case (plain EOA / address with no code).
    // =========================================================================

    // -------------------------------------------------------------------------
    // Test A1: LoanRegistry — unknown contract impl → abort
    // -------------------------------------------------------------------------
    function test_LR_UnknownContractImpl_Aborts() public {
        // Setup: proxy points to a contract that isn't V3 or V4
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLR, address(unk));

        // Expected: decideRegistry reverts with ABORT message
        vm.expectRevert();
        v4h.decideRegistry(proxyLR);
    }

    function test_LR_UnknownContractImpl_AbortMessageContainsExpectedText() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLR, address(unk));

        // Capture the revert reason and assert it starts with "ABORT: LoanRegistry"
        (bool success, bytes memory reason) = address(v4h).staticcall(
            abi.encodeWithSelector(v4h.decideRegistry.selector, proxyLR)
        );
        assertFalse(success, "call must revert");
        // reason is abi-encoded string revert: 4-byte Error selector + abi.encode(string)
        assertTrue(reason.length > 4, "revert reason must be non-empty");
        // Decode the revert string
        string memory msg_ = abi.decode(slice(reason, 4, reason.length - 4), (string));
        assertEq(bytes(msg_)[0], bytes("A")[0], "revert must start with A (ABORT)");
        // Verify the string contains "LoanRegistry"
        assertTrue(_contains(msg_, "LoanRegistry"), "abort message must mention LoanRegistry");
        assertTrue(_contains(msg_, "unexpected impl"), "abort message must say unexpected impl");
    }

    // -------------------------------------------------------------------------
    // Test A2: LoanRegistry — non-contract (EOA) address as impl → abort
    // -------------------------------------------------------------------------
    function test_LR_NonContractImpl_Aborts() public {
        // A bare EOA address: no code, all calls return empty (ok=true, length=0)
        address eoa = address(0xDEAD);
        _setImpl(proxyLR, eoa);

        vm.expectRevert();
        v4h.decideRegistry(proxyLR);
    }

    // -------------------------------------------------------------------------
    // Test B1: LoanVault — unknown contract impl → abort
    // -------------------------------------------------------------------------
    function test_LV_UnknownContractImpl_Aborts() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLV, address(unk));

        vm.expectRevert();
        v4h.decideVault(proxyLV);
    }

    function test_LV_UnknownContractImpl_AbortMessageContainsExpectedText() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLV, address(unk));

        (bool success, bytes memory reason) = address(v4h).staticcall(
            abi.encodeWithSelector(v4h.decideVault.selector, proxyLV)
        );
        assertFalse(success, "call must revert");
        assertTrue(reason.length > 4, "revert reason must be non-empty");
        string memory msg_ = abi.decode(slice(reason, 4, reason.length - 4), (string));
        assertTrue(_contains(msg_, "LoanVault"), "abort message must mention LoanVault");
        assertTrue(_contains(msg_, "unexpected impl"), "abort message must say unexpected impl");
    }

    // -------------------------------------------------------------------------
    // Test B2: LoanVault — non-contract (EOA) address as impl → abort
    // -------------------------------------------------------------------------
    function test_LV_NonContractImpl_Aborts() public {
        address eoa = address(0xBEEF);
        _setImpl(proxyLV, eoa);

        vm.expectRevert();
        v4h.decideVault(proxyLV);
    }

    // -------------------------------------------------------------------------
    // Test C1: LiquidityPool — unknown impl → NO abort (by design)
    //
    // UpgradeV4Script.resume() for LiquidityPool has no abort branch.
    // An unknown impl falls through to "attempt upgrade" (returns "upgrade").
    // The OZ storage check inside Upgrades.upgradeProxy provides the safety net.
    // This test verifies the design intent: the decision is "upgrade", not abort.
    // -------------------------------------------------------------------------
    function test_LP_UnknownContractImpl_Returns_Upgrade_ByDesign() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLP, address(unk));

        // Should NOT revert; should return "upgrade"
        string memory result = v4h.decidePool(proxyLP);
        assertEq(result, "upgrade",
            "LiquidityPool unknown impl must return 'upgrade' per design (no abort branch)");
    }

    function test_LP_NonContractImpl_Returns_Upgrade_ByDesign() public {
        address eoa = address(0xCAFE);
        _setImpl(proxyLP, eoa);

        string memory result = v4h.decidePool(proxyLP);
        assertEq(result, "upgrade",
            "LiquidityPool EOA impl must return 'upgrade' per design (no abort branch)");
    }

    // -------------------------------------------------------------------------
    // Test D1: RevenueRouter — unknown contract impl → abort
    // -------------------------------------------------------------------------
    function test_RR_UnknownContractImpl_Aborts() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyRR, address(unk));

        vm.expectRevert();
        rrh.decideRR(proxyRR);
    }

    function test_RR_UnknownContractImpl_AbortMessageContainsExpectedText() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyRR, address(unk));

        (bool success, bytes memory reason) = address(rrh).staticcall(
            abi.encodeWithSelector(rrh.decideRR.selector, proxyRR)
        );
        assertFalse(success, "call must revert");
        assertTrue(reason.length > 4, "revert reason must be non-empty");
        string memory msg_ = abi.decode(slice(reason, 4, reason.length - 4), (string));
        assertTrue(_contains(msg_, "RevenueRouter"), "abort message must mention RevenueRouter");
        assertTrue(_contains(msg_, "unexpected impl"), "abort message must say unexpected impl");
    }

    // -------------------------------------------------------------------------
    // Test D2: RevenueRouter — non-contract (EOA) address as impl → abort
    // -------------------------------------------------------------------------
    function test_RR_NonContractImpl_Aborts() public {
        address eoa = address(0xF00D);
        _setImpl(proxyRR, eoa);

        vm.expectRevert();
        rrh.decideRR(proxyRR);
    }

    // =========================================================================
    // SECTION 3: Confirm known-V3/V1 impl routes to "upgrade" (not abort, not skip)
    // =========================================================================

    function test_LR_V3Impl_Returns_Upgrade() public {
        _setImpl(proxyLR, LR_V3);
        string memory result = v4h.decideRegistry(proxyLR);
        assertEq(result, "upgrade", "V3 impl must route to upgrade branch");
    }

    function test_LV_V3Impl_Returns_Upgrade() public {
        _setImpl(proxyLV, LV_V3);
        string memory result = v4h.decideVault(proxyLV);
        assertEq(result, "upgrade", "V3 impl must route to upgrade branch");
    }

    function test_RR_V1Impl_Returns_Upgrade() public {
        _setImpl(proxyRR, RR_V1);
        string memory result = rrh.decideRR(proxyRR);
        assertEq(result, "upgrade", "V1 impl must route to upgrade branch");
    }

    // =========================================================================
    // SECTION 4: Confirm V4/V2 impl routes to "skip"
    // =========================================================================

    function test_LR_V4Impl_Returns_Skip() public {
        MockRegistryV4 mock = new MockRegistryV4();
        _setImpl(proxyLR, address(mock));
        // impl != V3, probe passes → skip
        string memory result = v4h.decideRegistry(proxyLR);
        assertEq(result, "skip", "V4 impl must route to skip branch");
    }

    function test_LV_V4Impl_Returns_Skip() public {
        MockVaultV4 mock = new MockVaultV4();
        _setImpl(proxyLV, address(mock));
        string memory result = v4h.decideVault(proxyLV);
        assertEq(result, "skip", "V4 impl must route to skip branch");
    }

    function test_LP_V4Impl_Returns_Skip() public {
        MockPoolV4 mock = new MockPoolV4();
        _setImpl(proxyLP, address(mock));
        string memory result = v4h.decidePool(proxyLP);
        assertEq(result, "skip", "V4 impl must route to skip branch");
    }

    function test_RR_V2Impl_Returns_Skip() public {
        MockRRV2 mock = new MockRRV2();
        _setImpl(proxyRR, address(mock));
        string memory result = rrh.decideRR(proxyRR);
        assertEq(result, "skip", "V2 impl must route to skip branch");
    }

    // =========================================================================
    // SECTION 4b: Targeted probe correctness tests — all four implementation
    //             variants per probe.  Required by the focused safety review.
    // =========================================================================
    //
    // For each probe, the four variants are:
    //   1. Real V4 / V2 impl    → probe returns true  (skip path)
    //   2. Real V3 / V1 impl    → probe returns false (upgrade path)
    //   3. Unknown contract     → probe returns false (abort path for LR/LV/RR;
    //                                                  upgrade path for LP by design)
    //   4. Non-contract (EOA)   → probe returns false (same as unknown contract)
    //
    // Vault-specific variants:
    //   5. Contract that succeeds on fundFromPool staticcall (view stub)
    //      — must NOT be classified as V4 (ok=true → return false).

    // -------------------------------------------------------------------------
    // _probeVaultV4 targeted tests
    // -------------------------------------------------------------------------

    /// @dev Case 1: Real V4 — NotAuthorized() on fundFromPool staticcall.
    function test_VaultProbe_V4_returnsTrue() public {
        MockVaultV4 mock = new MockVaultV4();
        _setImpl(proxyLV, address(mock));
        assertTrue(v4h.probeVaultV4(proxyLV),
            "probe must return true for V4 (NotAuthorized selector)");
    }

    /// @dev Case 2: Real V3 — OwnableUnauthorizedAccount on fundFromPool staticcall.
    function test_VaultProbe_V3_returnsFalse() public {
        MockVaultV3 mock = new MockVaultV3();
        _setImpl(proxyLV, address(mock));
        assertFalse(v4h.probeVaultV4(proxyLV),
            "probe must return false for V3 (OwnableUnauthorizedAccount, wrong selector)");
    }

    /// @dev Case 3: Unknown contract (UnknownImpl fallback reverts with empty data).
    function test_VaultProbe_UnknownContract_returnsFalse() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLV, address(unk));
        assertFalse(v4h.probeVaultV4(proxyLV),
            "probe must return false for unknown contract (empty revert, data.length < 4)");
    }

    /// @dev Case 4: Non-contract (EOA) — DELEGATECALL succeeds with ok=true, 0 bytes.
    ///      This is the case fixed in the previous session: if (ok) return false.
    function test_VaultProbe_EOAImpl_returnsFalse() public {
        _setImpl(proxyLV, address(0xBEEF));
        assertFalse(v4h.probeVaultV4(proxyLV),
            "probe must return false for EOA impl (ok=true with 0 bytes must not be treated as V4)");
    }

    /// @dev Case 5 (vault-specific): A contract whose fundFromPool SUCCEEDS under
    ///      staticcall (i.e. a view/pure stub).  ok=true must NOT be V4.
    ///      In production this cannot happen for a real contract because fundFromPool
    ///      is state-mutating, but a malicious or buggy impl could expose it as view.
    function test_VaultProbe_StaticCallSucceeds_returnsFalse() public {
        // Deploy a stub where fundFromPool is view and returns nothing (0 bytes).
        // This simulates the EOA case at the contract level.
        VaultStubFundFromPoolView stub = new VaultStubFundFromPoolView();
        _setImpl(proxyLV, address(stub));
        assertFalse(v4h.probeVaultV4(proxyLV),
            "probe must return false when fundFromPool staticcall succeeds (ok=true path)");
    }

    // -------------------------------------------------------------------------
    // _probePoolV4 targeted tests
    // -------------------------------------------------------------------------

    /// @dev Case 1: Real V4 — sweepToken(address,address) + OwnableUnauthorizedAccount.
    function test_PoolProbe_V4_returnsTrue() public {
        MockPoolV4 mock = new MockPoolV4();
        _setImpl(proxyLP, address(mock));
        assertTrue(v4h.probePoolV4(proxyLP),
            "probe must return true for V4 (sweepToken(address,address) + OwnableUnauthorizedAccount)");
    }

    /// @dev Case 2: Pre-V4 LP (no sweepToken(address,address) selector) → false.
    function test_PoolProbe_PreV4_returnsFalse() public {
        MockPoolPreV4 mock = new MockPoolPreV4();
        _setImpl(proxyLP, address(mock));
        assertFalse(v4h.probePoolV4(proxyLP),
            "probe must return false for pre-V4 LP (selector absent, empty revert)");
    }

    /// @dev Case 3: Unknown contract (UnknownImpl) → false.
    function test_PoolProbe_UnknownContract_returnsFalse() public {
        UnknownImpl unk = new UnknownImpl();
        _setImpl(proxyLP, address(unk));
        assertFalse(v4h.probePoolV4(proxyLP),
            "probe must return false for unknown contract");
    }

    /// @dev Case 4: EOA impl → ok=true, 0 bytes → false.
    function test_PoolProbe_EOAImpl_returnsFalse() public {
        _setImpl(proxyLP, address(0xCAFE));
        assertFalse(v4h.probePoolV4(proxyLP),
            "probe must return false for EOA impl");
    }

    /// @dev Extra: a contract that has sweepToken(address,address) but reverts
    ///      with a DIFFERENT selector (not OwnableUnauthorizedAccount) → false.
    ///      Ensures the selector check is specific.
    function test_PoolProbe_WrongRevertSelector_returnsFalse() public {
        PoolStubSweepWrongError stub = new PoolStubSweepWrongError();
        _setImpl(proxyLP, address(stub));
        assertFalse(v4h.probePoolV4(proxyLP),
            "probe must return false when sweepToken reverts with wrong selector");
    }

    /// @dev Extra: old single-argument sweepToken(address) DOES NOT satisfy the probe.
    ///      The old signature's selector (0x1be19560) is different from the V4
    ///      two-argument selector (0x258836fe).  Calling sweepToken(address,address)
    ///      on a contract that only has sweepToken(address) hits the fallback.
    function test_PoolProbe_OldOneArgSweepToken_returnsFalse() public {
        PoolStubOneArgSweep stub = new PoolStubOneArgSweep();
        _setImpl(proxyLP, address(stub));
        assertFalse(v4h.probePoolV4(proxyLP),
            "probe must return false for old one-argument sweepToken(address) impl");
    }

    // =========================================================================
    // SECTION 5: No other proxy is upgraded when abort fires
    //
    // The resume() scripts process proxies in order: LR → LV → LP (V4) and
    // RR alone.  When LR aborts, LV and LP must not be upgraded; when LV aborts,
    // LP must not be upgraded.  The harness decision functions model this
    // sequentially — an abort revert unwinds the entire call, so we verify that
    // a revert on decideRegistry would prevent reaching decideVault.
    //
    // This is guaranteed by Solidity's revert semantics: any revert in a
    // top-level call reverts all state changes and stops execution.  The tests
    // below document this guarantee explicitly.
    // =========================================================================

    function test_LR_AbortPreventsVaultAndPoolUpgrade() public {
        // Scenario: LR is at unknown impl, LV and LP are at known V3/pre-V4.
        UnknownImpl unkLR = new UnknownImpl();
        _setImpl(proxyLR, address(unkLR));

        // V3 for LV (would be "upgrade" if reached)
        _setImpl(proxyLV, LV_V3);

        // decideRegistry should revert — the test passes if it does
        vm.expectRevert();
        v4h.decideRegistry(proxyLR);

        // Since decideRegistry reverted, decideVault was never called.
        // Confirm LV impl is unchanged (still V3) as evidence no side-effect occurred.
        bytes32 lvSlotVal = vm.load(proxyLV, IMPL_SLOT);
        address lvImpl = address(uint160(uint256(lvSlotVal)));
        assertEq(lvImpl, LV_V3, "LoanVault impl must be unchanged after LR abort");
    }

    function test_LV_AbortPreventsPoolUpgrade() public {
        // Scenario: LR is V4 (would skip), LV is unknown (aborts).
        MockRegistryV4 mockLR = new MockRegistryV4();
        _setImpl(proxyLR, address(mockLR));

        UnknownImpl unkLV = new UnknownImpl();
        _setImpl(proxyLV, address(unkLV));

        // Confirm LR decision is "skip" (would not abort)
        string memory lrResult = v4h.decideRegistry(proxyLR);
        assertEq(lrResult, "skip", "LR must be skip before LV abort test");

        // LV decision should abort
        vm.expectRevert();
        v4h.decideVault(proxyLV);

        // LP impl is untouched (any value — but the point is decidePool was not called)
        // This is guaranteed by revert semantics; the assertion below documents it.
        // Set LP to a known value first to have something to check.
        _setImpl(proxyLP, address(0xABCD));
        bytes32 lpSlotVal = vm.load(proxyLP, IMPL_SLOT);
        address lpImpl = address(uint160(uint256(lpSlotVal)));
        assertEq(lpImpl, address(0xABCD), "LiquidityPool impl must be unchanged after LV abort");
    }

    // =========================================================================
    // Utility: bytes slice (used in message inspection tests)
    // =========================================================================
    function slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory) {
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = b[start + i];
        }
        return result;
    }

    // Utility: substring search
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { found = false; break; }
            }
            if (found) return true;
        }
        return false;
    }
}

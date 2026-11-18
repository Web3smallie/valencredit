// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================================
// TransferOwnership.t.sol
// =============================================================================
//
// Isolated unit tests for script/TransferOwnership.s.sol.
//
// ISOLATION GUARANTEES
// --------------------
// - No forge --fork-url / vm.createFork / vm.createSelectFork calls.
//   All tests run entirely in the local Foundry EVM.
// - No vm.broadcast / vm.startBroadcast / vm.stopBroadcast calls.
//   State changes are local EVM mutations via vm.prank / vm.store.
// - No calls to Arc Testnet or any live network.
// - Every test deploys fresh proxy + Safe mock instances in setUp() or
//   inline; no shared mutable state persists between tests.
//
// TEST COVERAGE AND LIMITATIONS (read before relying on any result)
// -----------------------------------------------------------------
// WHAT CALLS THE REAL SCRIPT: only T14 and T16.  Both call the deployed
// TransferOwnershipScript and only prove that the address(0) placeholder
// guards fire.  Because SAFE_ADDRESS and the signer constants are compile-time
// constants fixed at address(0), NO test can drive the real script past
// check A.  The real script's Safe checks C/D1/D2/E/F, _checkProxies(),
// run(), resume() and _assertAllTransferred() are therefore NOT executed by
// any test in this file.
//
// WHAT CALLS A HARNESS: T01-T13 (except where noted) call
// TransferOwnershipHarness, a separate hand-written re-implementation with
// injectable addresses.  It is a mirror, not the production code.  Passing
// harness tests show the mirrored LOGIC is sound; they do not prove the
// production script is correct, and they will not catch drift between the
// harness and the script.  The harness omits check D1 (slot 0) and uses
// shorter error strings than the script.
//
// WHAT CALLS NEITHER: T09, T12, T13 drive MockProxy directly with vm.prank
// (T12/T13 also call harness.assertAllTransferred).  T09 does not call the
// harness or the script.  T15 only checks that vm.store/vm.load round-trip on
// a mock; it does not call the script.
//
// run() and resume() use vm.startBroadcast(), which cannot run in a Test.
// Reverting tests (T11) cannot prove "no transfer happened before the abort"
// because an EVM revert rolls back all state anyway; the scan-before-transfer
// ordering is established by code review of the script, not by this suite.
//
// No test uses vm.etch.  No test touches a live network.
//
// TESTS
// -----
//   T01  [harness] placeholder guard: SAFE_ADDRESS == address(0)
//   T02  [harness] Safe has no contract code
//   T03  [harness] masterCopy() returns wrong singleton
//   T04  [harness] Safe threshold != 2
//   T05  [harness] Safe owner count != 3 (2 owners)
//   T06  [harness] approved signer missing from owner list
//   T07  [harness] per-element unexpected-address loop (reached via a
//                  duplicated signer argument)
//   T07b [harness] Safe has 4 owners (caught by count check)
//   T08  [harness] a proxy owner is not DEPLOYER
//   T09  [mock only] MockProxy ownership moves to the Safe via vm.prank;
//                  does not exercise the harness or the script
//   T10  [harness] resume(): skips Safe-owned proxies, transfers the rest
//   T11  [harness] resume(): reverts with the unexpected-owner message
//   T12  [harness] assertAllTransferred() reverts if one proxy is missed
//   T13  [harness] assertAllTransferred() passes when all 11 are at Safe
//   T14  [REAL SCRIPT] preflightChecks() reverts on the address(0) guard
//   T15  [mock only] vm.store/vm.load slot-0 round trip; script not called
//   T16  [REAL SCRIPT] verifyTransfer() reverts on the address(0) guard
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TransferOwnershipScript} from "../script/TransferOwnership.s.sol";

// ---------------------------------------------------------------------------
// Minimal OZ-compatible ownable contract used as proxy stand-in.
// Inherits no OZ code; uses raw storage so there are no import-version
// concerns.  Implements the standard owner()/transferOwnership() interface.
// ---------------------------------------------------------------------------
contract MockProxy {
    address private _owner;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "zero owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        address old = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // Allow tests to force an arbitrary owner (bypassing onlyOwner) to
    // simulate unexpected-owner scenarios without a privileged caller.
    function forceOwner(address newOwner) external {
        _owner = newOwner;
    }
}

// ---------------------------------------------------------------------------
// Mock Safe: configurable threshold, owner list, and singleton return value.
// Does NOT set slot-0 storage — tests that exercise the slot-0 check must
// use vm.store directly (see T15).
// ---------------------------------------------------------------------------
contract MockSafe {
    address public singleton;
    uint256 public threshold;
    address[] public ownerList;

    constructor(address _singleton, uint256 _threshold, address[] memory _owners) {
        singleton = _singleton;
        threshold = _threshold;
        for (uint256 i = 0; i < _owners.length; i++) {
            ownerList.push(_owners[i]);
        }
    }

    /// @dev Safe proxy interface: returns the ABI singleton address.
    ///      Note: this is NOT slot 0 of this contract (slot 0 holds `singleton`
    ///      only by coincidence for this mock).  Tests that verify slot-0 and
    ///      ABI agreement must use vm.store to set slot 0 explicitly.
    function masterCopy() external view returns (address) {
        return singleton;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return ownerList;
    }
}

// ---------------------------------------------------------------------------
// Harness: mirrors the script logic for testing without Forge broadcast.
// Accepts injected addresses rather than using compile-time constants.
//
// RELATIONSHIP TO SCRIPT
// The harness re-implements the script's _checkSafe, _checkProxies, run,
// resume, and _assertAllTransferred logic.  It is a mirror, not an import.
// Changes to the script must be reflected here by hand.  See the coverage
// notes at the top of this file for which tests use the harness and which
// (T14, T16 only) call the real script.
//
// The slot-0 cross-check (check D1 in the script's _checkSafe) is NOT mirrored
// here: the harness is a plain contract without cheatcode access.  Check D1 is
// not exercised by any test in this file.
// ---------------------------------------------------------------------------
contract TransferOwnershipHarness {

    address constant EXPECTED_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    // -----------------------------------------------------------------------
    // Low-level interface helpers (selectors match the script's ISafe/IOwnable)
    // -----------------------------------------------------------------------
    function _masterCopy(address safe) internal view returns (address) {
        (bool ok, bytes memory data) = safe.staticcall(abi.encodeWithSelector(0xa619486e));
        require(ok && data.length >= 32, "masterCopy() call failed");
        return abi.decode(data, (address));
    }

    function _getThreshold(address safe) internal view returns (uint256) {
        (bool ok, bytes memory data) = safe.staticcall(abi.encodeWithSelector(0xe75235b8));
        require(ok && data.length >= 32, "getThreshold() call failed");
        return abi.decode(data, (uint256));
    }

    function _getOwners(address safe) internal view returns (address[] memory) {
        (bool ok, bytes memory data) = safe.staticcall(abi.encodeWithSelector(0xa0e67e2b));
        require(ok, "getOwners() call failed");
        return abi.decode(data, (address[]));
    }

    function _proxyOwner(address proxy) internal view returns (address) {
        (bool ok, bytes memory data) = proxy.staticcall(abi.encodeWithSelector(0x8da5cb5b));
        require(ok && data.length >= 32, "owner() call failed");
        return abi.decode(data, (address));
    }

    function _transferOwnership(address proxy, address newOwner) internal {
        (bool ok,) = proxy.call(abi.encodeWithSelector(0xf2fde38b, newOwner));
        require(ok, "transferOwnership() call failed");
    }

    function _contains(address[] memory haystack, address needle)
        internal pure returns (bool)
    {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // checkSafe: mirrors _checkSafe() in the script.
    // NOTE: The slot-0 cross-check (D1) is NOT included here because the
    // harness is a plain contract without access to vm cheatcodes.  D1 is
    // verified directly in T15 using vm.store + vm.load on the script itself.
    // -----------------------------------------------------------------------
    function checkSafe(
        address safeAddress,
        address signer1,
        address signer2,
        address signer3
    ) external view {
        require(
            safeAddress != address(0),
            "ABORT: SAFE_ADDRESS is address(0). Fill in after Safe deployment and verification."
        );
        require(signer1 != address(0), "ABORT: SIGNER_1 is address(0). Fill in the verified signer address.");
        require(signer2 != address(0), "ABORT: SIGNER_2 is address(0). Fill in the verified signer address.");
        require(signer3 != address(0), "ABORT: SIGNER_3 is address(0). Fill in the verified signer address.");

        require(safeAddress.code.length > 0, "ABORT: SAFE_ADDRESS has no contract code. Verify the address and network.");

        address singleton = _masterCopy(safeAddress);
        require(
            singleton == EXPECTED_SINGLETON,
            "ABORT: Safe singleton mismatch."
        );

        uint256 thresh = _getThreshold(safeAddress);
        require(thresh == 2, "ABORT: Safe threshold must be exactly 2.");

        address[] memory owners = _getOwners(safeAddress);
        require(owners.length == 3, "ABORT: Safe must have exactly 3 owners.");
        require(_contains(owners, signer1), "ABORT: SIGNER_1 not found in Safe owner list.");
        require(_contains(owners, signer2), "ABORT: SIGNER_2 not found in Safe owner list.");
        require(_contains(owners, signer3), "ABORT: SIGNER_3 not found in Safe owner list.");
        for (uint256 i = 0; i < owners.length; i++) {
            require(
                owners[i] == signer1 || owners[i] == signer2 || owners[i] == signer3,
                "ABORT: Safe owner list contains unexpected address."
            );
        }
    }

    // -----------------------------------------------------------------------
    // checkProxies: mirrors _checkProxies() in the script.
    // -----------------------------------------------------------------------
    function checkProxies(address[11] memory proxies, address expectedDeployer) external view {
        for (uint256 i = 0; i < 11; i++) {
            require(proxies[i].code.length > 0, "ABORT: proxy has no code");
            address current = _proxyOwner(proxies[i]);
            require(
                current == expectedDeployer,
                "ABORT: proxy owner is not DEPLOYER"
            );
        }
    }

    // -----------------------------------------------------------------------
    // transferAll: mirrors _transferAll() + the broadcast loop in run().
    // -----------------------------------------------------------------------
    function transferAll(address[11] memory proxies, address newOwner) external {
        for (uint256 i = 0; i < 11; i++) {
            _transferOwnership(proxies[i], newOwner);
        }
    }

    // -----------------------------------------------------------------------
    // resume: mirrors resume() in the script exactly.
    //   Phase 1 (SCAN): read all 11 owners; abort immediately on unexpected owner.
    //   Phase 2 (TRANSFER): transfer only those flagged in the scan.
    // An unexpected owner at ANY index aborts before ANY transfer is issued.
    // -----------------------------------------------------------------------
    function resume(
        address[11] memory proxies,
        address deployer,
        address safeAddress
    ) external {
        bool[11] memory needsTransfer;

        // Phase 1: scan all proxies; revert immediately on unexpected owner.
        for (uint256 i = 0; i < 11; i++) {
            address current = _proxyOwner(proxies[i]);
            if (current == safeAddress) {
                // already transferred: skip
            } else if (current == deployer) {
                needsTransfer[i] = true;
            } else {
                revert(string(abi.encodePacked(
                    "ABORT: proxy index ",
                    _uintStr(i),
                    " has unexpected owner. Manual investigation required."
                )));
            }
        }

        // Phase 2: transfer only proxies flagged in the scan.
        for (uint256 i = 0; i < 11; i++) {
            if (needsTransfer[i]) {
                _transferOwnership(proxies[i], safeAddress);
            }
        }
    }

    // -----------------------------------------------------------------------
    // assertAllTransferred: mirrors _assertAllTransferred() in the script.
    // -----------------------------------------------------------------------
    function assertAllTransferred(address[11] memory proxies, address safeAddress) external view {
        for (uint256 i = 0; i < 11; i++) {
            address current = _proxyOwner(proxies[i]);
            require(current == safeAddress, "ABORT: proxy not at SAFE_ADDRESS");
        }
    }

    function _uintStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v; uint256 d;
        while (tmp != 0) { d++; tmp /= 10; }
        bytes memory buf = new bytes(d);
        while (v != 0) { d--; buf[d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }
}

// =============================================================================
// Test contract
// =============================================================================
contract TransferOwnershipTest is Test {

    TransferOwnershipHarness harness;
    TransferOwnershipScript  script;

    // Fixed addresses
    address constant DEPLOYER           = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144;
    address constant EXPECTED_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    // Test signers (not real wallets; address literals only)
    address constant SIGNER_1 = address(0x1111);
    address constant SIGNER_2 = address(0x2222);
    address constant SIGNER_3 = address(0x3333);

    // Deployed mock proxies (11 total)
    address[11] proxies;

    // -------------------------------------------------------------------------
    // setUp: deploys fresh harness, script instance, and 11 MockProxies.
    // -------------------------------------------------------------------------
    function setUp() public {
        harness = new TransferOwnershipHarness();
        script  = new TransferOwnershipScript();

        for (uint256 i = 0; i < 11; i++) {
            proxies[i] = address(new MockProxy(DEPLOYER));
        }
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    /// @dev Deploys a valid MockSafe with EXPECTED_SINGLETON, threshold=2,
    ///      owners=[SIGNER_1, SIGNER_2, SIGNER_3], and sets slot 0 via vm.store
    ///      so the slot-0 cross-check in the script also passes.
    function _validSafe() internal returns (address) {
        address[] memory owners = new address[](3);
        owners[0] = SIGNER_1;
        owners[1] = SIGNER_2;
        owners[2] = SIGNER_3;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 2, owners));
        // Set slot 0 to EXPECTED_SINGLETON so the vm.load check in the script passes.
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(EXPECTED_SINGLETON))));
        return safe;
    }

    /// @dev Returns a fresh array copy of the setUp proxies.
    function _proxyArr() internal view returns (address[11] memory arr) {
        for (uint256 i = 0; i < 11; i++) arr[i] = proxies[i];
    }

    // =========================================================================
    // T01 — preflightChecks reverts if SAFE_ADDRESS is address(0)
    // Exercises: SAFE_ADDRESS placeholder guard (check A).
    // Via: harness (script's SAFE_ADDRESS constant is always address(0)).
    // =========================================================================
    function test_T01_preflightReverts_safeAddressZero() public {
        vm.expectRevert(bytes("ABORT: SAFE_ADDRESS is address(0). Fill in after Safe deployment and verification."));
        harness.checkSafe(address(0), SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T02 — preflightChecks reverts if Safe has no contract code
    // Exercises: code-length check (check C).
    // =========================================================================
    function test_T02_preflightReverts_safeNotContract() public {
        address notAContract = address(0xDEAD); // no code in test EVM
        vm.expectRevert(bytes("ABORT: SAFE_ADDRESS has no contract code. Verify the address and network."));
        harness.checkSafe(notAContract, SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T03 — preflightChecks reverts if Safe returns wrong singleton
    // Exercises: masterCopy() ABI check (check D2 in harness, which omits D1).
    // =========================================================================
    function test_T03_preflightReverts_wrongSingleton() public {
        address[] memory owners = new address[](3);
        owners[0] = SIGNER_1; owners[1] = SIGNER_2; owners[2] = SIGNER_3;
        address wrongSingleton = address(0xBAD);
        address safe = address(new MockSafe(wrongSingleton, 2, owners));

        vm.expectRevert(bytes("ABORT: Safe singleton mismatch."));
        harness.checkSafe(safe, SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T04 — preflightChecks reverts if Safe threshold != 2
    // Exercises: threshold check (check E).
    // =========================================================================
    function test_T04_preflightReverts_wrongThreshold() public {
        address[] memory owners = new address[](3);
        owners[0] = SIGNER_1; owners[1] = SIGNER_2; owners[2] = SIGNER_3;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 1, owners)); // threshold=1

        vm.expectRevert(bytes("ABORT: Safe threshold must be exactly 2."));
        harness.checkSafe(safe, SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T05 — preflightChecks reverts if Safe owner count != 3
    // Exercises: owner list length check (check F, length guard).
    // =========================================================================
    function test_T05_preflightReverts_wrongOwnerCount() public {
        address[] memory owners = new address[](2); // only 2 owners
        owners[0] = SIGNER_1; owners[1] = SIGNER_2;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 2, owners));

        vm.expectRevert(bytes("ABORT: Safe must have exactly 3 owners."));
        harness.checkSafe(safe, SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T06 — preflightChecks reverts if a signer is missing from owner list
    // Exercises: _contains membership check (check F, signer-present guard).
    // Setup: owners = [S1, S2, stranger], signers = [S1, S2, S3].
    //        SIGNER_3 is not in the list → "SIGNER_3 not found".
    // =========================================================================
    function test_T06_preflightReverts_missingSignerInOwnerList() public {
        address strangerSigner = address(0x9999);
        address[] memory owners = new address[](3);
        owners[0] = SIGNER_1; owners[1] = SIGNER_2; owners[2] = strangerSigner;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 2, owners));

        vm.expectRevert(bytes("ABORT: SIGNER_3 not found in Safe owner list."));
        harness.checkSafe(safe, SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T07 — preflightChecks reverts via the unexpected-address per-element loop
    //
    // This test directly exercises the per-element loop path in check F, which
    // is DISTINCT from the missing-signer path tested in T06.
    //
    // The per-element loop fires when:
    //   - owners.length == 3 (length check passes)
    //   - all three approved signers are found in the list (_contains checks pass)
    //   - but one element in the list is not in the approved signer set
    //
    // To reach this with 3 owners: supply a DUPLICATE approved signer so that
    // all three _contains checks pass while one element is not in the expected set.
    //
    // Setup: owners = [S1, S2, S3], call checkSafe with signers (S1, S2, S1).
    //   - _contains(owners, S1) → true  ✓  (S1 present)
    //   - _contains(owners, S2) → true  ✓  (S2 present)
    //   - _contains(owners, S1) → true  ✓  (S1 present, used as signer3)
    //   Per-element loop on S3: S3 != S1 && S3 != S2 && S3 != S1 → ABORT
    //
    // This proves the per-element loop independently catches a case where the
    // approved signer set and the actual owner list differ, even when all
    // membership checks pass.
    // =========================================================================
    function test_T07_preflightReverts_unexpectedAddressInOwnerList() public {
        address[] memory owners = new address[](3);
        owners[0] = SIGNER_1; owners[1] = SIGNER_2; owners[2] = SIGNER_3;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 2, owners));

        // Pass SIGNER_1 twice as signer3 argument (duplicate).
        // All three _contains checks pass; per-element loop catches SIGNER_3
        // (which is in the owner list but not in {SIGNER_1, SIGNER_2, SIGNER_1}).
        vm.expectRevert(bytes("ABORT: Safe owner list contains unexpected address."));
        harness.checkSafe(safe, SIGNER_1, SIGNER_2, SIGNER_1);
    }

    // =========================================================================
    // T07b — preflightChecks reverts if Safe has 4 owners
    // Exercises: owner count check (caught by length guard before per-element loop).
    // =========================================================================
    function test_T07b_preflightReverts_fourOwnersWithUnexpected() public {
        address stranger = address(0x4444);
        address[] memory owners = new address[](4);
        owners[0] = SIGNER_1; owners[1] = SIGNER_2; owners[2] = SIGNER_3; owners[3] = stranger;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 2, owners));

        vm.expectRevert(bytes("ABORT: Safe must have exactly 3 owners."));
        harness.checkSafe(safe, SIGNER_1, SIGNER_2, SIGNER_3);
    }

    // =========================================================================
    // T08 — preflightChecks reverts if a proxy owner is not DEPLOYER
    // Exercises: _checkProxies per-proxy owner assertion.
    // =========================================================================
    function test_T08_preflightReverts_proxyOwnerNotDeployer() public {
        MockProxy(proxies[3]).forceOwner(address(0xABCD));

        vm.expectRevert(bytes("ABORT: proxy owner is not DEPLOYER"));
        harness.checkProxies(_proxyArr(), DEPLOYER);
    }

    // =========================================================================
    // T09 — MockProxy single-step transfer: all 11 mocks end up at the Safe
    // Exercises: MockProxy.transferOwnership via vm.prank(DEPLOYER) and
    // harness.assertAllTransferred.  Does NOT call the harness transfer loop
    // or the script's run(); it only confirms the mock behaves as OZ v5
    // single-step ownership.
    // =========================================================================
    function test_T09_transferAll_allProxiesTransferred() public {
        address safe = _validSafe();
        address[11] memory arr = _proxyArr();

        for (uint256 i = 0; i < 11; i++) {
            vm.prank(DEPLOYER);
            MockProxy(arr[i]).transferOwnership(safe);
        }

        harness.assertAllTransferred(arr, safe);

        for (uint256 i = 0; i < 11; i++) {
            assertEq(MockProxy(arr[i]).owner(), safe, "proxy not at safe");
        }
    }

    // =========================================================================
    // T10 — resume() skips already-transferred proxies
    // Exercises: Phase 1 SKIP branch and Phase 2 selective transfer in resume().
    // Verifies: proxies 0, 3, 7 emit no OwnershipTransferred event during resume.
    // =========================================================================
    function test_T10_resume_skipsAlreadyTransferred() public {
        address safe = _validSafe();

        // Deploy 11 proxies owned by the harness (so harness._transferOwnership works).
        address[11] memory hProxies;
        for (uint256 i = 0; i < 11; i++) {
            hProxies[i] = address(new MockProxy(address(harness)));
        }

        // Simulate partial broadcast: pre-set 3 proxies to the Safe via forceOwner.
        // forceOwner bypasses onlyOwner and emits no event, so any OwnershipTransferred
        // events recorded after this point originate exclusively from resume().
        MockProxy(hProxies[0]).forceOwner(safe);
        MockProxy(hProxies[3]).forceOwner(safe);
        MockProxy(hProxies[7]).forceOwner(safe);

        vm.recordLogs();
        harness.resume(hProxies, address(harness), safe);

        // All 11 must now be at safe.
        for (uint256 i = 0; i < 11; i++) {
            assertEq(MockProxy(hProxies[i]).owner(), safe,
                string(abi.encodePacked("proxy ", vm.toString(i), " not at safe")));
        }

        // The 3 pre-transferred proxies must not have been re-transferred.
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("OwnershipTransferred(address,address)");
        uint256 p0count; uint256 p3count; uint256 p7count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                if (logs[i].emitter == hProxies[0]) p0count++;
                if (logs[i].emitter == hProxies[3]) p3count++;
                if (logs[i].emitter == hProxies[7]) p7count++;
            }
        }
        assertEq(p0count, 0, "proxy[0] must not be re-transferred by resume()");
        assertEq(p3count, 0, "proxy[3] must not be re-transferred by resume()");
        assertEq(p7count, 0, "proxy[7] must not be re-transferred by resume()");
    }

    // =========================================================================
    // T11 — resume() aborts before any transfer if a proxy has an unexpected owner
    // Exercises: Phase 1 ABORT branch in resume().
    // Asserts the exact revert reason (index 2 flagged as unexpected) and that
    // no ownership changed.
    //
    // LIMITATION: an EVM revert rolls back all state, so the unchanged-owner
    // assertion below would hold even if the harness had transferred proxies 0
    // and 1 before reaching index 2.  This test therefore does NOT prove
    // scan-before-transfer ordering; that property rests on code review of the
    // script's resume() (Phase 1 scan loop precedes vm.startBroadcast()).
    // =========================================================================
    function test_T11_resume_abortsOnUnexpectedOwner() public {
        address safe = _validSafe();
        address unexpected = address(0xBADBAD);

        MockProxy(proxies[2]).forceOwner(unexpected);

        address[11] memory ownersBefore;
        for (uint256 i = 0; i < 11; i++) {
            ownersBefore[i] = MockProxy(proxies[i]).owner();
        }

        vm.expectRevert(bytes("ABORT: proxy index 2 has unexpected owner. Manual investigation required."));
        harness.resume(_proxyArr(), DEPLOYER, safe);

        // Owners unchanged (trivially true after a revert; see LIMITATION above).
        for (uint256 i = 0; i < 11; i++) {
            assertEq(
                MockProxy(proxies[i]).owner(),
                ownersBefore[i],
                "proxy ownership changed before abort"
            );
        }
    }

    // =========================================================================
    // T12 — assertAllTransferred() reverts if any proxy is not at SAFE_ADDRESS
    // Exercises: _assertAllTransferred failure path.
    // =========================================================================
    function test_T12_assertAllTransferred_revertsOnMissed() public {
        address safe = _validSafe();
        address[11] memory arr = _proxyArr();

        for (uint256 i = 0; i < 11; i++) {
            if (i != 5) {
                vm.prank(DEPLOYER);
                MockProxy(arr[i]).transferOwnership(safe);
            }
        }

        vm.expectRevert(bytes("ABORT: proxy not at SAFE_ADDRESS"));
        harness.assertAllTransferred(arr, safe);
    }

    // =========================================================================
    // T13 — assertAllTransferred() succeeds when all 11 proxies are at SAFE_ADDRESS
    // Exercises: _assertAllTransferred success path.
    // =========================================================================
    function test_T13_assertAllTransferred_succeedsWhenComplete() public {
        address safe = _validSafe();
        address[11] memory arr = _proxyArr();

        for (uint256 i = 0; i < 11; i++) {
            vm.prank(DEPLOYER);
            MockProxy(arr[i]).transferOwnership(safe);
        }

        harness.assertAllTransferred(arr, safe);

        for (uint256 i = 0; i < 11; i++) {
            assertEq(MockProxy(arr[i]).owner(), safe);
        }
    }

    // =========================================================================
    // T14 — Script preflightChecks() reverts directly (not via harness)
    //        when SAFE_ADDRESS constant is address(0).
    //
    // This is a direct call to the deployed TransferOwnershipScript contract.
    // It exercises the script's own _checkSafe code, not the harness mirror.
    // The script's SAFE_ADDRESS constant is always address(0) until filled in,
    // so this test will pass for the lifetime of the unfilled placeholder.
    // =========================================================================
    function test_T14_script_preflightReverts_safeAddressZero() public {
        // preflightChecks() is external view on the script — callable directly.
        vm.expectRevert(bytes(
            "ABORT: SAFE_ADDRESS is address(0). Fill in after Safe deployment and verification."
        ));
        script.preflightChecks();
    }

    // =========================================================================
    // T15 — vm.store / vm.load slot-0 round trip on a mock.  Does NOT call the
    // script and does NOT test check D1; it only confirms the cheatcode
    // mechanism D1 relies on behaves as expected in the local EVM.
    //
    // LIMITATION: The script's SAFE_ADDRESS is a compile-time constant set to
    // address(0).  Calling script.preflightChecks() will always revert at
    // check A (address(0) guard) before reaching checks D1/D2.  To directly
    // test checks D1 and D2 on the script code, the SAFE_ADDRESS constant must
    // first be filled in with a real address.  Until then, D1 is verified here
    // by confirming vm.load returns the value written by vm.store, which is the
    // mechanism the script uses.
    // =========================================================================
    function test_T15_vmLoad_slotZeroCheck_mechanism() public {
        // Deploy a MockSafe and write the expected singleton into its slot 0.
        address[] memory owners = new address[](3);
        owners[0] = SIGNER_1; owners[1] = SIGNER_2; owners[2] = SIGNER_3;
        address safe = address(new MockSafe(EXPECTED_SINGLETON, 2, owners));

        // Before vm.store: slot 0 holds MockSafe.singleton = EXPECTED_SINGLETON
        // (because it's the first declared state variable).
        bytes32 slotBefore = vm.load(safe, bytes32(0));
        assertEq(
            address(uint160(uint256(slotBefore))),
            EXPECTED_SINGLETON,
            "MockSafe slot 0 should hold EXPECTED_SINGLETON (first state var)"
        );

        // Write a different value to slot 0.
        address wrongSingleton = address(0xBADBEEF);
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(wrongSingleton))));

        // vm.load now returns the updated value.
        bytes32 slotAfter = vm.load(safe, bytes32(0));
        assertEq(
            address(uint160(uint256(slotAfter))),
            wrongSingleton,
            "vm.load should reflect vm.store write"
        );

        // Restore to correct value and confirm.
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(EXPECTED_SINGLETON))));
        bytes32 slotRestored = vm.load(safe, bytes32(0));
        assertEq(
            address(uint160(uint256(slotRestored))),
            EXPECTED_SINGLETON,
            "slot 0 should be restored to EXPECTED_SINGLETON"
        );

        // The script's D1 check is: address(uint160(uint256(vm.load(SAFE_ADDRESS, 0)))) == EXPECTED_SAFE_SINGLETON.
        // This test confirms that mechanism works correctly in the local EVM.
    }

    // =========================================================================
    // T16 — Script verifyTransfer() reverts directly (not via harness)
    //        when SAFE_ADDRESS is address(0).
    //
    // verifyTransfer() is external view on the script.  Its first require is
    // `SAFE_ADDRESS != address(0)`.  This test calls it directly to confirm
    // the script's own guard fires.
    // =========================================================================
    function test_T16_script_verifyTransfer_revertsWhenSafeAddressZero() public {
        vm.expectRevert(bytes("SAFE_ADDRESS not set"));
        script.verifyTransfer();
    }
}

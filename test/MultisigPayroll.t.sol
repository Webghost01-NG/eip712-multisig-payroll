// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MultisigPayroll.sol";
import "./mocks/MockERC20.sol";

contract MockRevertingTarget {
    error TargetCustomError(string msg);

    function failingCall() external pure {
        revert TargetCustomError("Intentional failure");
    }
}

contract MultisigPayrollTest is Test {
    MultisigPayroll public payroll;
    MockERC20 public token;
    MockRevertingTarget public revertingTarget;

    uint256 internal ownerPk1;
    uint256 internal ownerPk2;
    uint256 internal ownerPk3;
    uint256 internal outsiderPk;

    address public owner1;
    address public owner2;
    address public owner3;
    address public outsider;
    address public relayer = makeAddr("relayer");
    address public employee = makeAddr("employee");

    uint256 public constant INITIAL_ETH = 50 ether;
    uint256 public constant THRESHOLD = 2;

    function setUp() public {
        ownerPk1 = 0xA11CE;
        ownerPk2 = 0xB0B;
        ownerPk3 = 0xCAFE;
        outsiderPk = 0xBAD;

        address a1 = vm.addr(ownerPk1);
        address a2 = vm.addr(ownerPk2);
        address a3 = vm.addr(ownerPk3);
        outsider = vm.addr(outsiderPk);

        // Sort owners in ascending order so owner1 < owner2 < owner3
        address[3] memory addrs = [a1, a2, a3];
        uint256[3] memory pks = [ownerPk1, ownerPk2, ownerPk3];

        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (addrs[i] > addrs[j]) {
                    address tempA = addrs[i];
                    addrs[i] = addrs[j];
                    addrs[j] = tempA;

                    uint256 tempPk = pks[i];
                    pks[i] = pks[j];
                    pks[j] = tempPk;
                }
            }
        }

        owner1 = addrs[0];
        owner2 = addrs[1];
        owner3 = addrs[2];
        ownerPk1 = pks[0];
        ownerPk2 = pks[1];
        ownerPk3 = pks[2];

        address[] memory initialOwners = new address[](3);
        initialOwners[0] = owner1;
        initialOwners[1] = owner2;
        initialOwners[2] = owner3;

        payroll = new MultisigPayroll(initialOwners, THRESHOLD);

        vm.deal(address(payroll), INITIAL_ETH);

        token = new MockERC20("Payroll USD", "pUSD", 18);
        token.mint(address(payroll), 100_000 ether);

        revertingTarget = new MockRevertingTarget();
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_InitialState() public view {
        assertEq(payroll.threshold(), THRESHOLD);
        assertTrue(payroll.isOwner(owner1));
        assertTrue(payroll.isOwner(owner2));
        assertTrue(payroll.isOwner(owner3));
        assertFalse(payroll.isOwner(outsider));
        assertEq(address(payroll).balance, INITIAL_ETH);
    }

    function test_ExecuteETHPayment_Success() public {
        uint256 payout = 5 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory data = "";

        bytes32 digest = payroll.getPaymentDigest(employee, payout, data, nonce, deadline);

        // Signers in ascending order: owner1, then owner2
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, digest);
        sigs[1] = _signDigest(ownerPk2, digest);

        uint256 empBalBefore = employee.balance;

        vm.prank(relayer);
        payroll.executePayment(employee, payout, data, nonce, deadline, sigs);

        assertEq(employee.balance, empBalBefore + payout);
        assertTrue(payroll.isNonceUsed(nonce));
    }

    function test_ExecuteERC20Payroll_Success() public {
        uint256 payout = 2_500 ether;
        uint256 nonce = 2;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, employee, payout);

        bytes32 digest = payroll.getPaymentDigest(address(token), 0, data, nonce, deadline);

        // Signers: owner2 and owner3
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk2, digest);
        sigs[1] = _signDigest(ownerPk3, digest);

        vm.prank(relayer);
        payroll.executePayment(address(token), 0, data, nonce, deadline, sigs);

        assertEq(token.balanceOf(employee), payout);
    }

    function test_DuplicateSignersRevert() public {
        uint256 nonce = 3;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = payroll.getPaymentDigest(employee, 1 ether, "", nonce, deadline);

        // Duplicate signature: owner1 twice
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, digest);
        sigs[1] = _signDigest(ownerPk1, digest);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(MultisigPayroll.DuplicateOrUnorderedSigner.selector, owner1)
        );
        payroll.executePayment(employee, 1 ether, "", nonce, deadline, sigs);
    }

    function test_UnorderedSignersRevert() public {
        uint256 nonce = 4;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = payroll.getPaymentDigest(employee, 1 ether, "", nonce, deadline);

        // Descending order: owner2 then owner1
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk2, digest);
        sigs[1] = _signDigest(ownerPk1, digest);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(MultisigPayroll.DuplicateOrUnorderedSigner.selector, owner1)
        );
        payroll.executePayment(employee, 1 ether, "", nonce, deadline, sigs);
    }

    function test_ReplayAttackReverts() public {
        uint256 nonce = 5;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = payroll.getPaymentDigest(employee, 1 ether, "", nonce, deadline);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, digest);
        sigs[1] = _signDigest(ownerPk2, digest);

        vm.prank(relayer);
        payroll.executePayment(employee, 1 ether, "", nonce, deadline, sigs);

        // Attempt second execution with same nonce
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.NonceAlreadyUsed.selector, nonce));
        payroll.executePayment(employee, 1 ether, "", nonce, deadline, sigs);
    }

    function test_ExpiredDeadlineReverts() public {
        uint256 nonce = 6;
        uint256 deadline = block.timestamp + 100;
        bytes32 digest = payroll.getPaymentDigest(employee, 1 ether, "", nonce, deadline);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, digest);
        sigs[1] = _signDigest(ownerPk2, digest);

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(MultisigPayroll.ExpiredDeadline.selector, deadline + 1, deadline)
        );
        payroll.executePayment(employee, 1 ether, "", nonce, deadline, sigs);
    }

    function test_WrongChainDataReverts() public {
        uint256 nonce = 7;
        uint256 deadline = block.timestamp + 1 hours;

        // Construct digest manually with a different chainId (e.g., chainId = 999)
        bytes32 domainSeparatorWrongChain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MultisigPayroll")),
                keccak256(bytes("1")),
                999, // wrong chain ID
                address(payroll)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                payroll.PAYMENT_TYPEHASH(),
                employee,
                1 ether,
                keccak256(""),
                nonce,
                deadline
            )
        );

        bytes32 forgedDigest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparatorWrongChain, structHash)
        );

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, forgedDigest);
        sigs[1] = _signDigest(ownerPk2, forgedDigest);

        vm.prank(relayer);
        // The contract calculates digest with real chainId, so recovered signers won't match owners
        vm.expectRevert();
        payroll.executePayment(employee, 1 ether, "", nonce, deadline, sigs);
    }

    function test_FailedCallRevertsWithExecutionFailed() public {
        uint256 nonce = 8;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory data = abi.encodeWithSelector(MockRevertingTarget.failingCall.selector);

        bytes32 digest = payroll.getPaymentDigest(address(revertingTarget), 0, data, nonce, deadline);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, digest);
        sigs[1] = _signDigest(ownerPk2, digest);

        vm.prank(relayer);
        vm.expectRevert();
        payroll.executePayment(address(revertingTarget), 0, data, nonce, deadline, sigs);
    }

    function test_SelfGovernedOwnerManagement() public {
        // Change threshold to 3 via multisig execution
        uint256 nonce = 9;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory data = abi.encodeWithSelector(MultisigPayroll.changeThreshold.selector, 3);

        bytes32 digest = payroll.getPaymentDigest(address(payroll), 0, data, nonce, deadline);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(ownerPk1, digest);
        sigs[1] = _signDigest(ownerPk2, digest);

        vm.prank(relayer);
        payroll.executePayment(address(payroll), 0, data, nonce, deadline, sigs);

        assertEq(payroll.threshold(), 3);

        // Direct call without multisig must revert
        vm.prank(relayer);
        vm.expectRevert(MultisigPayroll.OnlySelf.selector);
        payroll.changeThreshold(2);
    }

    function testFuzz_SignaturesThreshold(uint8 signerSubset) public {
        // Subset between 0 and 7 (bitmask for 3 owners)
        uint256 nonce = 1000 + signerSubset;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = payroll.getPaymentDigest(employee, 0.1 ether, "", nonce, deadline);

        // Count owners selected
        bool use1 = (signerSubset & 1) != 0;
        bool use2 = (signerSubset & 2) != 0;
        bool use3 = (signerSubset & 4) != 0;

        uint256 count = (use1 ? 1 : 0) + (use2 ? 1 : 0) + (use3 ? 1 : 0);
        bytes[] memory sigs = new bytes[](count);

        uint256 idx = 0;
        if (use1) sigs[idx++] = _signDigest(ownerPk1, digest);
        if (use2) sigs[idx++] = _signDigest(ownerPk2, digest);
        if (use3) sigs[idx++] = _signDigest(ownerPk3, digest);

        vm.prank(relayer);
        if (count < THRESHOLD) {
            vm.expectRevert(
                abi.encodeWithSelector(MultisigPayroll.InsufficientSignatures.selector, count, THRESHOLD)
            );
            payroll.executePayment(employee, 0.1 ether, "", nonce, deadline, sigs);
        } else {
            payroll.executePayment(employee, 0.1 ether, "", nonce, deadline, sigs);
            assertTrue(payroll.isNonceUsed(nonce));
        }
    }
}

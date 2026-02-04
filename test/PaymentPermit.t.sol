// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/PaymentPermit.sol";
import "./MockERC20.sol";
import "../contracts/interface/IPaymentPermit.sol";
import "../contracts/libraries/PermitHash.sol";

contract PaymentPermitTest is Test {
    using PermitHash for IPaymentPermit.PaymentPermitDetails;

    PaymentPermit public paymentPermit;
    MockERC20 public token;

    uint256 internal ownerPrivateKey;
    address internal owner;
    address internal receiver;
    address internal feeReceiver;

    bytes32 internal DOMAIN_SEPARATOR;

    // TypeHashes from library
    bytes32 public constant PERMIT_META_TYPEHASH =
        PermitHash.PERMIT_META_TYPEHASH;
    bytes32 public constant PAYMENT_TYPEHASH = PermitHash.PAYMENT_TYPEHASH;
    bytes32 public constant FEE_TYPEHASH = PermitHash.FEE_TYPEHASH;
    bytes32 public constant DELIVERY_TYPEHASH = PermitHash.DELIVERY_TYPEHASH;
    bytes32 public constant PAYMENT_PERMIT_DETAILS_TYPEHASH =
        PermitHash.PAYMENT_PERMIT_DETAILS_TYPEHASH;

    function setUp() public {
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        receiver = address(0xB0B);
        feeReceiver = address(0xFEE);

        paymentPermit = new PaymentPermit();
        token = new MockERC20("Test Token", "TEST", 18);

        DOMAIN_SEPARATOR = paymentPermit.DOMAIN_SEPARATOR();

        token.mint(owner, 1000 ether);

        vm.prank(owner);
        token.approve(address(paymentPermit), type(uint256).max);
    }

    function testPermitTransferFrom() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            1 ether,
            address(0xCA11EB)
        );
        bytes memory signature = _signPermit(permit);

        IPaymentPermit.TransferDetails memory transferDetails = IPaymentPermit
            .TransferDetails({
                amount: 50 ether // Transfer less than max
            });

        vm.prank(address(0xCA11EB)); // Arbitrary caller
        paymentPermit.permitTransferFrom(
            permit,
            transferDetails,
            owner,
            signature
        );

        assertEq(token.balanceOf(owner), 1000 ether - 50 ether - 1 ether);
        assertEq(token.balanceOf(receiver), 50 ether);
        assertEq(token.balanceOf(feeReceiver), 1 ether);

        assertTrue(paymentPermit.nonceUsed(owner, permit.meta.nonce));
    }

    function testRevertNonceUsed() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        IPaymentPermit.TransferDetails memory transferDetails = IPaymentPermit
            .TransferDetails(100 ether);

        paymentPermit.permitTransferFrom(
            permit,
            transferDetails,
            owner,
            signature
        );

        vm.expectRevert(IPaymentPermit.NonceAlreadyUsed.selector);
        paymentPermit.permitTransferFrom(
            permit,
            transferDetails,
            owner,
            signature
        );
    }

    function testRevertExpired() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        permit.meta.validBefore = block.timestamp - 1;

        bytes memory signature = _signPermit(permit);
        vm.expectRevert(IPaymentPermit.InvalidTimestamp.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            owner,
            signature
        );
    }

    function testRevertSignatureError() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        // Tamper with data
        permit.payment.maxPayAmount = 200 ether;

        vm.expectRevert(IPaymentPermit.InvalidSignature.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            owner,
            signature
        );
    }

    function testRevertBuyerMismatch() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        vm.expectRevert(IPaymentPermit.BuyerMismatch.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            address(0xDEAD),
            signature
        );
    }

    function testRevertInvalidKind_Normal() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        permit.meta.kind = 1; // Wrong kind for normal transfer
        bytes memory signature = _signPermit(permit);

        vm.expectRevert(IPaymentPermit.InvalidKind.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            owner,
            signature
        );
    }

    function testRevertInvalidCaller() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        vm.prank(address(0xBAD));
        vm.expectRevert(IPaymentPermit.InvalidCaller.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            owner,
            signature
        );
    }

    function testRevertInvalidAmount() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        vm.expectRevert(IPaymentPermit.InvalidAmount.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(101 ether), // Exceeds maxPayAmount
            owner,
            signature
        );
    }

    function testRevertNotYetValid() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        permit.meta.validAfter = block.timestamp + 10;
        bytes memory signature = _signPermit(permit);

        vm.expectRevert(IPaymentPermit.InvalidTimestamp.selector);
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            owner,
            signature
        );
    }

    function testZeroFee() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0, // Zero fee
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(50 ether),
            owner,
            signature
        );

        assertEq(token.balanceOf(owner), 1000 ether - 50 ether);
        assertEq(token.balanceOf(receiver), 50 ether);
        assertEq(token.balanceOf(feeReceiver), 0);
    }

    function testPaymentTransferFailed() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            0,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        // Mock transferFrom to return false for payment
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(
                token.transferFrom.selector,
                owner,
                receiver,
                100 ether
            ),
            abi.encode(false)
        );

        vm.expectRevert("Payment failed");
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(100 ether),
            owner,
            signature
        );
    }

    function testFeeTransferFailed() public {
        IPaymentPermit.PaymentPermitDetails memory permit = _createPermit(
            100 ether,
            1 ether,
            address(this)
        );
        bytes memory signature = _signPermit(permit);

        // Mock transferFrom to return false for fee
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(
                token.transferFrom.selector,
                owner,
                feeReceiver,
                1 ether
            ),
            abi.encode(false)
        );

        vm.expectRevert("Fee failed");
        paymentPermit.permitTransferFrom(
            permit,
            IPaymentPermit.TransferDetails(50 ether),
            owner,
            signature
        );
    }

    // Helpers
    function _createPermit(
        uint256 amount,
        uint256 fee,
        address caller
    ) internal view returns (IPaymentPermit.PaymentPermitDetails memory) {
        return
            IPaymentPermit.PaymentPermitDetails({
                meta: IPaymentPermit.PermitMeta({
                    kind: 0,
                    paymentId: bytes16(0),
                    nonce: 0,
                    validAfter: 0,
                    validBefore: block.timestamp + 1000
                }),
                buyer: owner,
                caller: caller,
                payment: IPaymentPermit.Payment({
                    payToken: address(token),
                    maxPayAmount: amount,
                    payTo: receiver
                }),
                fee: IPaymentPermit.Fee({feeTo: feeReceiver, feeAmount: fee}),
                delivery: IPaymentPermit.Delivery({
                    receiveToken: address(0),
                    miniReceiveAmount: 0,
                    tokenId: 0
                })
            });
    }

    function _signPermit(
        IPaymentPermit.PaymentPermitDetails memory permit
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, permit.hash())
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

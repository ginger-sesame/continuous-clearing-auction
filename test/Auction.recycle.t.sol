// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ContinuousClearingAuction} from '../src/ContinuousClearingAuction.sol';
import {AuctionParameters, IContinuousClearingAuction} from '../src/interfaces/IContinuousClearingAuction.sol';
import {IStepStorage} from '../src/interfaces/IStepStorage.sol';
import {Bid} from '../src/libraries/BidLib.sol';
import {FixedPoint96} from '../src/libraries/FixedPoint96.sol';
import {ERC20Mock} from '@openzeppelin/contracts/mocks/token/ERC20Mock.sol';
import {Test} from 'forge-std/Test.sol';
import {IPermit2} from 'permit2/src/interfaces/IPermit2.sol';
import {DeployPermit2} from 'permit2/test/utils/DeployPermit2.sol';

contract AuctionRecycleTest is Test {
    uint256 constant Q96 = FixedPoint96.Q96;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant FUNDS = address(0xF00D);
    address constant TOKENS = address(0x7000);
    ERC20Mock token;

    function setUp() public {
        token = new ERC20Mock();
        vm.deal(ALICE, 1000 ether);
        vm.deal(BOB, 1000 ether);
    }

    function deploy(uint128 threshold) internal returns (ContinuousClearingAuction auction) {
        return deployWith(threshold, 100 ether, address(0), address(0));
    }

    function deployWith(uint128 threshold, uint128 supply, address hook, address currency)
        internal
        returns (ContinuousClearingAuction auction)
    {
        AuctionParameters memory params = AuctionParameters({
            currency: currency,
            tokensRecipient: TOKENS,
            fundsRecipient: FUNDS,
            startBlock: 100,
            endBlock: 200,
            claimBlock: 200,
            tickSpacing: Q96 / 2,
            validationHook: hook,
            floorPrice: Q96 / 2,
            requiredCurrencyRaised: threshold,
            auctionStepsData: abi.encodePacked(uint24(100_000), uint40(100))
        });
        auction = new ContinuousClearingAuction(address(token), supply, params, address(0));
        token.mint(address(auction), supply);
        auction.onTokensReceived();
    }

    function bid(ContinuousClearingAuction auction, address owner, uint128 amount, uint256 price)
        internal
        returns (uint256)
    {
        vm.prank(owner);
        return auction.submitBid{value: amount}(price, amount, owner, '');
    }

    function seed(ContinuousClearingAuction auction) internal {
        vm.roll(100);
        bid(auction, ALICE, 100 ether, Q96);
        vm.roll(110);
        bid(auction, BOB, 100 ether, 3 * Q96);
        vm.roll(111);
    }

    function recycle(ContinuousClearingAuction auction, uint128 amount) internal returns (uint256) {
        vm.prank(ALICE);
        return auction.recycleOutbidBid(0, amount, 3 * Q96, Q96 / 2, 100, 111);
    }

    function finish(ContinuousClearingAuction auction) internal {
        vm.roll(200);
        auction.checkpoint();
    }

    function test_baselineVersusRecycling_graduationAndSettlement() public {
        ContinuousClearingAuction baseline = deploy(150 ether);
        ContinuousClearingAuction recycled = deploy(150 ether);
        seed(baseline);
        seed(recycled);
        uint256 aliceBefore = ALICE.balance;
        uint256 bobBefore = BOB.balance;
        Bid memory original = recycled.bids(0);
        vm.expectEmit(true, true, false, true, address(recycled));
        emit IContinuousClearingAuction.BidRecycled(0, 2, 90 ether);
        uint256 replacement = recycle(recycled, 90 ether);
        assertEq(abi.encode(recycled.bids(0)), abi.encode(original), 'original bid unchanged');
        assertEq(recycled.recycledAmount(0), 90 ether);
        assertEq(ALICE.balance, aliceBefore);
        assertEq(BOB.balance, bobBefore);
        assertEq(address(baseline).balance, 200 ether);
        assertEq(address(recycled).balance, 200 ether);
        Bid memory fresh = recycled.bids(replacement);
        assertEq(fresh.startBlock, 111);
        assertEq(fresh.startCumulativeMps, 1_100_000);
        assertEq(fresh.amountQ96, uint256(90 ether) * Q96);
        assertEq(fresh.owner, ALICE);
        finish(baseline);
        finish(recycled);
        assertApproxEqAbs(baseline.currencyRaised(), 110 ether, 1);
        assertFalse(baseline.isGraduated());
        assertApproxEqAbs(recycled.currencyRaised(), 200 ether, 1);
        assertTrue(recycled.isGraduated());
        emit log_named_uint('Baseline proceeds (wei)', baseline.currencyRaised());
        emit log_named_uint('Recycled proceeds (wei)', recycled.currencyRaised());

        recycled.exitPartiallyFilledBid(0, 100, 111);
        assertEq(recycled.bids(0).tokensFilled, 10 ether, 'historical partial fills retained');
        recycled.exitBid(1);
        recycled.exitBid(replacement);
        uint256 expectedAliceTokens = 10 ether + recycled.bids(replacement).tokensFilled;
        recycled.claimTokens(0);
        recycled.claimTokens(replacement);
        recycled.claimTokens(1);
        assertEq(token.balanceOf(ALICE), expectedAliceTokens);
        assertApproxEqAbs(token.balanceOf(ALICE) + token.balanceOf(BOB), 100 ether, 3);
        vm.prank(FUNDS);
        recycled.sweepCurrency();
        assertApproxEqAbs(FUNDS.balance, 200 ether, 1);
        assertLe(address(recycled).balance, 1);
        assertEq(ALICE.balance, aliceBefore, 'no recycled credit refunded twice');
    }

    function test_bothFail_refundExactlyExternalDeposits() public {
        ContinuousClearingAuction baseline = deploy(250 ether);
        ContinuousClearingAuction recycled = deploy(250 ether);
        seed(baseline);
        seed(recycled);
        uint256 replacement = recycle(recycled, 90 ether);
        finish(baseline);
        finish(recycled);
        assertFalse(baseline.isGraduated());
        assertFalse(recycled.isGraduated());
        assertApproxEqAbs(baseline.currencyRaised(), 110 ether, 1);
        assertApproxEqAbs(recycled.currencyRaised(), 200 ether, 1);
        uint256 before = ALICE.balance;
        baseline.exitBid(0);
        assertEq(ALICE.balance - before, 100 ether);
        before = ALICE.balance;
        recycled.exitBid(replacement);
        recycled.exitPartiallyFilledBid(0, 100, 111);
        assertEq(ALICE.balance - before, 100 ether);
        baseline.exitBid(1);
        recycled.exitBid(1);
        assertEq(address(baseline).balance, 0);
        assertEq(address(recycled).balance, 0);
        assertEq(ALICE.balance, 1000 ether);
        assertEq(BOB.balance, 1000 ether);
        assertEq(recycled.bids(0).tokensFilled, 0);
        vm.expectRevert(IContinuousClearingAuction.BidAlreadyExited.selector);
        recycled.exitBid(0);
    }

    function test_originalEarlyExitRejected() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        auction.checkpoint();
        assertGt(auction.clearingPrice(), Q96);
        vm.expectRevert(IStepStorage.AuctionIsNotOver.selector);
        auction.exitBid(0);
        vm.expectRevert(IContinuousClearingAuction.CannotPartiallyExitBidBeforeGraduation.selector);
        auction.exitPartiallyFilledBid(0, 100, 111);
    }

    function testFuzz_replacementMatchesFreshMoneyAtSameCheckpoint(uint64 recycleBlock) public {
        recycleBlock = uint64(bound(recycleBlock, 111, 199));
        ContinuousClearingAuction recycled = deploy(150 ether);
        ContinuousClearingAuction fresh = deploy(150 ether);
        seed(recycled);
        seed(fresh);
        recycled.checkpoint();
        fresh.checkpoint();
        vm.roll(recycleBlock);
        uint256 recycledId = recycle(recycled, 90 ether);
        uint256 freshId = bid(fresh, ALICE, 90 ether, 3 * Q96);
        assertEq(abi.encode(recycled.bids(recycledId)), abi.encode(fresh.bids(freshId)));
        assertEq(address(fresh).balance - address(recycled).balance, 90 ether);
        finish(recycled);
        finish(fresh);
        assertEq(recycled.currencyRaised(), fresh.currencyRaised());
        assertEq(recycled.totalCleared(), fresh.totalCleared());
        if (recycled.clearingPrice() < 3 * Q96) {
            recycled.exitBid(recycledId);
            fresh.exitBid(freshId);
        } else {
            assertEq(recycled.clearingPrice(), 3 * Q96);
            recycled.exitPartiallyFilledBid(recycledId, recycleBlock, 0);
            fresh.exitPartiallyFilledBid(freshId, recycleBlock, 0);
        }
        assertEq(recycled.bids(recycledId).tokensFilled, fresh.bids(freshId).tokensFilled);
        recycled.exitPartiallyFilledBid(0, 100, 111);
        fresh.exitPartiallyFilledBid(0, 100, 111);
        assertEq(recycled.bids(0).tokensFilled, fresh.bids(0).tokensFilled);
    }

    function test_activeBidCannotRecycle() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        vm.roll(100);
        bid(auction, ALICE, 100 ether, Q96);
        vm.expectRevert(IContinuousClearingAuction.BidNotStrictlyOutbid.selector);
        recycle(auction, 1);
    }

    function test_bidExactlyAtClearingCannotRecycle() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        vm.roll(100);
        bid(auction, ALICE, 100 ether, Q96);
        vm.roll(110);
        auction.checkpoint();
        assertEq(auction.clearingPrice(), Q96);
        vm.expectRevert(IContinuousClearingAuction.BidNotStrictlyOutbid.selector);
        recycle(auction, 1);
    }

    function test_unauthorizedCaller() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IContinuousClearingAuction.NotAuthorized.selector, ALICE, BOB));
        auction.recycleOutbidBid(0, 90 ether, 3 * Q96, Q96 / 2, 100, 111);
        assertEq(auction.recycledAmount(0), 0);
        assertEq(auction.nextBidId(), 2);
    }

    function test_overdrawAndDoubleRecycleRejected() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        recycle(auction, 90 ether + 1);
        recycle(auction, 90 ether);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        recycle(auction, 1);
        assertEq(auction.nextBidId(), 3);
    }

    function test_zeroAmountRejected() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.expectRevert(IContinuousClearingAuction.BidAmountTooSmall.selector);
        recycle(auction, 0);
    }

    function test_validationHookRejected() public {
        address hook = address(0x1234);
        ContinuousClearingAuction auction = deployWith(150 ether, 100 ether, hook, address(0));
        vm.roll(100);
        // Reject before any hook call, even if that hook would otherwise accept bids.
        vm.expectRevert(IContinuousClearingAuction.RecyclingWithValidationHook.selector);
        recycle(auction, 1);
    }

    function test_invalidReplacementRollsBackCredit() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.prank(ALICE);
        vm.expectRevert(IContinuousClearingAuction.BidMustBeAboveClearingPrice.selector);
        auction.recycleOutbidBid(0, 90 ether, Q96, Q96 / 2, 100, 111);
        assertEq(auction.recycledAmount(0), 0);
        assertEq(auction.nextBidId(), 2);
        recycle(auction, 90 ether);
    }

    function test_invalidHintsRejected() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.startPrank(ALICE);
        vm.expectRevert(IContinuousClearingAuction.InvalidOutbidBlockCheckpointHint.selector);
        auction.recycleOutbidBid(0, 1, 3 * Q96, Q96 / 2, 100, 0);
        vm.expectRevert(IContinuousClearingAuction.InvalidLastFullyFilledCheckpointHint.selector);
        auction.recycleOutbidBid(0, 1, 3 * Q96, Q96 / 2, 110, 111);
        vm.expectRevert(IContinuousClearingAuction.InvalidLastFullyFilledCheckpointHint.selector);
        auction.recycleOutbidBid(0, 1, 3 * Q96, Q96 / 2, 109, 111);
        vm.expectRevert(IContinuousClearingAuction.InvalidOutbidBlockCheckpointHint.selector);
        auction.recycleOutbidBid(0, 1, 3 * Q96, Q96 / 2, 100, 112);
        vm.expectRevert(IContinuousClearingAuction.InvalidOutbidBlockCheckpointHint.selector);
        auction.recycleOutbidBid(0, 1, 3 * Q96, Q96 / 2, 100, 110);
        vm.stopPrank();
        assertEq(auction.recycledAmount(0), 0);
    }

    function test_exitedBidCannotRecycle() public {
        ContinuousClearingAuction auction = deploy(0);
        seed(auction);
        auction.exitPartiallyFilledBid(0, 100, 111);
        vm.expectRevert(IContinuousClearingAuction.BidAlreadyExited.selector);
        recycle(auction, 1);
    }

    function test_endBlockCannotRecycle() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.roll(200);
        vm.expectRevert(IStepStorage.AuctionIsOver.selector);
        recycle(auction, 1);
    }

    function test_creditIsLocalToAuction() public {
        ContinuousClearingAuction first = deploy(250 ether);
        ContinuousClearingAuction second = deploy(250 ether);
        seed(first);
        vm.roll(100);
        bid(second, BOB, 100 ether, Q96);
        vm.roll(110);
        bid(second, ALICE, 100 ether, 3 * Q96);
        vm.roll(111);
        recycle(first, 90 ether);
        vm.expectRevert(abi.encodeWithSelector(IContinuousClearingAuction.NotAuthorized.selector, BOB, ALICE));
        recycle(second, 90 ether);
        assertEq(second.recycledAmount(0), 0);
        assertEq(address(first).balance, 200 ether);
        assertEq(address(second).balance, 200 ether);
    }

    function testFuzz_repeatedRecyclingAndRefundOrder(uint128 firstAmount, bool reverse, bool failed) public {
        firstAmount = uint128(bound(firstAmount, 1, 90 ether - 1));
        ContinuousClearingAuction auction = deploy(failed ? 250 ether : 150 ether);
        seed(auction);
        uint256 first = recycle(auction, firstAmount);
        uint256 second = recycle(auction, 90 ether - firstAmount);
        assertEq(auction.recycledAmount(0), 90 ether);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        recycle(auction, 1);
        finish(auction);
        uint256 before = ALICE.balance;
        if (reverse) {
            auction.exitBid(second);
            auction.exitBid(first);
            auction.exitPartiallyFilledBid(0, 100, 111);
        } else {
            auction.exitPartiallyFilledBid(0, 100, 111);
            auction.exitBid(first);
            auction.exitBid(second);
        }
        auction.exitBid(1);
        assertEq(ALICE.balance - before, failed ? 100 ether : 0);
        assertEq(auction.isGraduated(), !failed);
        if (failed) {
            assertEq(address(auction).balance, 0);
        } else {
            vm.prank(FUNDS);
            auction.sweepCurrency();
            assertLe(address(auction).balance, 1);
        }
    }

    function test_partialRecycleRefundBeforeEndAfterGraduation() public {
        ContinuousClearingAuction auction = deploy(1 ether);
        seed(auction);
        recycle(auction, 40 ether);
        uint256 before = ALICE.balance;
        auction.exitPartiallyFilledBid(0, 100, 111);
        assertEq(ALICE.balance - before, 50 ether);
        assertEq(auction.bids(0).tokensFilled, 10 ether);
        vm.expectRevert(IContinuousClearingAuction.BidAlreadyExited.selector);
        recycle(auction, 1);
        finish(auction);
        auction.exitBid(1);
        auction.exitBid(2);
        vm.prank(FUNDS);
        auction.sweepCurrency();
        assertApproxEqAbs(FUNDS.balance, 150 ether, 1);
        assertLe(address(auction).balance, 1);
    }

    function testFuzz_fractionalSpendRoundsAvailableDown(uint8 extraWei, bool failed) public {
        extraWei = uint8(bound(extraWei, 1, 9));
        // Below max throughout the first 10%: spent = (100 ether + extraWei) / 10.
        ContinuousClearingAuction auction = deployWith(failed ? 250 ether : 0, 101 ether, address(0), address(0));
        vm.roll(100);
        bid(auction, ALICE, 100 ether + extraWei, Q96);
        vm.roll(110);
        bid(auction, BOB, 100 ether, 3 * Q96);
        vm.roll(111);
        uint128 available = 90 ether + extraWei - 1;
        vm.prank(ALICE);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        auction.recycleOutbidBid(0, available + 1, 3 * Q96, Q96 / 2, 110, 111);
        vm.prank(ALICE);
        auction.recycleOutbidBid(0, available, 3 * Q96, Q96 / 2, 110, 111);
        finish(auction);
        uint256 before = ALICE.balance;
        auction.exitPartiallyFilledBid(0, 110, 111);
        auction.exitBid(2);
        auction.exitBid(1);
        assertEq(ALICE.balance - before, failed ? 100 ether + extraWei : 0);
        if (failed) {
            assertEq(address(auction).balance, 0);
        } else {
            vm.prank(FUNDS);
            auction.sweepCurrency();
            assertLe(address(auction).balance, 2);
        }
    }

    function testFuzz_descendantRecycling(bool failed, bool reverse) public {
        ContinuousClearingAuction auction = deploy(failed ? 400 ether : 0);
        seed(auction);
        vm.prank(ALICE);
        uint256 child = auction.recycleOutbidBid(0, 90 ether, 3 * Q96 / 2, Q96, 100, 111);
        vm.roll(120);
        uint256 bobSecond = bid(auction, BOB, 100 ether, 5 * Q96);
        assertEq(auction.clearingPrice(), 3 * Q96 / 2);
        vm.roll(121);
        auction.checkpoint();
        assertGt(auction.clearingPrice(), 3 * Q96 / 2);
        // Child spent approximately 3.5 ETH at clearing between blocks 111 and 120.
        // Round the residual down by one wei to account for Q96 rounding.
        uint128 residual = 86.5 ether - 1;
        vm.prank(ALICE);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        auction.recycleOutbidBid(child, 90 ether, 5 * Q96, 3 * Q96, 111, 121);
        vm.prank(ALICE);
        uint256 grandchild = auction.recycleOutbidBid(child, residual, 5 * Q96, 3 * Q96, 111, 121);
        vm.prank(ALICE);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        auction.recycleOutbidBid(child, residual, 5 * Q96, 3 * Q96, 111, 121);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        recycle(auction, 1);
        assertEq(address(auction).balance, 300 ether);
        finish(auction);
        uint256 before = ALICE.balance;
        if (reverse) {
            auction.exitBid(grandchild);
            auction.exitPartiallyFilledBid(child, 111, 121);
            auction.exitPartiallyFilledBid(0, 100, 111);
        } else {
            auction.exitPartiallyFilledBid(0, 100, 111);
            auction.exitPartiallyFilledBid(child, 111, 121);
            auction.exitBid(grandchild);
        }
        if (failed) {
            auction.exitBid(1);
            auction.exitBid(bobSecond);
            assertEq(ALICE.balance - before, 100 ether);
            assertEq(ALICE.balance, 1000 ether);
            assertEq(BOB.balance, 1000 ether);
            assertEq(address(auction).balance, 0);
        } else {
            // Bob's first bid finishes exactly at clearing.
            assertEq(auction.clearingPrice(), 3 * Q96);
            auction.exitPartiallyFilledBid(1, 121, 0);
            auction.exitBid(bobSecond);
            assertLe(ALICE.balance - before, 1);
            assertEq(auction.bids(0).tokensFilled, 10 ether);
            assertApproxEqAbs(auction.bids(child).tokensFilled, uint256(3.5 ether) * 2 / 3, 1);
            for (uint256 i; i < auction.nextBidId(); ++i) {
                auction.claimTokens(i);
            }
            vm.prank(FUNDS);
            auction.sweepCurrency();
            assertLe(address(auction).balance, 5);
        }
    }

    function test_sameSubmissionCheckpointOutbid_hasNoHistoricalFill() public {
        ContinuousClearingAuction auction = deploy(0);
        vm.roll(100);
        bid(auction, ALICE, 100 ether, Q96);
        bid(auction, BOB, 200 ether, 5 * Q96);
        vm.roll(101);
        vm.prank(ALICE);
        uint256 child = auction.recycleOutbidBid(0, 100 ether, 5 * Q96, Q96 / 2, 100, 101);
        auction.exitPartiallyFilledBid(0, 100, 101);
        assertEq(auction.bids(0).tokensFilled, 0);
        assertEq(auction.bids(child).startBlock, 101);
        finish(auction);
        auction.exitBid(1);
        auction.exitBid(child);
        vm.prank(FUNDS);
        auction.sweepCurrency();
        assertApproxEqAbs(FUNDS.balance, 300 ether, 1);
        assertLe(address(auction).balance, 1);
    }

    function test_zeroUnspentBalanceCannotRecycle() public {
        // A tiny bid spends a fractional wei before it is outbid, leaving no whole wei credit.
        ContinuousClearingAuction auction = deployWith(0, 10, address(0), address(0));
        vm.roll(100);
        bid(auction, ALICE, 1, Q96);
        vm.roll(110);
        bid(auction, BOB, 20, 5 * Q96);
        vm.roll(111);
        vm.prank(ALICE);
        vm.expectRevert(IContinuousClearingAuction.InsufficientUnspentBalance.selector);
        auction.recycleOutbidBid(0, 1, 5 * Q96, Q96 / 2, 110, 111);
    }

    function testFuzz_erc20CreditStaysInAuction(bool failed) public {
        IPermit2 permit2 = IPermit2(new DeployPermit2().deployPermit2());
        ERC20Mock currency = new ERC20Mock();
        ContinuousClearingAuction auction =
            deployWith(failed ? 250 ether : 150 ether, 100 ether, address(0), address(currency));
        currency.mint(ALICE, 100 ether);
        currency.mint(BOB, 100 ether);
        vm.roll(100);
        vm.startPrank(ALICE);
        currency.approve(address(permit2), 100 ether);
        permit2.approve(address(currency), address(auction), uint160(100 ether), type(uint48).max);
        auction.submitBid(Q96, 100 ether, ALICE, '');
        vm.stopPrank();
        vm.roll(110);
        vm.startPrank(BOB);
        currency.approve(address(permit2), 100 ether);
        permit2.approve(address(currency), address(auction), uint160(100 ether), type(uint48).max);
        auction.submitBid(3 * Q96, 100 ether, BOB, '');
        vm.stopPrank();
        vm.roll(111);
        recycle(auction, 90 ether);
        assertEq(currency.balanceOf(ALICE), 0);
        assertEq(currency.balanceOf(BOB), 0);
        assertEq(currency.balanceOf(address(auction)), 200 ether);
        assertEq(address(auction).balance, 0);
        finish(auction);
        auction.exitPartiallyFilledBid(0, 100, 111);
        auction.exitBid(1);
        auction.exitBid(2);
        assertEq(currency.balanceOf(ALICE), failed ? 100 ether : 0);
        assertEq(currency.balanceOf(BOB), failed ? 100 ether : 0);
        vm.prank(FUNDS);
        auction.sweepCurrency();
        assertApproxEqAbs(currency.balanceOf(FUNDS), failed ? 0 : 200 ether, 1);
        assertLe(currency.balanceOf(address(auction)), 1);
    }

    function test_recycleCannotAcceptExternalETH() public {
        ContinuousClearingAuction auction = deploy(150 ether);
        seed(auction);
        vm.prank(ALICE);
        (bool success,) = address(auction).call{value: 1}(
            abi.encodeCall(auction.recycleOutbidBid, (0, 90 ether, 3 * Q96, Q96 / 2, 100, 111))
        );
        assertFalse(success);
        assertEq(address(auction).balance, 200 ether);
        assertEq(auction.recycledAmount(0), 0);
    }
}

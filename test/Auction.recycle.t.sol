// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ContinuousClearingAuction} from '../src/ContinuousClearingAuction.sol';
import {AuctionParameters, IContinuousClearingAuction} from '../src/interfaces/IContinuousClearingAuction.sol';
import {Bid} from '../src/libraries/BidLib.sol';
import {Checkpoint} from '../src/libraries/CheckpointLib.sol';
import {FixedPoint96} from '../src/libraries/FixedPoint96.sol';
import {ERC20Mock} from '@openzeppelin/contracts/mocks/token/ERC20Mock.sol';
import {Test} from 'forge-std/Test.sol';

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
        vm.expectRevert(IContinuousClearingAuction.CannotPartiallyExitBidBeforeGraduation.selector);
        auction.exitPartiallyFilledBid(0, 100, 111);
    }

    function test_replacementMatchesFreshMoneyAtSameCheckpoint() public {
        ContinuousClearingAuction recycled = deploy(150 ether);
        ContinuousClearingAuction fresh = deploy(150 ether);
        seed(recycled);
        seed(fresh);
        uint256 recycledId = recycle(recycled, 90 ether);
        uint256 freshId = bid(fresh, ALICE, 90 ether, 3 * Q96);
        assertEq(abi.encode(recycled.bids(recycledId)), abi.encode(fresh.bids(freshId)));
        assertEq(address(fresh).balance - address(recycled).balance, 90 ether);
        finish(recycled);
        finish(fresh);
        assertEq(recycled.currencyRaised(), fresh.currencyRaised());
        assertEq(recycled.totalCleared(), fresh.totalCleared());
        recycled.exitBid(recycledId);
        fresh.exitBid(freshId);
        assertEq(recycled.bids(recycledId).tokensFilled, fresh.bids(freshId).tokensFilled);
        recycled.exitPartiallyFilledBid(0, 100, 111);
        fresh.exitPartiallyFilledBid(0, 100, 111);
        assertEq(recycled.bids(0).tokensFilled, fresh.bids(0).tokensFilled);
    }
}

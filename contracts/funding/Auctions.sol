/*

    Copyright 2019 The Hydro Protocol Foundation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./LendingPool.sol";
import "../lib/Store.sol";
import "../lib/SafeMath.sol";
import "../lib/Types.sol";
import "../lib/Events.sol";
import "../lib/Decimal.sol";
import "../lib/Transfer.sol";

library Auctions {
    using SafeMath for uint256;
    using Auction for Types.Auction;

    function fillAuctionWithRatioLessOrEqualThanOne(
        Store.State storage state,
        Types.Auction storage auction,
        uint256 ratio,
        uint256 repayAmount
    )
        internal
        returns (uint256, uint256) // bidderRepay collateral
    {
        uint256 leftDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        uint256 leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];

        state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = SafeMath.add(
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset],
            repayAmount
        );

        uint256 actualRepay = LendingPool.repay(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            repayAmount
        );

        state.balances[msg.sender][auction.debtAsset] = SafeMath.sub(
            state.balances[msg.sender][auction.debtAsset],
            actualRepay
        );

        if (actualRepay < repayAmount) {
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = 0;
        }

        uint256 collateralToProcess = leftCollateralAmount.mul(actualRepay).div(leftDebtAmount);
        uint256 collateralForBidder = Decimal.mulFloor(collateralToProcess, ratio);

        uint256 collateralForInitiator = Decimal.mulFloor(collateralToProcess.sub(collateralForBidder), state.auction.initiatorRewardRatio);
        uint256 collateralForBorrower = collateralToProcess.sub(collateralForBidder).sub(collateralForInitiator);

        // update collateralAmount
        state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset] = SafeMath.sub(
            state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset],
            collateralToProcess
        );

        // bidder receive collateral
        state.balances[msg.sender][auction.collateralAsset] = SafeMath.add(
            state.balances[msg.sender][auction.collateralAsset],
            collateralForBidder
        );

        // initiator receive collateral
        state.balances[auction.initiator][auction.collateralAsset] = SafeMath.add(
            state.balances[auction.initiator][auction.collateralAsset],
            collateralForInitiator
        );

        // auction.borrower receive collateral
        state.balances[auction.borrower][auction.collateralAsset] = SafeMath.add(
            state.balances[auction.borrower][auction.collateralAsset],
            collateralForBorrower
        );

        Events.logFillAuction(auction.id, repayAmount);
        return (actualRepay, collateralForBidder);
    }

    // Msg.sender only need to afford bidderRepayAmount and get collateralAmount
    // insurance and suppliers will cover the badDebtAmount
    function fillAuctionWithRatioGreaterThanOne(
        Store.State storage state,
        Types.Auction storage auction,
        uint256 ratio,
        uint256 bidderRepayAmount
    )
        internal
        returns (uint256, uint256) // bidderRepay collateral
    {
        uint256 leftDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        uint256 leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];

        uint256 repayAmount = Decimal.mulFloor(bidderRepayAmount, ratio);

        state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = SafeMath.add(
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset],
            repayAmount
        );

        uint256 actualRepay = LendingPool.repay(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            repayAmount
        );

        uint256 actualBidderRepay = bidderRepayAmount;
        if (actualRepay < repayAmount) {
            actualBidderRepay = Decimal.divCeil(actualRepay, ratio);
        }

        // gather repay capital
        LendingPool.compensate(state, auction.debtAsset, actualRepay.sub(actualBidderRepay));

        state.balances[msg.sender][auction.debtAsset] = SafeMath.sub(
            state.balances[msg.sender][auction.debtAsset],
            actualBidderRepay
        );

        // update collateralAmount
        uint256 collateralForBidder = leftCollateralAmount.mul(actualRepay).div(leftDebtAmount);

        state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset] = SafeMath.sub(
            state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset],
            collateralForBidder
        );

        // bidder receive collateral
        state.balances[msg.sender][auction.collateralAsset] = SafeMath.add(
            state.balances[msg.sender][auction.collateralAsset],
            collateralForBidder
        );

        return (repayAmount, collateralForBidder);
    }

    // ensure repay no more than repayAmount
    function fillAuctionWithAmount(
        Store.State storage state,
        uint32 auctionID,
        uint256 repayAmount
    )
        external
    {
        Types.Auction storage auction = state.auction.auctions[auctionID];
        uint256 ratio = auction.ratio(state);

        if (ratio<=Decimal.one()){
            fillAuctionWithRatioLessOrEqualThanOne(state, auction, ratio, repayAmount);
        } else {
            fillAuctionWithRatioGreaterThanOne(state, auction, ratio, repayAmount);
        }

        // reset account state if all debts are paid
        uint256 leftDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );
        if (leftDebtAmount == 0) {
            endAuction(state, auction);
        }
    }

    function endAuction(
        Store.State storage state,
        Types.Auction storage auction
    )
        internal
    {
        auction.status = Types.AuctionStatus.Finished;

        Types.CollateralAccount storage account = state.accounts[auction.borrower][auction.marketID];
        account.status = Types.CollateralAccountStatus.Normal;

        for (uint i = 0; i < state.auction.currentAuctions.length; i++){
            if (state.auction.currentAuctions[i] == auction.id){
                state.auction.currentAuctions[i] = state.auction.currentAuctions[state.auction.currentAuctions.length-1];
                state.auction.currentAuctions.length--;
            }
        }

        Events.logAuctionFinished(auction.id);
    }

    /**
     * Create an auction and save it in global state
     *
     */
    function create(
        Store.State storage state,
        uint16 marketID,
        address borrower,
        address initiator,
        address debtAsset,
        address collateralAsset
    )
        internal
        returns (uint32)
    {
        uint32 id = state.auction.auctionsCount++;

        Types.Auction memory auction = Types.Auction({
            id: id,
            status: Types.AuctionStatus.InProgress,
            startBlockNumber: uint32(block.number),
            marketID: marketID,
            borrower: borrower,
            initiator: initiator,
            debtAsset: debtAsset,
            collateralAsset: collateralAsset
        });

        state.auction.auctions[id] = auction;
        state.auction.currentAuctions.push(id);

        Events.logAuctionCreate(id);

        return id;
    }

    function getAuctionDetails(
        Store.State storage state,
        uint32 auctionID
    )
        internal
        view
        returns (Types.AuctionDetails memory details)
    {
        Types.Auction memory auction = state.auction.auctions[auctionID];

        details.debtAsset = auction.debtAsset;
        details.collateralAsset = auction.collateralAsset;

        details.leftDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        details.leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];
        details.ratio = auction.ratio(state);
    }
}
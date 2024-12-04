// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusWrapperConsumerBase.sol";
import "./chainlink/VRFV2PlusClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./lib/TreasureHuntLib.sol";

contract ProcessFacet is VRFV2PlusWrapperConsumerBase {
    event RequestFulfilled(uint256 requestId, uint256[] randomWords, uint256 payment);
    event SpotResult(
        uint256 gameId,
        SpotInfo spotInfo,
        uint256 tileNetCostInAmount,
        uint256 referralFeeAmount,
        uint256 refereeFeeAmount,
        uint256 ticketNum
    );
    event EndGame(uint256 gameId);
    event TreasureFound(uint256 gameId, uint256 tile, address winner, address[] assets, uint256[] amounts, string userUid);

    struct LocalProcessStruct {
        uint256 tileCostInAmount;
        uint256 tileNetCostInAmount;
        uint256 treasuryFeeAmount;
        uint256 referralFeeAmount;
        uint256 refereeFeeAmount;
        uint256 ticketNum;
        address[] potAssets;
        uint256[] potAmounts;
    }

    function _processResult(uint256 requestId) internal {
        RequestStatus memory requestStatus = requests[requestId];
        require(requestStatus.fulfilled, 'Request Not Fulfilled');
        uint256 gameId = requestStatus.gameId;
        GameInfo memory gameInfo = gameInfos[gameId];
        GameMetaInfo storage gameMetaInfo = gameMetaInfos[gameId];
        for (uint256 index = 0; index < requestStatus.randomWords.length; index++) {
            LocalProcessStruct memory localStruct;
            uint256 tile = requestStatus.tiles[index];
            localStruct.tileCostInAmount = requestStatus.tileCostsInAmount[index];
            // If the request is sent before all treasures and tickets are found, it will be transferred to the treasury.
            if (
                gameMetaInfo.leftNumTreasureTile == 0
                && gameMetaInfo.leftNumTicketTile == 0
                && requestStatus.blockNumber < gameMetaInfo.distributedAllBlockNumber
            ) {
                if (!spotInfos[gameId][tile].isOpened) {
                    _setSpotResult(gameId, tile, TileType.NONE, localStruct.tileCostInAmount, requestStatus.paidAsset, requestStatus.user, requestStatus.userUid);
                }

                if (spotInfos[gameId][tile].withReferral) {
                    (localStruct.refereeFeeAmount, localStruct.referralFeeAmount) = _processReferralFee(spotInfos[gameId][tile].referralUser, requestStatus.user, requestStatus.paidAsset, localStruct.tileCostInAmount);
                }   
                
                pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] = pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] - localStruct.tileCostInAmount ;
                globalPendingPots[requestStatus.paidAsset] = globalPendingPots[requestStatus.paidAsset] - localStruct.tileCostInAmount;
                IERC20(requestStatus.paidAsset).transfer(treasury, localStruct.tileCostInAmount);
                continue;
            }

            // The actual point at which the fee is charged.
            if (spotInfos[gameId][tile].withReferral) {
                (localStruct.refereeFeeAmount, localStruct.referralFeeAmount) = _processReferralFee(spotInfos[gameId][tile].referralUser, requestStatus.user, requestStatus.paidAsset, localStruct.tileCostInAmount);
            }

            localStruct.treasuryFeeAmount = TreasureHuntLib.calculateRatio(localStruct.tileCostInAmount, treasuryFeeRatio);
            localStruct.tileNetCostInAmount = localStruct.tileCostInAmount - (localStruct.treasuryFeeAmount - localStruct.referralFeeAmount - localStruct.refereeFeeAmount);

            pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] = pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] - localStruct.tileCostInAmount;
            globalPendingPots[requestStatus.paidAsset] = globalPendingPots[requestStatus.paidAsset] - localStruct.tileCostInAmount;
            IERC20(requestStatus.paidAsset).transfer(treasury, localStruct.tileCostInAmount - localStruct.tileNetCostInAmount);
            pots[requestStatus.paidAsset] = pots[requestStatus.paidAsset] + localStruct.tileNetCostInAmount;

            TileType result = _checkResult(
                requestStatus.randomWords[index],
                gameMetaInfo.leftSpots,
                gameMetaInfo.leftNumTreasureTile,
                gameMetaInfo.leftNumTicketTile
            );
            gameMetaInfo.leftSpots = gameMetaInfo.leftSpots - 1;
            _setSpotResult(gameId, tile, result, localStruct.tileCostInAmount, requestStatus.paidAsset, requestStatus.user, requestStatus.userUid);

            if (result == TileType.TICKET && gameMetaInfo.leftNumTicketTile != 0) {
                localStruct.ticketNum = _calculateTicketNum(requestStatus.randomWords[index], gameInfo.minTicketNum, gameInfo.maxTicketNum, gameMetaInfo.leftNumTicket, gameMetaInfo.leftNumTicketTile);
                spotInfos[gameId][tile].ticketNum = localStruct.ticketNum;
                gameMetaInfo.leftNumTicket = gameMetaInfo.leftNumTicket - localStruct.ticketNum;
                gameMetaInfo.leftNumTicketTile = gameMetaInfo.leftNumTicketTile - 1;
                gameMetaInfo.ticketTiles.push(tile);
            }

            if (result == TileType.TREASURE && gameMetaInfo.leftNumTreasureTile != 0) {
                gameMetaInfo.treasureTile = tile;
                gameMetaInfo.leftNumTreasureTile = gameMetaInfo.leftNumTreasureTile - 1;
                _processTreasure(gameMetaInfo);
            }

            emit SpotResult(
                gameId,
                spotInfos[gameId][tile],
                localStruct.tileNetCostInAmount,
                localStruct.referralFeeAmount,
                localStruct.refereeFeeAmount,
                localStruct.ticketNum
            );
        }

        if (!gameMetaInfo.isPlaying) {
            gameInfos[gameId] = gameInfo;
            return;
        }

        if (gameMetaInfo.leftSpots == 0) {
            _endGame(gameMetaInfo);
        } else if (gameMetaInfo.leftNumTreasureTile == 0 && gameMetaInfo.leftNumTicketTile == 0) {
            _endGame(gameMetaInfo);
        } else if (
            gameMetaInfo.leftSpots == 1 
            && gameMetaInfo.treasureTile == type(uint256).max
            && gameMetaInfo.leftNumTreasureTile > 0
        ) {
            uint256 treasureTile = getUnopenedTiles(gameId)[0];
            _setSpotResult(gameId, treasureTile, TileType.TREASURE, 0, address(0), address(0), "");
            gameMetaInfo.leftSpots = 0;
            gameMetaInfo.leftNumTreasureTile = 0;
            gameMetaInfo.treasureTile = treasureTile;
            _processTreasure(gameMetaInfo);
            _endGame(gameMetaInfo);
        }
        gameMetaInfos[gameId] = gameMetaInfo;
    }

    function getUnopenedTiles(uint256 gameId) public view returns (uint256[] memory) {
        GameInfo memory gameInfo = gameInfos[gameId];
        GameMetaInfo memory gameMetaInfo = gameMetaInfos[gameId];
        uint256[] memory unopenedTiles = new uint256[](gameMetaInfo.leftSpots);
        uint256 counter = 0;
        for (uint256 index = 0; index < gameInfo.totalSpots; index++) {
            if (!spotInfos[gameId][index].isOpened) {
                unopenedTiles[counter] = index;
                counter++;
            }
        }

        return unopenedTiles;
    }

    function _endGame(GameMetaInfo storage gameMetaInfo) internal {
        gameMetaInfo.isPlaying = false;
        gameMetaInfo.distributedAllBlockNumber = block.number;
        emit EndGame(gameMetaInfo.id);
    }

    function _processTreasure(GameMetaInfo storage gameMetaInfo) internal {
        address winner = spotInfos[gameMetaInfo.id][gameMetaInfo.treasureTile].user;
        string memory userUid = spotInfos[gameMetaInfo.id][gameMetaInfo.treasureTile].userUid;
        if (winner != address(0)) {
            uint256[] memory _prizes = new uint256[](assetList.length);
            for (uint256 index = 0; index < assetList.length; index++) {
                address asset = assetList[index];
                _prizes[index] = pots[asset];
                winnerPrizes[gameMetaInfo.id][asset] = pots[asset];
                userClaimableAmounts[winner][asset] = userClaimableAmounts[winner][asset] + pots[asset];
                globalUserClaimableAmounts[asset] = globalUserClaimableAmounts[asset] + pots[asset];
                pots[asset] = 0;
            }
            emit TreasureFound(gameMetaInfo.id, gameMetaInfo.treasureTile, winner, assetList, _prizes, userUid);
            return;
        }
        emit TreasureFound(gameMetaInfo.id, gameMetaInfo.treasureTile, address(0), assetList, new uint256[](assetList.length), userUid);
    }

    function _processReferralFee(address referralUser, address refereeUser, address paidAsset, uint256 tileCostInAmount) internal returns (uint256, uint256) {
        (uint256 refereeFeeAmount, uint256 referralFeeAmount) = _calculateReferralFee(referralUser, tileCostInAmount);
        userTreasury[refereeUser][paidAsset] = userTreasury[refereeUser][paidAsset] + refereeFeeAmount;
        userTreasury[referralUser][paidAsset] = userTreasury[referralUser][paidAsset] + referralFeeAmount;
        globalUserTreasury[paidAsset] = globalUserTreasury[paidAsset] + refereeFeeAmount + referralFeeAmount;
        return (refereeFeeAmount, referralFeeAmount);
    }

    function _calculateReferralFee(address referralUser, uint256 tileCostInAmount) internal view returns (uint256, uint256) {
        if (predefinedReferralUsers[referralUser]) {
            return (
                TreasureHuntLib.calculateRatio(tileCostInAmount, predefinedRefereeFeeRatio), 
                TreasureHuntLib.calculateRatio(tileCostInAmount, predefinedReferralFeeRatio)
            );
        } else {
            return (
                TreasureHuntLib.calculateRatio(tileCostInAmount, refereeFeeRatio),
                TreasureHuntLib.calculateRatio(tileCostInAmount, referralFeeRatio)
            );
        }
    }

    function _checkResult(uint256 randomNumber, uint256 leftSpots, uint256 leftNumTreasureTile, uint256 leftNumTicketTile) internal pure returns (TileType) {
        if (leftSpots == leftNumTicketTile) {
            return TileType.TICKET;
        }

        if (leftSpots == leftNumTreasureTile) {
            return TileType.TREASURE;
        }

        uint256 result = randomNumber % leftSpots;
        if (leftNumTreasureTile != 0 && result == 0) {
            return TileType.TREASURE;
        }
        if (result > 0 && result <= leftNumTicketTile) {
            return TileType.TICKET;
        }
        return TileType.NONE;
    }

    function _calculateTicketNum(
        uint256 randomNumber,
        uint256 minTicketNum,
        uint256 maxTicketNum,
        uint256 leftNumTicket,
        uint256 leftNumTicketTile
    ) internal pure returns (uint256) {
        if (leftNumTicket == 0 || leftNumTicketTile == 0) {
            return 0;
        }

        uint256 maxAssignable = leftNumTicket >= (leftNumTicketTile - 1) * minTicketNum 
            ? leftNumTicket - (leftNumTicketTile - 1) * minTicketNum 
            : minTicketNum;

        uint256 minAssignable = leftNumTicket >= (leftNumTicketTile - 1) * maxTicketNum 
            ? leftNumTicket - (leftNumTicketTile - 1) * maxTicketNum 
            : minTicketNum;
        
        uint256 range = maxTicketNum - minTicketNum + 1;
        uint256 result = (randomNumber % range) + minTicketNum;
        result = result > maxAssignable ? maxAssignable : result;
        result = result < minAssignable ? minAssignable : result;
        return result;
    }


    function _setSpotResult(
        uint256 gameId,
        uint256 tile,
        TileType tileType,
        uint256 tileCostInAmount,
        address asset,
        address user,
        string memory userUid
    ) internal {
        spotInfos[gameId][tile].isOpened = true;
        spotInfos[gameId][tile].tile = tile;
        spotInfos[gameId][tile].tileType = tileType;
        spotInfos[gameId][tile].tileCostInAmount = tileCostInAmount;
        spotInfos[gameId][tile].asset = asset;
        spotInfos[gameId][tile].user = user;
        spotInfos[gameId][tile].userUid = userUid;
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        require(requests[_requestId].requestPaid > 0, "request not found");
        requests[_requestId].fulfilled = true;
        requests[_requestId].randomWords = _randomWords;
        _processResult(_requestId);
        emit RequestFulfilled(_requestId, _randomWords, requests[_requestId].requestPaid);
    }
}

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
        address user,
        string userUid,
        uint256 tile,
        TileType tileType,
        address asset,
        address referralUser,
        uint256 tileCostInAmount,
        uint256 tileNetCostInAmount
    );
    event EndGame(uint256 gameId);
    event TreasureFound(uint256 gameId, uint256 tile, address winner, address[] assets, uint256[] amounts, string userUid);

    struct LocalProcessStruct {
        uint256 tileCostInAmount;
        uint256 treasureRatio;
        uint256 tileNetCostInAmount;
    }

    function _processResult(uint256 requestId) internal {
        RequestStatus memory requestStatus = requests[requestId];
        require(requestStatus.fulfilled, 'Request Not Fulfilled');
        uint256 gameId = requestStatus.gameId;
        GameInfo storage gameInfo = gameInfos[gameId];
        LocalProcessStruct memory localStruct;
        for (uint256 index = 0; index < requestStatus.randomWords.length; index++) {
            uint256 tile = requestStatus.tiles[index];
            localStruct.tileCostInAmount = requestStatus.tileCostsInAmount[index];
            // If the request is sent before all treasures and tickets are found, it will be transferred to the treasury.
            if (
                gameInfo.leftNumTreasure == 0
                && gameInfo.leftNumTicket == 0
                && requestStatus.blockNumber < gameInfo.distributedAllBlockNumber
            ) {
                if (!spotInfos[gameId][tile].isOpened) {
                    _setSpotResult(gameId, tile, TileType.NONE, localStruct.tileCostInAmount, requestStatus.paidAsset, requestStatus.user, requestStatus.userUid);
                }

                pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] = pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] - localStruct.tileCostInAmount;
                IERC20(requestStatus.paidAsset).transfer(treasury, localStruct.tileCostInAmount);
                continue;
            }

            // The actual point at which the fee is charged.
            localStruct.treasureRatio = 10;
            if (gameInfo.numTicket == 0) {
                localStruct.treasureRatio = 30;
            }
            localStruct.tileNetCostInAmount = TreasureHuntLib.calculateRatio(localStruct.tileCostInAmount, 100 - localStruct.treasureRatio);
            pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] = pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] - localStruct.tileCostInAmount;
            IERC20(requestStatus.paidAsset).transfer(treasury, localStruct.tileCostInAmount - localStruct.tileNetCostInAmount);
            pots[requestStatus.paidAsset] = pots[requestStatus.paidAsset] + localStruct.tileNetCostInAmount;
            if (spotInfos[gameId][tile].withReferral) {
                userTreasury[requestStatus.user][requestStatus.paidAsset] = userTreasury[requestStatus.user][requestStatus.paidAsset] + TreasureHuntLib.calculateRatio(localStruct.tileCostInAmount, 4);
                userTreasury[spotInfos[gameId][tile].referralUser][requestStatus.paidAsset] = userTreasury[spotInfos[gameId][tile].referralUser][requestStatus.paidAsset] + TreasureHuntLib.calculateRatio(localStruct.tileCostInAmount, 4);
            }

            TileType result = _checkResult(requestStatus.randomWords[index]
            , gameInfo.leftSpots, gameInfo.leftNumTreasure, gameInfo.leftNumTicket);
            gameInfo.leftSpots = gameInfo.leftSpots - 1;
            _setSpotResult(gameId, tile, result, localStruct.tileCostInAmount, requestStatus.paidAsset, requestStatus.user, requestStatus.userUid);

            if (result == TileType.TICKET && gameInfo.leftNumTicket != 0) {
                gameInfo.leftNumTicket = gameInfo.leftNumTicket - 1;
                gameInfo.ticketTiles.push(tile);
            }

            if (result == TileType.TREASURE && gameInfo.leftNumTreasure != 0) {
                gameInfo.treasureTile = tile;
                gameInfo.leftNumTreasure = gameInfo.leftNumTreasure - 1;
                _processTreasure(gameInfo);
            }
            emit SpotResult(
                gameId,
                spotInfos[gameId][tile].user,
                spotInfos[gameId][tile].userUid,
                tile,
                result,
                spotInfos[gameId][tile].asset,
                spotInfos[gameId][tile].referralUser,
                spotInfos[gameId][tile].tileCostInAmount,
                localStruct.tileNetCostInAmount
            );
        }

        if (!gameInfo.isPlaying) {
            gameInfos[gameId] = gameInfo;
            return;
        }

        if (gameInfo.leftSpots == 0) {
            _endGame(gameInfo);
        } else if (gameInfo.leftNumTreasure == 0 && gameInfo.leftNumTicket == 0) {
            _endGame(gameInfo);
        } else if (gameInfo.leftSpots == 1 && gameInfo.treasureTile == type(uint256).max) {
            uint256 treasureTile = getUnopenedTiles(gameId)[0];
            _setSpotResult(gameId, treasureTile, TileType.TREASURE, 0, address(0), address(0), "");
            gameInfo.leftSpots = 0;
            gameInfo.leftNumTreasure = 0;
            gameInfo.treasureTile = treasureTile;
            _processTreasure(gameInfo);
            _endGame(gameInfo);
        }
        gameInfos[gameId] = gameInfo;
    }

    function getUnopenedTiles(uint256 gameId) public view returns (uint256[] memory) {
        GameInfo memory gameInfo = gameInfos[gameId];
        uint256[] memory unopenedTiles = new uint256[](gameInfo.leftSpots);
        uint256 counter = 0;
        for (uint256 index = 0; index < gameInfo.totalSpots; index++) {
            if (!spotInfos[gameId][index].isOpened) {
                unopenedTiles[counter] = index;
                counter++;
            }
        }

        return unopenedTiles;
    }

    function _endGame(GameInfo storage gameInfo) internal {
        gameInfo.isPlaying = false;
        gameInfo.distributedAllBlockNumber = block.number;
        emit EndGame(gameInfo.id);
    }

    function _processTreasure(GameInfo storage gameInfo) internal {
        address winner = spotInfos[gameInfo.id][gameInfo.treasureTile].user;
        string memory userUid = spotInfos[gameInfo.id][gameInfo.treasureTile].userUid;
        if (winner != address(0)) {
            uint256[] memory _prizes = new uint256[](assetList.length);
            for (uint256 index = 0; index < assetList.length; index++) {
                address asset = assetList[index];
                _prizes[index] = pots[asset];
                winnerPrizes[gameInfo.id][asset] = pots[asset];
                userClaimableAmounts[winner][asset] = userClaimableAmounts[winner][asset] + pots[asset];
                pots[asset] = 0;
            }
            emit TreasureFound(gameInfo.id, gameInfo.treasureTile, winner, assetList, _prizes, userUid);
            return;
        }
        emit TreasureFound(gameInfo.id, gameInfo.treasureTile, address(0), assetList, new uint256[](assetList.length), userUid);
    }

    function _checkResult(uint256 randomNumber, uint256 leftSpots, uint256 leftNumTreasure, uint256 leftNumTicket) internal pure returns (TileType) {
        if (leftSpots == leftNumTicket) {
            return TileType.TICKET;
        }

        if (leftSpots == leftNumTreasure) {
            return TileType.TREASURE;
        }

        uint256 result = randomNumber % leftSpots;
        if (leftNumTreasure != 0 && result == 0) {
            return TileType.TREASURE;
        }
        if (result > 0 && result <= leftNumTicket) {
            return TileType.TICKET;
        }
        return TileType.NONE;
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

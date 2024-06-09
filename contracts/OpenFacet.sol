// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusWrapperConsumerBase.sol";
import "./chainlink/VRFV2PlusClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./lib/TreasureHuntLib.sol";
import "./lib/BokkyPooBahsDateTimeLibrary.sol";
import "./BaseFacet.sol";

contract OpenFacet is BaseFacet {
    using ECDSA for bytes32;

    event OpenSpot(
        address user,
        uint256 gameId,
        uint256[] tiles,
        uint256 openCostInAmount,
        address paidAsset,
        uint256 requestId
    );

    event Claim(address user, address[] assets, uint256[] amounts);
    event ClaimPendingAsset(address user, address[] assets, uint256[] amounts);
    event ClaimPrivateTreasury(address user, address[] assets, uint256[] amounts);
    event ClaimTwitter(address user, uint256 gameId, uint256 tile, address asset, uint256 amount);

    struct LocalOpenSpotStruct {
        uint256 unopenedTileCount;
        uint256 unopenedTileIndex;
        uint256 actualTileCount;
        uint256 accumulatedTileCostInAmount;
        uint256 treasuryRatio;
        uint256[] tileCostsInAmount;
        uint256[] unopenedTiles;
        uint256[] actualTiles;
        uint256[] actualTileCostsInAmount;
        uint256 actualPaidInAmount;
    }

    function openSpotWithReferral(
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmount,
        string memory userUid,
        address referralUser,
        uint256 nonce,
        bytes memory signature
    ) external {
        require(referralUser != address(0), 'Invalid Referral User');
        address user = msg.sender;
        require(user != referralUser, 'Not Allowed to Refer Yourself');
        require(!referralNonce[user][nonce], 'Already Used Nonce');
        _verifyReferralSignature(uidOwner, userUid, referralUser, nonce, signature);
        referralNonce[user][nonce] = true;
        _openSpot(user, userUid, gameId, tiles, asset, maxAvgAmount, referralUser);
    }

    function openSpotWithUID(
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmount,
        string memory userUid,
        uint256 nonce,
        bytes memory signature
    ) external {
        address user = msg.sender;
        require(!uidNonce[userUid][nonce], 'Already Used Nonce');
        _verifyUidSignature(uidOwner, userUid, nonce, signature);
        uidNonce[userUid][nonce] = true;
        _openSpot(user, userUid, gameId, tiles, asset, maxAvgAmount, address(0));
    }

    function openSpot(
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmount
    ) external {
        address user = msg.sender;
        _openSpot(user, "", gameId, tiles, asset, maxAvgAmount, address(0));
    }

    function _openSpot(
        address user,
        string memory userUid,
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmount,
        address referralUser
    ) internal {
        GameInfo storage gameInfo = gameInfos[gameId];
        require(tiles.length >= 1 && tiles.length <= gameInfo.maxTilesOpenableAtOnce, 'Invalid Tile Size');
        require(gameInfo.isPlaying, 'Game Not in Progress');
        require(block.timestamp <= gameInfo.startTime + maxGameTime, 'Already Ended Game');
        require(gameInfo.leftNumTicket != 0 || gameInfo.leftNumTreasure != 0, 'No Ticket And Treasure');

        LocalOpenSpotStruct memory localStruct;
        for (uint256 i = 0; i < tiles.length; i++) {
            if (spotInfos[gameId][tiles[i]].tileType == TileType.CLOSED) {
                localStruct.unopenedTileCount++;
            }
        }
        require(localStruct.unopenedTileCount > 0, 'No Unopened Tile');

        localStruct.unopenedTiles = new uint256[](localStruct.unopenedTileCount);
        for (uint256 i = 0; i < tiles.length; i++) {
            if (spotInfos[gameId][tiles[i]].tileType == TileType.CLOSED) {
                localStruct.unopenedTiles[localStruct.unopenedTileIndex] = tiles[i];
                localStruct.unopenedTileIndex++;
            }
        }

        localStruct.tileCostsInAmount = calculateTileCostsInAmount(asset, gameId, localStruct.unopenedTileCount);
        for (uint256 i = 0; i < localStruct.unopenedTileCount; i++) {
            uint256 tile = localStruct.unopenedTiles[i];
            require(tile < gameInfo.totalSpots, 'Invalid Tile');
            localStruct.accumulatedTileCostInAmount = localStruct.accumulatedTileCostInAmount + localStruct.tileCostsInAmount[i];
            if (localStruct.accumulatedTileCostInAmount <= maxAvgAmount * (i + 1)) {
                localStruct.actualTileCount++;
            }
        }

        require(localStruct.actualTileCount != 0, 'No Tiles Available for Purchase');
        localStruct.accumulatedTileCostInAmount = 0;
        localStruct.actualTiles = new uint256[](localStruct.actualTileCount);
        localStruct.actualTileCostsInAmount = new uint256[](localStruct.actualTileCount);
        uint256 index = 0;
        for (uint256 i = 0; i < localStruct.unopenedTileCount; i++) {
            localStruct.accumulatedTileCostInAmount = localStruct.accumulatedTileCostInAmount + localStruct.tileCostsInAmount[i];
            if (localStruct.accumulatedTileCostInAmount <= maxAvgAmount * (i + 1)) {
                localStruct.actualTiles[index] = localStruct.unopenedTiles[i];
                localStruct.actualTileCostsInAmount[index] = localStruct.tileCostsInAmount[i];
                localStruct.actualPaidInAmount = localStruct.actualPaidInAmount + localStruct.tileCostsInAmount[i];
                spotInfos[gameId][localStruct.unopenedTiles[i]].tileType = TileType.OCCUPIED;
                spotInfos[gameId][localStruct.unopenedTiles[i]].asset = asset;
                spotInfos[gameId][localStruct.unopenedTiles[i]].tileCostInAmount = localStruct.tileCostsInAmount[i];
                if (referralUser != address(0)) {
                    spotInfos[gameId][localStruct.unopenedTiles[i]].withReferral = true;
                    spotInfos[gameId][localStruct.unopenedTiles[i]].referralUser = referralUser;
                }
                index++;
            }
        }

        pendingPots[gameId][user][asset] = pendingPots[gameId][user][asset] + localStruct.actualPaidInAmount;
        IERC20(asset).transferFrom(user, address(this), localStruct.actualPaidInAmount);
        uint256 requestId = _makeVrfNative(
            user,
            userUid,
            gameId,
            localStruct.actualTiles,
            localStruct.actualTileCostsInAmount,
            localStruct.actualPaidInAmount,
            asset
        );
        emit OpenSpot(user, gameId, localStruct.actualTiles, localStruct.actualPaidInAmount, asset, requestId);
    }

    function getTiles(uint256 gameId) public view returns (SpotInfo[] memory, address[] memory, uint256[] memory) {
        GameInfo memory gameInfo = gameInfos[gameId];
        SpotInfo[] memory tiles = new SpotInfo[](gameInfo.totalSpots);
        for (uint256 index = 0; index < gameInfo.totalSpots; index++) {
            tiles[index] = spotInfos[gameId][index];
        }

        (address[] memory _assets, uint256[] memory _amounts) = _getPotInfo();

        return (tiles, _assets, _amounts);
    }

    function claim() external {
        uint256[] memory _amounts = new uint256[](assetList.length);
        for (uint256 index = 0; index < assetList.length; index++) {
            address asset = assetList[index];
            uint256 amount = userClaimableAmounts[msg.sender][asset];
            _amounts[index] = amount;
            if (amount > 0) {
                userClaimableAmounts[msg.sender][asset] = 0;
                IERC20(asset).transfer(msg.sender, amount);
            }
        }
        emit Claim(msg.sender, assetList, _amounts);
    }

    // ref: https://docs.chain.link/vrf/v2-5/billing#estimate-gas-costs
    // ref: https://docs.chain.link/vrf/v2-5/supported-networks
    // callbackGasLimit must not exceed maxGasLimit - wrapperGasOverhead.
    function _makeVrfNative(
        address _user,
        string memory _userUid,
        uint256 _gameId,
        uint256[] memory _tiles,
        uint256[] memory _tileCostsInAmount,
        uint256 _paidInAmount,
        address _paidAsset
    ) internal returns (uint256 requestId) {
        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment : true}));
        uint256 requestPaid;
        require(address(this).balance >= i_vrfV2PlusWrapper.calculateRequestPriceNative(callbackGasLimit, uint32(_tiles.length)), 'Insufficient Balance for VRF Request');
        (requestId, requestPaid) = requestRandomnessPayInNative(callbackGasLimit, requestConfirmations, uint32(_tiles.length), extraArgs);
        requests[requestId] = RequestStatus({
            requestPaid : requestPaid,
            randomWords : new uint256[](0),
            tiles : _tiles,
            tileCostsInAmount : _tileCostsInAmount,
            fulfilled : false,
            gameId : _gameId,
            user : _user,
            userUid: _userUid,
            paidInAmount: _paidInAmount,
            paidAsset: _paidAsset,
            blockNumber: block.number
        });
        return requestId;
    }

    function getWinnerPrize(uint256 gameId) public view returns(address[] memory, uint256[] memory) {
        uint256[] memory amounts = new uint256[](assetList.length);
        for (uint256 index = 0; index < assetList.length; index++) {
            address asset = assetList[index];
            amounts[index] = winnerPrizes[gameId][asset];
        }
        return (assetList, amounts);
    }

    function getGameOverview(uint256 _gameId) external view returns (
        uint256 gameId,
        uint256 startTime,
        SpotInfo[] memory tiles,
        address[] memory potAssets,
        uint256[] memory potAmounts,
        address[] memory winnerAssets,
        uint256[] memory winnerAmounts,
        uint256 leftNumTicket,
        bool isPlaying
    ) {
        GameInfo memory gameInfo = gameInfos[_gameId];
        (tiles, potAssets, potAmounts) = getTiles(_gameId);
        (winnerAssets, winnerAmounts) = getWinnerPrize(_gameId);
        gameId = _gameId;
        startTime = gameInfo.startTime;
        leftNumTicket = gameInfo.leftNumTicket;
        isPlaying = gameInfo.isPlaying;
    }

    function calculateTileCostsInAmount(address asset, uint256 gameId, uint256 tileCount) public view returns (uint256[] memory) {
        uint256[] memory tileCostsInUsd = calculateTileCostsInUsd(gameId, tileCount);
        uint256[] memory tileCostsInAmount = new uint256[](tileCount);
        for (uint256 index = 0; index < tileCostsInUsd.length; index++) {
            tileCostsInAmount[index] = getAmountFromUsd(asset, tileCostsInUsd[index]);
        }
        return tileCostsInAmount;
    }

    function calculateTileCostsInUsd(uint256 gameId, uint256 tileCount) public view returns (uint256[] memory) {
        GameInfo memory gameInfo = gameInfos[gameId];
        require(gameInfo.leftSpots >= tileCount, 'Invalid Tile Count');
        uint256[] memory tileCostsInUsd = new uint256[](tileCount);
        for (uint256 index = 0; index < tileCount; index++) {
            uint256 leftSpots = gameInfo.leftSpots - index;
            tileCostsInUsd[index] = calculateTileCostInUsd(gameInfo.ticketCostInUsd, leftSpots, gameInfo.leftNumTreasure, gameInfo.numTicket, gameInfo.leftNumTicket);
        }
        return tileCostsInUsd;
    }

    function calculateTileCostInUsd(uint256 ticketCostInUsd, uint256 leftSpots, uint256 leftNumTreasure, uint256 numTicket, uint256 leftNumTicket) public view returns (uint256) {
        if (leftSpots == 0) {
            return 0;
        }
        if (numTicket == 0) {
            return (getLeftPotSizeInUsd() / leftSpots);
        }
        if (leftNumTreasure == 0) {
            return ((ticketCostInUsd * leftNumTicket) / leftSpots);
        } else {
            return ((ticketCostInUsd * leftNumTicket + getLeftPotSizeInUsd()) / leftSpots);
        }
    }

    // form VRFV2PlusWrapperConsumerBase.sol
    function requestRandomnessPayInNative(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        uint32 _numWords,
        bytes memory extraArgs
    ) internal returns (uint256 requestId, uint256 requestPrice) {
        requestPrice = i_vrfV2PlusWrapper.calculateRequestPriceNative(_callbackGasLimit, _numWords);
        return (
        i_vrfV2PlusWrapper.requestRandomWordsInNative{value: requestPrice}(
            _callbackGasLimit,
            _requestConfirmations,
            _numWords,
            extraArgs
        ),
        requestPrice
        );
    }

    function claimPrivateTreasury() external {
        require(_inTimeWindow(), 'Invalid Time Window');
        uint256[] memory _amounts = new uint256[](assetList.length);
        for(uint256 assetIndex = 0; assetIndex < assetList.length; assetIndex++) {
            address asset = assetList[assetIndex];
            uint256 amount = userTreasury[msg.sender][asset];
            userTreasury[msg.sender][asset] = 0;
            if (amount > 0) {
                IERC20(asset).transferFrom(treasury, msg.sender, amount);
            }
            _amounts[assetIndex] = amount;
        }
        emit ClaimPrivateTreasury(msg.sender, assetList, _amounts);
    }

    function _inTimeWindow() internal view returns (bool) {
        uint256 currentTime = block.timestamp;

        uint currentDayOfWeek = BokkyPooBahsDateTimeLibrary.getDayOfWeek(currentTime);
        uint currentHour = BokkyPooBahsDateTimeLibrary.getHour(currentTime);

        if (currentDayOfWeek == timeWindow.dayOfWeek) {
            if (currentHour >= timeWindow.startHour && currentHour < timeWindow.endHour) {
                return true;
            }
        }
        return false;
    }

    function claimTwitter(uint256 gameId, uint256[] memory tiles) external {
        uint256 length = tiles.length;
        for(uint256 i = 0; i < length; i++) {
            SpotInfo storage spotInfo = spotInfos[gameId][tiles[i]];
            require(spotInfo.withReferral && !spotInfo.twitterClaimed && spotInfo.isOpened, 'Invalid');
            uint256 amount = TreasureHuntLib.calculateRatio(spotInfo.tileCostInAmount, 1);
            IERC20(spotInfo.asset).transferFrom(treasury, msg.sender, amount); // gas optimization?
            spotInfo.twitterClaimed = true;
            emit ClaimTwitter(msg.sender, gameId, tiles[i], spotInfo.asset, amount);
        }
    }

    // Charges apply to all games except the latest game.
    function claimPendingAsset() external {
        require(lastGameId > 0, 'Minimum 1 Game Required');
        uint256[] memory _amounts = new uint256[](assetList.length);
        for(uint256 assetIndex = 0; assetIndex < assetList.length; assetIndex++) {
            address asset = assetList[assetIndex];
            uint256 amount = 0;
            for(uint256 gameIndex = 1; gameIndex < lastGameId; gameIndex++) {
                uint256 _amount =  pendingPots[gameIndex][msg.sender][asset];
                if (_amount > 0) {
                    amount = amount + _amount;
                    pendingPots[gameIndex][msg.sender][asset] = 0;
                }
            }
            _amounts[assetIndex] = amount;
            if (amount > 0) {
                IERC20(asset).transfer(msg.sender, amount);
            }
        }

        emit ClaimPendingAsset(msg.sender, assetList, _amounts);
    }

    function getGameInfo(uint256 _gameId) external view returns (GameInfo memory) {
        return gameInfos[_gameId];
    }

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (RequestStatus memory) {
        require(requests[_requestId].requestPaid > 0, "request not found");
        return requests[_requestId];
    }

    function _verifyUidSignature(
        address _owner,
        string memory _userUid,
        uint256 _nonce,
        bytes memory _signature
    ) internal pure {
        bytes32 messageHash = keccak256(abi.encode(_userUid, _nonce));
        address signer = MessageHashUtils.toEthSignedMessageHash(messageHash).recover(_signature);
        require(signer == _owner, 'Invalid Signature');
    }

    function _verifyReferralSignature(
        address _owner,
        string memory _userUid,
        address referralUser,
        uint256 _nonce,
        bytes memory _signature
    ) internal pure {
        bytes32 messageHash = keccak256(abi.encode(_userUid, referralUser, _nonce));
        address signer = MessageHashUtils.toEthSignedMessageHash(messageHash).recover(_signature);
        require(signer == _owner, 'Invalid Signature');
    }
}

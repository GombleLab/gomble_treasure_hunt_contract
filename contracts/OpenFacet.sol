// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusWrapperConsumerBase.sol";
import "./chainlink/VRFV2PlusClient.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./lib/TreasureHuntLib.sol";
import "./BaseFacet.sol";

contract OpenFacet is BaseFacet {
    using ECDSA for bytes32;

    event OpenSpot(
        address user,
        address payer,
        uint256 gameId,
        uint256[] tiles,
        uint256 openCostInAmount,
        address paidAsset,
        uint256 requestId
    );

    event Claim(address user, address[] assets, uint256[] amounts);
    event ClaimPendingAsset(address user, address[] assets, uint256[] amounts);
    event ClaimFlagFee(address user, address[] assets, uint256[] amounts);
    event ClaimPrivateTreasury(address user, address[] assets, uint256[] amounts);

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
        uint256 vrfBaseFeeInEth;
        uint256 vrfWordFeeInEth;
        uint256 vrfBaseFeeInAssetAmount;
        uint256 vrfWordFeeInAssetAmount;
    }

    function openSpotWithReferral(
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmountInAsset,
        address user,
        string memory userUid,
        address referralUser,
        uint256 nonce,
        bytes memory signature,
        uint256 vrfBaseFeeInAssetAmount
    ) external {
        require(referralUser != address(0), 'Invalid Referral User');
        address payer = msg.sender;
        require(user != referralUser, 'Not Allowed to Refer Yourself');
        require(!referralNonce[user][nonce], 'Already Used Nonce');
        _verifyReferralSignature(uidOwner, user, userUid, referralUser, nonce, signature);
        referralNonce[user][nonce] = true;
        _openSpot(user, userUid, payer, gameId, tiles, asset, maxAvgAmountInAsset, vrfBaseFeeInAssetAmount, referralUser);
    }

    function openSpotWithUID(
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmountInAsset,
        address user,
        string memory userUid,
        uint256 nonce,
        bytes memory signature,
        uint256 vrfBaseFeeInAssetAmount
    ) external {
        address payer = msg.sender;
        require(!uidNonce[userUid][nonce], 'Already Used Nonce');
        _verifyUidSignature(uidOwner, user, userUid, nonce, signature);
        uidNonce[userUid][nonce] = true;
        _openSpot(user, userUid, payer, gameId, tiles, asset, maxAvgAmountInAsset, vrfBaseFeeInAssetAmount, address(0));
    }

    function openSpot(
        uint256 gameId,
        uint256[] memory tiles,
        address user,
        address asset,
        uint256 maxAvgAmountInAsset,
        uint256 vrfBaseFeeInAssetAmount
    ) external {
        address payer = msg.sender;
        _openSpot(user, "", payer, gameId, tiles, asset, maxAvgAmountInAsset, vrfBaseFeeInAssetAmount, address(0));
    }

    function _openSpot(
        address user,
        string memory userUid,
        address payer,
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmountInAsset,
        uint256 vrfBaseFeeInAssetAmount,
        address referralUser
    ) internal {
        GameInfo memory gameInfo = gameInfos[gameId];
        GameMetaInfo memory gameMetaInfo = gameMetaInfos[gameId];
        require(tiles.length >= 1 && tiles.length <= gameInfo.maxTilesOpenableAtOnce, 'Invalid Tile Size');
        require(gameMetaInfo.isPlaying, 'Game Not in Progress');
        require(block.timestamp <= gameInfo.startTime + maxGameTime, 'Already Ended Game');
        require(gameMetaInfo.leftNumTicketTile != 0 || gameMetaInfo.leftNumTreasureTile != 0, 'No Ticket And Treasure');
        require(asset != ETH, 'ETH is not supported');
        require(assets[asset], 'Not Supported Asset');

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

        (localStruct.vrfBaseFeeInAssetAmount, localStruct.vrfWordFeeInAssetAmount) = calculateVrfFeeInAssetAmount(asset);
        localStruct.tileCostsInAmount = calculateTileCostsInAmount(asset, gameId, localStruct.unopenedTileCount);
        for (uint256 i = 0; i < localStruct.unopenedTileCount; i++) {
            uint256 tile = localStruct.unopenedTiles[i];
            require(tile < gameInfo.totalSpots, 'Invalid Tile');
            localStruct.accumulatedTileCostInAmount = localStruct.accumulatedTileCostInAmount + localStruct.tileCostsInAmount[i];
            if (localStruct.accumulatedTileCostInAmount + localStruct.vrfBaseFeeInAssetAmount <= maxAvgAmountInAsset * (i + 1) + vrfBaseFeeInAssetAmount) {
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
            if (localStruct.accumulatedTileCostInAmount + localStruct.vrfBaseFeeInAssetAmount <= maxAvgAmountInAsset * (i + 1) + vrfBaseFeeInAssetAmount) {
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

        IERC20(asset).transferFrom(payer, treasury, localStruct.vrfBaseFeeInAssetAmount + localStruct.vrfWordFeeInAssetAmount * localStruct.actualTileCount);

        pendingPots[gameId][user][asset] = pendingPots[gameId][user][asset] + localStruct.actualPaidInAmount;
        globalPendingPots[asset] = globalPendingPots[asset] + localStruct.actualPaidInAmount;
        IERC20(asset).transferFrom(payer, address(this), localStruct.actualPaidInAmount);
        uint256 requestId = _makeVrfNative(
            user,
            userUid,
            gameId,
            localStruct.actualTiles,
            localStruct.actualTileCostsInAmount,
            localStruct.actualPaidInAmount,
            asset
        );
        emit OpenSpot(user, payer, gameId, localStruct.actualTiles, localStruct.actualPaidInAmount, asset, requestId);
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
                globalUserClaimableAmounts[asset] = globalUserClaimableAmounts[asset] - amount;
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

    function getGameOverview() external view returns (
        uint256 gameId,
        SpotInfo[] memory tiles,
        address[] memory potAssets,
        uint256[] memory potAmounts,
        address[] memory winnerAssets,
        uint256[] memory winnerAmounts,
        GameInfo memory gameInfo,
        GameMetaInfo memory gameMetaInfo,
        uint256 _minGameTime,
        uint256 _maxGameTime,
        address winner
    ) {
        gameInfo = gameInfos[lastGameId];
        gameMetaInfo = gameMetaInfos[lastGameId];
        (tiles, potAssets, potAmounts) = getTiles(lastGameId);
        (winnerAssets, winnerAmounts) = getWinnerPrize(lastGameId);
        gameId = lastGameId;
        _minGameTime = minGameTime;
        _maxGameTime = maxGameTime;
        winner = getWinner(lastGameId);
    }

    function getWinner(uint256 gameId) public view returns (address) {
        GameMetaInfo memory gameMetaInfo = gameMetaInfos[gameId];
        return spotInfos[gameId][gameMetaInfo.treasureTile].user;
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
        GameMetaInfo memory gameMetaInfo = gameMetaInfos[gameId];
        require(gameMetaInfo.leftSpots >= tileCount, 'Invalid Tile Count');
        uint256[] memory tileCostsInUsd = new uint256[](tileCount);
        for (uint256 index = 0; index < tileCount; index++) {
            uint256 leftSpots = gameMetaInfo.leftSpots - index;
            tileCostsInUsd[index] = calculateTileCostInUsd(gameInfo.ticketCostInUsd, leftSpots, gameMetaInfo.leftNumTreasureTile, gameMetaInfo.leftNumTicket);
        }
        return tileCostsInUsd;
    }

    function calculateTileCostInUsd(uint256 ticketCostInUsd, uint256 leftSpots, uint256 leftNumTreasureTile, uint256 leftNumTicket) public view returns (uint256) {
        if (leftSpots == 0) {
            return 0;
        }
        if (leftNumTreasureTile == 0) {
            return ((ticketCostInUsd * leftNumTicket) / leftSpots);
        } else {
            return ((ticketCostInUsd * leftNumTicket + getLeftPotSizeInUsd()) / leftSpots);
        }
    }

    function calculateVrfFeeInAssetAmount(address asset) public view returns (uint256 baseFeeInAsset, uint256 wordFeeInAsset) {
        if (asset == ETH) {
            (baseFeeInAsset, wordFeeInAsset) = calculateVrfFeeInEthAmount();
        } else {
            (uint256 baseFeeInEth, uint256 wordFeeInEth) = calculateVrfFeeInEthAmount();
            baseFeeInAsset = convertAssetAmount(ETH, asset, baseFeeInEth);
            wordFeeInAsset = convertAssetAmount(ETH, asset, wordFeeInEth);
        }
    }

    function calculateVrfFeeInEthAmount() public view returns (uint256 baseFee, uint256 wordFee) {
        uint256 oneWordFee = i_vrfV2PlusWrapper.calculateRequestPriceNative(callbackGasLimit, uint32(1));
        uint256 twoWordFee = i_vrfV2PlusWrapper.calculateRequestPriceNative(callbackGasLimit, uint32(2));
        wordFee = twoWordFee - oneWordFee;
        baseFee = oneWordFee - wordFee;
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
        _claimPrivateTreasury(msg.sender);
    }

    function claimPrivateTreasury(address[] memory users) external {
        for(uint256 index = 0; index < users.length; index++) {
            _claimPrivateTreasury(users[index]);
        }
    }

    function _claimPrivateTreasury(address user) internal {
        uint256[] memory _amounts = new uint256[](assetList.length);
        for(uint256 assetIndex = 0; assetIndex < assetList.length; assetIndex++) {
            address asset = assetList[assetIndex];
            uint256 amount = userTreasury[user][asset];
            userTreasury[user][asset] = 0;
            globalUserTreasury[asset] = globalUserTreasury[asset] - amount;
            if (amount > 0) {
                IERC20(asset).transfer(user, amount);
            }
            _amounts[assetIndex] = amount;
        }
        emit ClaimPrivateTreasury(user, assetList, _amounts);
    }

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
                    globalPendingPots[asset] = globalPendingPots[asset] - _amount;
                }
            }
            _amounts[assetIndex] = amount;
            if (amount > 0) {
                IERC20(asset).transfer(msg.sender, amount);
            }
        }

        emit ClaimPendingAsset(msg.sender, assetList, _amounts);
    }

    function claimFlagFee(address[] memory assets, uint256[] memory amounts, uint256 nonce, bytes memory signature) external {
        require(assets.length == amounts.length, 'Invalid Length');
        require(!flagFeeNonce[nonce], 'Already Used Nonce');
        _verifyFlagFeeSignature(flagFeeOwner, assets, msg.sender, amounts, nonce, signature);
        flagFeeNonce[nonce] = true;

        for(uint256 index = 0; index < assets.length; index++) {
            address asset = assets[index];
            uint256 amount = amounts[index];
            require(flagPots[asset] >= amount, 'Insufficient Flag Fee');
            if (amount > 0) {
                flagPots[asset] = flagPots[asset] - amount;
                IERC20(asset).transfer(msg.sender, amount);
            }
        }
        emit ClaimFlagFee(msg.sender, assets, amounts);
    }
    function getGameInfo(uint256 _gameId) external view returns (GameInfo memory) {
        return gameInfos[_gameId];
    }

    function getGameMetaInfo(uint256 _gameId) external view returns (GameMetaInfo memory) {
        return gameMetaInfos[_gameId];
    }

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (RequestStatus memory) {
        require(requests[_requestId].requestPaid > 0, "request not found");
        return requests[_requestId];
    }

    function _verifyUidSignature(
        address _owner,
        address _user,
        string memory _userUid,
        uint256 _nonce,
        bytes memory _signature
    ) internal pure {
        bytes32 messageHash = keccak256(abi.encode(_user, _userUid, _nonce));
        address signer = MessageHashUtils.toEthSignedMessageHash(messageHash).recover(_signature);
        require(signer == _owner, 'Invalid Signature');
    }

    function _verifyReferralSignature(
        address _owner,
        address _user,
        string memory _userUid,
        address referralUser,
        uint256 _nonce,
        bytes memory _signature
    ) internal pure {
        bytes32 messageHash = keccak256(abi.encode(_user, _userUid, referralUser, _nonce));
        address signer = MessageHashUtils.toEthSignedMessageHash(messageHash).recover(_signature);
        require(signer == _owner, 'Invalid Signature');
    }

    function _verifyFlagFeeSignature(
        address _owner,
        address[] memory _assets,
        address _user,
        uint256[] memory _amounts,
        uint256 _nonce,
        bytes memory _signature
    ) internal pure {
        bytes32 messageHash = keccak256(abi.encode(_assets, _user, _amounts, _nonce));
        address signer = MessageHashUtils.toEthSignedMessageHash(messageHash).recover(_signature);
        require(signer == _owner, 'Invalid Signature');
    }
}

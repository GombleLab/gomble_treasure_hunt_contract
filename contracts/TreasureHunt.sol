// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusWrapperConsumerBase.sol";
import "./chainlink/VRFV2PlusClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract TreasureHunt is VRFV2PlusWrapperConsumerBase, Initializable {
    using ECDSA for bytes32;

    event Received(address, uint256);

    // vrf
    event RequestFulfilled(uint256 requestId, uint256[] randomWords, uint256 payment);

    struct RequestStatus {
        uint256 requestPaid;
        bool fulfilled;
        uint256[] tiles;
        uint256[] tileCostsInAmount;
        address paidAsset;
        uint256 tilePaidInAmount;
        uint256[] randomWords;
        uint256 gameId;
        address user;
        string userUid;
        uint256 blockNumber;
    }
    event SetVrfConfig(uint32 callbackGasLimit, uint16 requestConfirmations);

    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    mapping(uint256 => RequestStatus) public requests;

    // game
    event InitGame(
        uint256 gameId,
        uint256 totalSpots,
        uint256 numTreasure,
        uint256 numTicket,
        uint256 ticketCostInUsd,
        uint256 startTime,
        address[] assets,
        uint256[] amounts
    );

    event OpenSpot(
        address user,
        uint256 gameId,
        uint256[] tiles,
        uint256 openCostInAmount,
        address paidAsset,
        uint256 requestId
    );

    event SpotResult(uint256 gameId, address user, string userUid, uint256 tile, TileType tileType);
    event EndGame(uint256 gameId);
    event TerminateGame(uint256 gameId);
    event TreasureFound(uint256 gameId, uint256 tile, address winner, address[] assets, uint256[] amounts, string userUid);
    event SetGameConfig(uint256 minimumPotSizeInUsd, uint256 minGame, uint256 maxGame);
    event Claim(address user, address[] assets, uint256[] amounts);
    event ClaimPendingAsset(address user, address[] assets, uint256[] amounts);
    event TransferUidOwnership(address oldOwner, address newOwner);
    event TransferOwnership(address oldOwner, address newOwner);

    enum TileType {
        CLOSED,
        OCCUPIED,
        NONE,
        TICKET,
        TREASURE
    }

    struct GameInfo {
        uint256 id;
        uint256 totalSpots;
        uint256 maxTilesOpenableAtOnce;
        uint256 leftSpots;
        uint256 numTreasure;
        uint256 numTicket;
        uint256 leftNumTreasure;
        uint256 leftNumTicket;
        bool isPlaying;
        uint256 ticketCostInUsd; // decimal 8
        uint256 startTime;
        uint256 treasureTile;
        uint256 distributedAllBlockNumber; // 보물과 LDT가 모두 나눠진 블록
        uint256[] ticketTiles;
    }

    struct SpotInfo {
        uint256 tile;
        bool isOpened;
        TileType tileType;
        uint256 tileCostInAmount;
        address asset;
        address user;
        string userUid;
    }

    struct LocalOpenSpotStruct {
        uint256 unopenedTileCount;
        uint256 unopenedTileIndex;
        uint256[] tileCostsInAmount;
        uint256[] unopenedTiles;
        uint256[] actualTiles;
        uint256[] actualTileCostsInAmount;
    }

    uint256 public lastGameId;
    uint256 public minimumPotSizeInUsd; // decimal 8
    address public immutable USDT;
    address public immutable USDC;
    address private treasury;
    uint256 public minGameTime; // 보드판 최소 등장 주기
    uint256 public maxGameTime; // 진행시간
    mapping(address => bool) public assets;
    address[] public assetList;
    address public owner;
    address public uidOwner;
    mapping(string => mapping(uint256 => bool)) uidNonce; // user uid => nonce => bool

    mapping(uint256 => GameInfo) public gameInfos; // game => game info
    mapping(uint256 => mapping(uint256 => SpotInfo)) public spotInfos; // game => spot => spot info
    mapping(address => mapping(address => uint256)) public userClaimableAmounts; // user => token => amount
    mapping(uint256 => mapping(address => mapping(address => uint256))) public pendingPots; // 아직 처리되지 않은 pot, game => user => asset => amount
    mapping(address => uint256) public pots; // 처리된 pot, asset => amount

    modifier onlyOwner() {
        require(owner == msg.sender, "Invalid Owner");
        _;
    }

    function initialize(
        address _initialOwner,
        uint256 _minimumPotSizeInUsd,
        address _treasury,
        uint256 _minGameTime,
        uint256 _maxGameTime,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        address[] memory _initialAssets,
        address _uidOwner
    ) external initializer {
        owner = _initialOwner;
        minimumPotSizeInUsd = _minimumPotSizeInUsd;
        treasury = _treasury;
        minGameTime = _minGameTime;
        maxGameTime = _maxGameTime;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        for(uint256 index = 0; index < _initialAssets.length; index++) {
            assetList.push(_initialAssets[index]);
            assets[_initialAssets[index]] = true;
        }
        uidOwner = _uidOwner;
    }

    constructor(
        address _vrfV2Wrapper,
        address _usdt,
        address _usdc
    ) VRFV2PlusWrapperConsumerBase(_vrfV2Wrapper)
    {
        USDT = _usdt;
        USDC = _usdc;
    }

    function initGame(
        uint256 totalSpots,
        uint256 numTreasure,
        uint256 numTicket,
        uint256 ticketCostInUsd,
        uint256 maxTilesOpenableAtOnce,
        address initialPotAsset // pot size 부족 시 채워넣기 위해 사용할 asset
    ) external onlyOwner {
        require(assets[initialPotAsset], 'Not Supported Asset');
        require(totalSpots >= maxTilesOpenableAtOnce, 'Invalid Game Info');
        _checkAndResolveEnoughBalanceInTreasureHunt();
        uint256 previousGameLeftPotSizeInUsd;
        if (lastGameId == 0) { // first time
            previousGameLeftPotSizeInUsd = 0;
        } else {
            require(!gameInfos[lastGameId].isPlaying, 'Previous Game in Progress');
            previousGameLeftPotSizeInUsd = getLeftPotSizeInUsd();
        }
        lastGameId = lastGameId + 1;

        if (previousGameLeftPotSizeInUsd < minimumPotSizeInUsd) {
            uint256 requiredAmount = getAmountFromUsd(initialPotAsset, minimumPotSizeInUsd - previousGameLeftPotSizeInUsd);
            IERC20(initialPotAsset).transferFrom(msg.sender, address(this), requiredAmount);
            pots[initialPotAsset] = pots[initialPotAsset] + requiredAmount;
        }

        GameInfo storage gameInfo = gameInfos[lastGameId];
        gameInfo.id = lastGameId;
        gameInfo.totalSpots = totalSpots;
        gameInfo.maxTilesOpenableAtOnce = maxTilesOpenableAtOnce;
        gameInfo.leftSpots = totalSpots;
        gameInfo.numTreasure = numTreasure;
        gameInfo.numTicket = numTicket;
        gameInfo.leftNumTreasure = numTreasure;
        gameInfo.leftNumTicket = numTicket;
        gameInfo.isPlaying = true;
        gameInfo.ticketCostInUsd = ticketCostInUsd;
        gameInfo.startTime = block.timestamp;
        gameInfo.treasureTile = type(uint256).max;
        gameInfos[lastGameId] = gameInfo;

        (address[] memory _assets, uint256[] memory _amounts) = _getPotInfo();
        emit InitGame(lastGameId, totalSpots, numTreasure, numTicket, ticketCostInUsd, block.timestamp, _assets, _amounts);
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
        _verifySignature(uidOwner, userUid, nonce, signature);
        uidNonce[userUid][nonce] = true;
        _openSpot(user, userUid, gameId, tiles, asset, maxAvgAmount);
    }

    function openSpot(
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmount
    ) external {
        address user = msg.sender;
        _openSpot(user, "", gameId, tiles, asset, maxAvgAmount);
    }

    function _openSpot(
        address user,
        string memory userUid,
        uint256 gameId,
        uint256[] memory tiles,
        address asset,
        uint256 maxAvgAmount
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
        uint256 actualTileCount = 0;
        uint256 accumulatedTileCostInAmount = 0;
        for (uint256 i = 0; i < localStruct.unopenedTileCount; i++) {
            uint256 tile = localStruct.unopenedTiles[i];
            require(tile < gameInfo.totalSpots, 'Invalid Tile');
            accumulatedTileCostInAmount = accumulatedTileCostInAmount + localStruct.tileCostsInAmount[i];
            if (accumulatedTileCostInAmount <= maxAvgAmount * (i + 1)) {
                actualTileCount++;
            }
        }

        require(actualTileCount != 0, 'No Tiles Available for Purchase');

        uint256 actualPaidInAmount = 0;
        accumulatedTileCostInAmount = 0;
        localStruct.actualTiles = new uint256[](actualTileCount);
        localStruct.actualTileCostsInAmount = new uint256[](actualTileCount);
        uint256 index = 0;
        for (uint256 i = 0; i < localStruct.unopenedTileCount; i++) {
            accumulatedTileCostInAmount = accumulatedTileCostInAmount + localStruct.tileCostsInAmount[i];
            if (accumulatedTileCostInAmount <= maxAvgAmount * (i + 1)) {
                localStruct.actualTiles[index] = localStruct.unopenedTiles[i];
                localStruct.actualTileCostsInAmount[index] = localStruct.tileCostsInAmount[i];
                actualPaidInAmount = actualPaidInAmount + localStruct.tileCostsInAmount[i];
                spotInfos[gameId][localStruct.unopenedTiles[i]].tileType = TileType.OCCUPIED;
                index++;
            }
        }

        pendingPots[gameId][user][asset] = pendingPots[gameId][user][asset] + actualPaidInAmount;
        IERC20(asset).transferFrom(user, address(this), actualPaidInAmount);
        uint256 requestId = _makeVrfNative(
            user,
            userUid,
            gameId,
            localStruct.actualTiles,
            localStruct.actualTileCostsInAmount,
            actualPaidInAmount,
            asset
        );
        emit OpenSpot(user, gameId, localStruct.actualTiles, actualPaidInAmount, asset, requestId);
    }

    function terminateGame(uint256 gameId) external onlyOwner {
        GameInfo storage gameInfo = gameInfos[gameId];
        if (
            (!gameInfo.isPlaying && block.timestamp > gameInfo.startTime + minGameTime) // 게임이 이미 끝났어도 최소 등장 주기 이후 종료 가능
            || (gameInfo.isPlaying && block.timestamp > gameInfo.startTime + maxGameTime)) // 게임이 끝나지 않았지만 진행 시간이 초과했을 경우 종료 가능
        {
            gameInfo.isPlaying = false;
            gameInfos[gameId] = gameInfo;
            emit TerminateGame(gameId);
            return;
        }

        revert("Game Cannot Be Terminated Yet");
    }

    function _processResult(uint256 requestId) internal {
        RequestStatus memory requestStatus = requests[requestId];
        require(requestStatus.fulfilled, 'Request Not Fulfilled');
        uint256 gameId = requestStatus.gameId;
        GameInfo storage gameInfo = gameInfos[gameId];

        for (uint256 index = 0; index < requestStatus.randomWords.length; index++) {
            uint256 randomNumber = requestStatus.randomWords[index];
            uint256 tile = requestStatus.tiles[index];
            uint256 tileCostInAmount = requestStatus.tileCostsInAmount[index];
            // 보물과 티켓이 모두 찾아지기 전에 보낸 요청이면 treasury로 전송
            if (
                gameInfo.leftNumTreasure == 0
                && gameInfo.leftNumTicket == 0
                && requestStatus.blockNumber < gameInfo.distributedAllBlockNumber
            ) {
                if (!spotInfos[gameId][tile].isOpened) {
                    _setSpotResult(gameId, tile, TileType.NONE, tileCostInAmount, requestStatus.paidAsset, requestStatus.user, requestStatus.userUid);
                }

                pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] = pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] - tileCostInAmount;
                IERC20(requestStatus.paidAsset).transfer(treasury, tileCostInAmount);
                continue;
            }

            pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] = pendingPots[gameId][requestStatus.user][requestStatus.paidAsset] - tileCostInAmount;
            pots[requestStatus.paidAsset] = pots[requestStatus.paidAsset] + tileCostInAmount;
            TileType result = _checkResult(randomNumber, gameInfo.leftSpots, gameInfo.leftNumTreasure, gameInfo.leftNumTicket);
            gameInfo.leftSpots = gameInfo.leftSpots - 1;
            _setSpotResult(gameId, tile, result, tileCostInAmount, requestStatus.paidAsset, requestStatus.user, requestStatus.userUid);

            if (result == TileType.TICKET && gameInfo.leftNumTicket != 0) {
                gameInfo.leftNumTicket = gameInfo.leftNumTicket - 1;
                gameInfo.ticketTiles.push(tile);
            }

            if (result == TileType.TREASURE && gameInfo.leftNumTreasure != 0) {
                gameInfo.treasureTile = tile;
                gameInfo.leftNumTreasure = gameInfo.leftNumTreasure - 1;
                _processTreasure(gameInfo);
            }
            emit SpotResult(gameId, requestStatus.user, requestStatus.userUid, tile, result);
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

    function getTiles(uint256 gameId) external view returns (SpotInfo[] memory, address[] memory, uint256[] memory) {
        GameInfo memory gameInfo = gameInfos[gameId];
        SpotInfo[] memory tiles = new SpotInfo[](gameInfo.totalSpots);
        for (uint256 index = 0; index < gameInfo.totalSpots; index++) {
            tiles[index] = spotInfos[gameId][index];
        }

        (address[] memory _assets, uint256[] memory _amounts) = _getPotInfo();

        return (tiles, _assets, _amounts);
    }

    function _getPotInfo() internal view returns (address[] memory, uint256[] memory) {
        uint256[] memory _amounts = new uint256[](assetList.length);
        for (uint256 index = 0; index < assetList.length; index++) {
            address asset = assetList[index];
            _amounts[index] = pots[asset];
        }

        return (assetList, _amounts);
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

    function _endGame(GameInfo storage gameInfo) internal {
        gameInfo.isPlaying = false;
        gameInfo.distributedAllBlockNumber = block.number;
        emit EndGame(gameInfo.id);
    }

    function _processTreasure(GameInfo storage gameInfo) internal {
        address winner = spotInfos[gameInfo.id][gameInfo.treasureTile].user;
        string memory userUid = spotInfos[gameInfo.id][gameInfo.treasureTile].userUid;
        if (winner != address(0)) {
            uint256 prizeRatio;
            uint256 remainRatio;
            if (gameInfo.numTicket == 0) {
                prizeRatio = 70;
                remainRatio = 30;
            } else {
                prizeRatio = 90;
                remainRatio = 10;
            }
            uint256[] memory _prizes = new uint256[](assetList.length);
            for (uint256 index = 0; index < assetList.length; index++) {
                address asset = assetList[index];
                uint256 prize = pots[asset] * prizeRatio / 100;
                uint256 remain = pots[asset] * remainRatio / 100;
                _prizes[index] = prize;
                userClaimableAmounts[winner][asset] = userClaimableAmounts[winner][asset] + prize;
                IERC20(asset).transfer(treasury, remain);
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

    function getLeftPotSizeInUsd() public view returns (uint256 potSize) {
        for(uint256 index = 0; index < assetList.length; index++) {
            potSize = potSize + _getAssetInUsd(assetList[index], pots[assetList[index]]);
        }
    }

    function _checkAndResolveEnoughBalanceInTreasureHunt() internal {
        for(uint256 index = 0; index < assetList.length; index++) {
            uint256 potAmount = pots[assetList[index]];
            uint256 treasureHuntBalance = IERC20(assetList[index]).balanceOf(address(this));
            if (potAmount > treasureHuntBalance) {
                IERC20(assetList[index]).transferFrom(msg.sender, address(this), potAmount - treasureHuntBalance);
            }
        }
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
        uint256 tilePaidInAmount,
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
            tilePaidInAmount : tilePaidInAmount,
            fulfilled : false,
            gameId : _gameId,
            user : _user,
            userUid: _userUid,
            paidAsset: _paidAsset,
            blockNumber: block.number
        });
        return requestId;
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

    function getAmountFromUsd(address asset, uint256 amountInUsd) public view returns (uint256) {
        return (amountInUsd * (10 ** IERC20(asset).decimals()) / _getAssetPriceInUsd(asset));
    }

    function _getAssetInUsd(address asset, uint256 amount) internal view returns (uint256) {
        uint256 decimals = IERC20(asset).decimals();
        uint256 priceInUsd = _getAssetPriceInUsd(asset);
        return amount * priceInUsd / (10 ** decimals);
    }

    function _getAssetPriceInUsd(address asset) internal view returns (uint256) {
        if (asset == USDT || asset == USDC) {
            return 10 ** 8;
        }
        return 0;
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

    // 최신 게임을 제외한 나머지 게임에 대해서 청구
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

    // TODO: upgrade
    // - check pending pot
    // - oracle
    // function addAsset(address asset) external onlyOwner {}

    function getGameInfo(uint256 _gameId) external view returns (GameInfo memory) {
        return gameInfos[_gameId];
    }

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (RequestStatus memory) {
        require(requests[_requestId].requestPaid > 0, "request not found");
        return requests[_requestId];
    }

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        if (amount == 0) {
            to.call{value: address(this).balance}("");
        } else {
            to.call{value: amount}("");
        }
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        if (amount == 0) {
            IERC20(token).transfer(
                to,
                IERC20(token).balanceOf(address(this))
            );
        } else {
            IERC20(token).transfer(to, amount);
        }
    }

    function transferUidOwnership(address newOwner) external onlyOwner {
        address oldOwner = uidOwner;
        uidOwner = newOwner;
        emit TransferUidOwnership(oldOwner, newOwner);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        address oldOwner = owner;
        owner = newOwner;
        emit TransferOwnership(oldOwner, newOwner);
    }

    // configuration
    function setVrfConfig(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyOwner {
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        emit SetVrfConfig(_callbackGasLimit, _requestConfirmations);
    }

    function setGameConfig(
        uint256 _minimumPotSizeInUsd,
        uint256 _minGameTime,
        uint256 _maxGameTime
    ) external onlyOwner {
        minimumPotSizeInUsd = _minimumPotSizeInUsd;
        minGameTime = _minGameTime;
        maxGameTime = _maxGameTime;
        emit SetGameConfig(_minimumPotSizeInUsd, _minGameTime, _maxGameTime);
    }

    function _verifySignature(
        address _owner,
        string memory _userUid,
        uint256 _nonce,
        bytes memory _signature
    ) internal pure {
        bytes32 messageHash = keccak256(abi.encode(_userUid, _nonce));
        address signer = MessageHashUtils.toEthSignedMessageHash(messageHash).recover(_signature);
        require(signer == _owner, 'Invalid Signature');
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusWrapperConsumerBase.sol";
import "./chainlink/VRFV2PlusClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./BaseFacet.sol";

contract ConfigurationFacet is BaseFacet {
    event SetVrfConfig(uint32 callbackGasLimit, uint16 requestConfirmations);
    event TerminateGame(uint256 gameId);
    event SetGameConfig(uint256 minimumPotSizeInUsd, uint256 minGame, uint256 maxGame);
    event SetFeeConfig(uint256 treasuryFeeRatio, uint256 referralFeeRatio, uint256 refereeFeeRatio);
    event SetMaxGasPrice(uint256 maxGasPrice);
    event SetTimeWindow(uint256 dayOfWeek, uint256 startHour, uint256 endHour);
    event TransferUidOwnership(address oldOwner, address newOwner);
    event TransferOwnership(address oldOwner, address newOwner);

    event InitGame(
        uint256 gameId,
        uint256 totalSpots,
        uint256 numTreasureTile,
        uint256 numTicketTile,
        uint256 numTicket,
        uint256 minTicketNum,
        uint256 maxTicketNum,
        uint256 ticketCostInUsd,
        uint256 startTime,
        address[] assets,
        uint256[] amounts
    );

    modifier onlyOwner() {
        require(owner == msg.sender, "Invalid Owner");
        _;
    }

    modifier onlyUidOwner() {
        require(uidOwner == msg.sender, "Invalid UidOwner");
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
        address _uidOwner,
        address _vrfV2Wrapper,
        address _usdt,
        address _usdc
    ) external onlyOwner {
        owner = _initialOwner;
        minimumPotSizeInUsd = _minimumPotSizeInUsd;
        treasury = _treasury;
        minGameTime = _minGameTime;
        maxGameTime = _maxGameTime;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        for (uint256 index = 0; index < _initialAssets.length; index++) {
            assetList.push(_initialAssets[index]);
            assets[_initialAssets[index]] = true;
        }
        uidOwner = _uidOwner;
        IVRFV2PlusWrapper vrfV2PlusWrapper = IVRFV2PlusWrapper(_vrfV2Wrapper);
        i_linkToken = LinkTokenInterface(vrfV2PlusWrapper.link());
        i_vrfV2PlusWrapper = vrfV2PlusWrapper;
        USDT = _usdt;
        USDC = _usdc;
        treasuryFeeRatio = 9;
        referralFeeRatio = 3;
        refereeFeeRatio = 3;
        maxGasPrice = 100000000;
    }

    function initGame(
        uint256 totalSpots,
        uint256 numTreasureTile,
        uint256 numTicketTile,
        uint256 numTicket,
        uint256 minTicketNum,
        uint256 maxTicketNum,
        uint256 ticketCostInUsd,
        uint256 maxTilesOpenableAtOnce,
        address initialPotAsset
    ) external onlyUidOwner {
        require(tx.gasprice <= maxGasPrice, 'Max Gas Price Exceeded');
        require(assets[initialPotAsset], 'Not Supported Asset');
        require(
            totalSpots >= maxTilesOpenableAtOnce
            && numTicketTile > 0
            && totalSpots >= numTreasureTile + numTicketTile
            && minTicketNum > 0
            && minTicketNum <= maxTicketNum
            && numTicket >= numTicketTile
            && maxTicketNum <= numTicket
            , 'Invalid Game Info');
        _checkAndResolveEnoughBalanceInTreasureHunt();
        if (lastGameId != 0) {
            require(!gameMetaInfos[lastGameId].isPlaying, 'Previous Game in Progress');
        }
        lastGameId = lastGameId + 1;
        _checkAndResolveMinimumPotSize(initialPotAsset);

        GameInfo storage gameInfo = gameInfos[lastGameId];
        gameInfo.id = lastGameId;
        gameInfo.totalSpots = totalSpots;
        gameInfo.maxTilesOpenableAtOnce = maxTilesOpenableAtOnce;
        gameInfo.numTreasureTile = numTreasureTile;
        gameInfo.numTicketTile = numTicketTile;
        gameInfo.numTicket = numTicket;
        gameInfo.minTicketNum = minTicketNum;
        gameInfo.maxTicketNum = maxTicketNum;
        gameInfo.ticketCostInUsd = ticketCostInUsd;
        gameInfo.startTime = block.timestamp;
        gameInfos[lastGameId] = gameInfo;

        GameMetaInfo storage gameMetaInfo = gameMetaInfos[lastGameId];
        gameMetaInfo.id = lastGameId;
        gameMetaInfo.leftSpots = totalSpots;
        gameMetaInfo.leftNumTreasureTile = numTreasureTile;
        gameMetaInfo.leftNumTicketTile = numTicketTile;
        gameMetaInfo.leftNumTicket = numTicket;
        gameMetaInfo.isPlaying = true;
        gameMetaInfo.treasureTile = type(uint256).max;
        gameMetaInfos[lastGameId] = gameMetaInfo;

        (address[] memory _assets, uint256[] memory _amounts) = _getPotInfo();
        emit InitGame(lastGameId, totalSpots, numTreasureTile, numTicketTile, numTicket, minTicketNum, maxTicketNum, ticketCostInUsd, block.timestamp, _assets, _amounts);
    }

    function terminateGame(uint256 gameId) external onlyUidOwner {
        GameMetaInfo storage gameMetaInfo = gameMetaInfos[gameId];
        GameInfo memory gameInfo = gameInfos[gameId];
        if (
            (!gameMetaInfo.isPlaying && block.timestamp > gameInfo.startTime + minGameTime) // The game can be terminated after the minimum appearance cycle, even if it has already ended.
            || (gameMetaInfo.isPlaying && block.timestamp > gameInfo.startTime + maxGameTime)) // The game can be terminated if the progress time is exceeded, even if it has not ended.
        {
            gameMetaInfo.isPlaying = false;
            gameMetaInfos[gameId] = gameMetaInfo;
            emit TerminateGame(gameId);
            return;
        }

        revert("Game Cannot Be Terminated Yet");
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

    function setFeeConfig(
        uint256 _treasuryFeeRatio,
        uint256 _referralFeeRatio,
        uint256 _refereeFeeRatio
    ) external onlyOwner {
        require(_treasuryFeeRatio + _referralFeeRatio + _refereeFeeRatio <= 100, "Invalid Fee Ratio");
        treasuryFeeRatio = _treasuryFeeRatio;
        referralFeeRatio = _referralFeeRatio;
        refereeFeeRatio = _refereeFeeRatio;
        emit SetFeeConfig(_treasuryFeeRatio, _referralFeeRatio, _refereeFeeRatio);
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external onlyOwner {
        maxGasPrice = _maxGasPrice;
        emit SetMaxGasPrice(_maxGasPrice);
    }

    function _checkAndResolveEnoughBalanceInTreasureHunt() internal {
        for (uint256 index = 0; index < assetList.length; index++) {
            uint256 potAmount = pots[assetList[index]];
            uint256 treasureHuntBalance = IERC20(assetList[index]).balanceOf(address(this));
            if (potAmount > treasureHuntBalance) {
                IERC20(assetList[index]).transferFrom(msg.sender, address(this), potAmount - treasureHuntBalance);
            }
        }
    }

    function _checkAndResolveMinimumPotSize(address asset) internal {
        uint256 leftPotSizeInUsd = getLeftPotSizeInUsd();
        if (leftPotSizeInUsd < minimumPotSizeInUsd) {
            uint256 requiredAmount = getAmountFromUsd(asset, minimumPotSizeInUsd - leftPotSizeInUsd);
            IERC20(asset).transferFrom(msg.sender, address(this), requiredAmount);
            pots[asset] = pots[asset] + requiredAmount;
        }
    }
}

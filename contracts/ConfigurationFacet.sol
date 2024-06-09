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
    event SetTimeWindow(uint256 dayOfWeek, uint256 startHour, uint256 endHour);
    event TransferUidOwnership(address oldOwner, address newOwner);
    event TransferOwnership(address oldOwner, address newOwner);

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
        for(uint256 index = 0; index < _initialAssets.length; index++) {
            assetList.push(_initialAssets[index]);
            assets[_initialAssets[index]] = true;
        }
        uidOwner = _uidOwner;
        IVRFV2PlusWrapper vrfV2PlusWrapper = IVRFV2PlusWrapper(_vrfV2Wrapper);
        i_linkToken = LinkTokenInterface(vrfV2PlusWrapper.link());
        i_vrfV2PlusWrapper = vrfV2PlusWrapper;
        USDT = _usdt;
        USDC = _usdc;
        timeWindow = TimeWindow(7, 0, 24);
    }

    function initGame(
        uint256 totalSpots,
        uint256 numTreasure,
        uint256 numTicket,
        uint256 ticketCostInUsd,
        uint256 maxTilesOpenableAtOnce,
        address initialPotAsset
    ) external onlyOwner {
        require(assets[initialPotAsset], 'Not Supported Asset');
        require(totalSpots >= maxTilesOpenableAtOnce, 'Invalid Game Info');
        _checkAndResolveEnoughBalanceInTreasureHunt();
        if (lastGameId != 0) {
            require(!gameInfos[lastGameId].isPlaying, 'Previous Game in Progress');
        }
        lastGameId = lastGameId + 1;
        uint256 requiredAmount = getAmountFromUsd(initialPotAsset, minimumPotSizeInUsd);
        IERC20(initialPotAsset).transferFrom(msg.sender, address(this), requiredAmount);
        pots[initialPotAsset] = pots[initialPotAsset] + requiredAmount;

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

    function terminateGame(uint256 gameId) external onlyOwner {
        GameInfo storage gameInfo = gameInfos[gameId];
        if (
            (!gameInfo.isPlaying && block.timestamp > gameInfo.startTime + minGameTime) // The game can be terminated after the minimum appearance cycle, even if it has already ended.
            || (gameInfo.isPlaying && block.timestamp > gameInfo.startTime + maxGameTime)) // The game can be terminated if the progress time is exceeded, even if it has not ended.
        {
            gameInfo.isPlaying = false;
            gameInfos[gameId] = gameInfo;
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

    function setTimeWindow(uint8 dayOfWeek, uint8 startHour, uint8 endHour) external onlyOwner {
        require(dayOfWeek >= 1 && dayOfWeek <= 7, "Invalid Day of Week");
        require(startHour < 24, "Invalid Start Hour");
        require(endHour <= 24, "Invalid End Hour");
        require(startHour < endHour, "StartHour >= EndHour");
        timeWindow = TimeWindow(dayOfWeek, startHour, endHour);
        emit SetTimeWindow(dayOfWeek, startHour, endHour);
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
}

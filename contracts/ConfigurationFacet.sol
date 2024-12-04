// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusClient.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./BaseFacet.sol";

contract ConfigurationFacet is BaseFacet {
    event SetVrfConfig(uint32 callbackGasLimit, uint16 requestConfirmations);
    event TerminateGame(uint256 gameId);
    event SetGameConfig(uint256 minimumPotSizeInUsd, uint256 minGame, uint256 maxGame);
    event SetFeeConfig(uint256 treasuryFeeRatio, uint256 referralFeeRatio, uint256 refereeFeeRatio, uint256 predefinedReferralFeeRatio, uint256 predefinedRefereeFeeRatio);
    event SetMaxGasPrice(uint256 maxGasPrice);
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
        address[] memory _initialAssets,
        address _uidOwner,
        address _vrfV2Wrapper,
        address _usdt,
        address _usdc,
        address _ethOracle
    ) external initializer {
        owner = _initialOwner;
        minimumPotSizeInUsd = _minimumPotSizeInUsd;
        treasury = _treasury;
        minGameTime = _minGameTime;
        maxGameTime = _maxGameTime;
        for (uint256 index = 0; index < _initialAssets.length; index++) {
            assetList.push(_initialAssets[index]);
            assets[_initialAssets[index]] = true;
        }
        assets[ETH] = true;
        uidOwner = _uidOwner;
        IVRFV2PlusWrapper vrfV2PlusWrapper = IVRFV2PlusWrapper(_vrfV2Wrapper);
        i_linkToken = LinkTokenInterface(vrfV2PlusWrapper.link());
        i_vrfV2PlusWrapper = vrfV2PlusWrapper;
        USDT = _usdt;
        USDC = _usdc;
        ethOracle = AggregatorV3Interface(_ethOracle);
        callbackGasLimit = 1500000;
        requestConfirmations = 1;
        treasuryFeeRatio = 15;
        referralFeeRatio = 1;
        refereeFeeRatio = 1;
        predefinedReferralFeeRatio = 2;
        predefinedRefereeFeeRatio = 2;
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

    function setPredefinedReferralUser(address[] memory users, bool isPredefined) external onlyOwner {
        for (uint256 index = 0; index < users.length; index++) {
            require(users[index] != address(0), 'Invalid User');
            predefinedReferralUsers[users[index]] = isPredefined;
        }
    }

    function setFeeConfig(
        uint256 _treasuryFeeRatio,
        uint256 _referralFeeRatio,
        uint256 _refereeFeeRatio,
        uint256 _predefinedReferralFeeRatio,
        uint256 _predefinedRefereeFeeRatio
    ) external onlyOwner {
        require(_treasuryFeeRatio + _referralFeeRatio + _refereeFeeRatio <= 100, "Invalid Fee Ratio");
        require(_treasuryFeeRatio + _predefinedReferralFeeRatio + _predefinedRefereeFeeRatio <= 100, "Invalid Predefined Fee Ratio");
        treasuryFeeRatio = _treasuryFeeRatio;
        referralFeeRatio = _referralFeeRatio;
        refereeFeeRatio = _refereeFeeRatio;
        predefinedReferralFeeRatio = _predefinedReferralFeeRatio;
        predefinedRefereeFeeRatio = _predefinedRefereeFeeRatio;
        emit SetFeeConfig(_treasuryFeeRatio, _referralFeeRatio, _refereeFeeRatio, _predefinedReferralFeeRatio, _predefinedRefereeFeeRatio);
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external onlyOwner {
        maxGasPrice = _maxGasPrice;
        emit SetMaxGasPrice(_maxGasPrice);
    }

    function _checkAndResolveEnoughBalanceInTreasureHunt() internal {
        for (uint256 index = 0; index < assetList.length; index++) {
            uint256 amountToMaintain = _getAmountToMaintain(assetList[index]);
            uint256 treasureHuntBalance = IERC20(assetList[index]).balanceOf(address(this));
            if (amountToMaintain > treasureHuntBalance) {
                IERC20(assetList[index]).transferFrom(msg.sender, address(this), amountToMaintain - treasureHuntBalance);
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

    function _getAmountToMaintain(address asset) internal view returns (uint256) {
        return pots[asset] + globalPendingPots[asset] + globalUserTreasury[asset] + globalUserClaimableAmounts[asset];
    }
}

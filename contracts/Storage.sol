// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./chainlink/LinkTokenInterface.sol";
import "./chainlink/IVRFV2PlusWrapper.sol";

contract Storage {
    // facet
    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition; // position in _facetFunctionSelectors.functionSelectors array
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition; // position of facetAddress in _facetAddresses array
    }

    mapping(bytes4 => FacetAddressAndPosition) internal _selectorToFacetAndPosition;
    // maps facet addresses to function selectors
    mapping(address => FacetFunctionSelectors) internal _facetFunctionSelectors;
    // facet addresses
    address[] internal _facetAddresses;

    // vrf
    LinkTokenInterface internal i_linkToken;
    IVRFV2PlusWrapper public i_vrfV2PlusWrapper;

    struct RequestStatus {
        uint256 requestPaid;
        bool fulfilled;
        uint256[] tiles;
        uint256[] tileCostsInAmount;
        uint256 paidInAmount;
        address paidAsset;
        uint256[] randomWords;
        uint256 gameId;
        address user;
        string userUid;
        uint256 blockNumber;
    }

    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    mapping(uint256 => RequestStatus) public requests;

    // games

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
        uint256 distributedAllBlockNumber; // A block where both treasures and LDT are distributed.
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
        address referralUser;
        bool withReferral;
        bool twitterClaimed;
    }

    struct TimeWindow {
        uint256 dayOfWeek; // 1: Monday, 7: Sunday
        uint256 startHour; // 0 ~ 23
        uint256 endHour; // 0 ~ 23
    }

    uint256 public lastGameId;
    uint256 public minimumPotSizeInUsd; // decimal 8
    address public USDT;
    address public USDC;
    address public treasury;
    uint256 public minGameTime; // Minimum appearance cycle of the board.
    uint256 public maxGameTime; // Progress time
    mapping(address => bool) public assets;
    address[] public assetList;
    address public owner;
    address public uidOwner;
    mapping(string => mapping(uint256 => bool)) uidNonce; // user uid => nonce => bool
    mapping(address => mapping(uint256 => bool)) referralNonce; // user(sender, not referral user) => nonce => bool
    mapping(address => mapping(address => uint256)) public userTreasury; // user => asset => amount
    mapping(uint256 => mapping(address => uint256)) public winnerPrizes; // game => asset => amount

    mapping(uint256 => GameInfo) public gameInfos; // game => game info
    mapping(uint256 => mapping(uint256 => SpotInfo)) public spotInfos; // game => spot => spot info
    mapping(address => mapping(address => uint256)) public userClaimableAmounts; // user => token => amount
    mapping(uint256 => mapping(address => mapping(address => uint256))) public pendingPots; // Unprocessed pot, game => user => asset => amount
    mapping(address => uint256) public pots; // Processed pot, asset => amount
    TimeWindow public timeWindow;
}

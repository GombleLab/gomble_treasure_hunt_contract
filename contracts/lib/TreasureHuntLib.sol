// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library TreasureHuntLib {
    uint256 internal constant FEE_RATIO_DENOMINATOR = 10000;
    
    function calculateRatio(uint256 value, uint256 ratio) internal pure returns (uint256) {
        return value * ratio / FEE_RATIO_DENOMINATOR;
    }
}

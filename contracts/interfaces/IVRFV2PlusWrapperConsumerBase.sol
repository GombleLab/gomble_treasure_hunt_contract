// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVRFV2PlusWrapperConsumerBase {
    function rawFulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) external;
}

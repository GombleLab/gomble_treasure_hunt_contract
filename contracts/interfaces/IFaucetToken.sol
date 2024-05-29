pragma solidity ^0.8.0;

interface IFaucetToken {
    function allocateTo(address _owner, uint256 value) external;
}

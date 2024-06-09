pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "./Diamond.sol";
import "./OpenFacet.sol";
import "./ProcessFacet.sol";
import "./ConfigurationFacet.sol";

contract DiamondConsolidated is Diamond, OpenFacet, ProcessFacet, ConfigurationFacet {

    constructor(address owner) Diamond(owner)  {}
}

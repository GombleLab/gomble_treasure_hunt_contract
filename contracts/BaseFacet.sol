// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./chainlink/VRFV2PlusWrapperConsumerBase.sol";
import "./chainlink/VRFV2PlusClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract BaseFacet is Storage {
    function getLeftPotSizeInUsd() public view returns (uint256 potSize) {
        for(uint256 index = 0; index < assetList.length; index++) {
            potSize = potSize + _getAssetInUsd(assetList[index], pots[assetList[index]]);
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

    function _getPotInfo() internal view returns (address[] memory, uint256[] memory) {
        uint256[] memory _amounts = new uint256[](assetList.length);
        for (uint256 index = 0; index < assetList.length; index++) {
            address asset = assetList[index];
            _amounts[index] = pots[asset];
        }

        return (assetList, _amounts);
    }
}

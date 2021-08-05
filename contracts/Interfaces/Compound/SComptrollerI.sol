pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "./SCErc20I.sol";
import "./PriceOracle.sol";

interface SComptrollerI {
    function oracle() external view returns (PriceOracle);
    function getAccountLiquidity(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    /***  Comp claims ****/
    function claimComp(address holder) external;

    function claimComp(address holder, SCErc20I[] memory cTokens) external;

    function markets(address ctoken)
        external
        view
        returns (
            bool,
            uint256,
            bool
        );

    function compSpeeds(address ctoken) external view returns (uint256);

}
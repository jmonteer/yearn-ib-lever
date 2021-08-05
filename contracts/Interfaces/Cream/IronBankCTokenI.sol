pragma solidity >=0.5.0;

import "../Compound/CErc20I.sol";

interface IronBankCTokenI is CErc20I {
    function estimateBorrowRatePerBlockAfterChange(uint256 change, bool repay) external view returns (uint);
    function estimateSupplyRatePerBlockAfterChange(uint256 change, bool repay) external view returns (uint);
}
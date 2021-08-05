pragma solidity >=0.5.0;
import "./InterestRateModel.sol";

interface SCErc20I {
    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);

    function repayBorrow(uint256 repayAmount) external returns (uint256);
    
    function underlying() external view returns (address);
    function reserveFactorMantissa() external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function getAccountSnapshot(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function borrowBalanceCurrent(address account) external returns (uint256);

    function borrowBalanceStored(address account) external view returns (uint256);

    function totalBorrows() external view returns (uint256);

    function totalSupply() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function interestRateModel() external view returns (InterestRateModel);
    function borrowRatePerBlock() external view returns (uint256);

    function supplyRatePerBlock() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);

}
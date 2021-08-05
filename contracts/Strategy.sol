// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./Interfaces/Cream/IronBankCTokenI.sol";
import "./Interfaces/Compound/SComptrollerI.sol";

// These are the core Yearn libraries
import {
    BaseStrategy, StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";


// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    //IRON BANK
    address private ironBank;
    address private ironBankToken;

    //Operating variables
    uint256 public targetAPR = 0.07 ether; 
    uint256 public maxBorrow = 10_000_000 * 1e18; 

    uint256 public buffer = 1_000 * 1e18; // how much profit buffer do we keep

    uint256 public step = 10; //how many iterations we do
    

    bool public checkLiqGauge = true;

    uint256 public maxSingleTrade;
    uint256 public constant DENOMINATOR = 10_000;
    uint256 public constant BLOCKSPERYEAR = 2102400; //number that cream uses
    uint256 public slippageProtectionOut;// = 50; //out of 10000. 50 = 0.5%


    constructor(address _vault, address _ironBank, address _ironBankToken) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 43200;
        profitFactor = 2000;
        debtThreshold = 400_000*1e18;

        ironBank = _ironBank;
        ironBankToken = _ironBankToken;
        want.safeApprove(address(vault), uint256(-1));
        want.safeApprove(address(_ironBankToken), uint256(-1));
    }


    function ironBankOutstandingDebtStored() public view returns (uint256 available) {
        return SCErc20I(ironBankToken).borrowBalanceStored(address(this));
     }

     function ironBankOutstandingDebtCurrent() public returns (uint256 available) {
        return SCErc20I(ironBankToken).borrowBalanceCurrent(address(this));
     }


    function ironBankBorrowRate(uint256 amount, bool repay) public view returns (uint256) {
        return IronBankCTokenI(ironBankToken).estimateBorrowRatePerBlockAfterChange(amount, repay);
    }

    function name() external override view returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "IronbankLever";
    }

    function estimatedTotalAssets() public override view returns (uint256) {
        (uint256 profit,) = pnl();
        
        return profit;
    }

    function pnl() public view returns (uint256 profit, uint256 loss){
        uint256 assets = wantBalance().add(vaultBalanceWant());
        uint256 liabilities = ironBankOutstandingDebtStored();

        if(assets > liabilities){
            profit =  assets - liabilities;
        }else{
            loss = liabilities - assets;
        }
    }

    function wantBalance() public view returns (uint256){
        return want.balanceOf(address(this));
    }

    function vaultBalanceTokens() public view returns (uint256){
        return vault.balanceOf(address(this));
    }

    function vaultBalanceWant() public view returns (uint256){
        return vaultBalanceTokens().mul(vault.pricePerShare()).div(1e18);
    }

    function _withdrawFromVault(uint256 toWithdraw) internal returns(uint256){
        uint256 tokensNeeded = toWithdraw.mul(1e18).div(vault.pricePerShare()); // round down so leaves dust

        uint256 vaultTokens = vaultBalanceTokens();
        vault.withdraw(Math.min(vaultTokens, tokensNeeded));

        return wantBalance();

    }

    /*****************
     * Iron Bank
     ******************/

    //simple logic. do we get more apr than iron bank charges?
    //if so, is that still true with increased pos?
    //if not, should be reduce?
    //made harder because we can't assume iron bank debt curve. So need to increment
    function internalCreditOfficer() public view returns (bool borrowMore, uint256 amount) {

        //how much credit we have
        (, uint256 liquidity, uint256 shortfall) = SComptrollerI(ironBank).getAccountLiquidity(address(this));
        uint256 underlyingPrice = SComptrollerI(ironBank).oracle().getUnderlyingPrice(address(ironBankToken));
        
        if(underlyingPrice == 0){
            return (false, 0);
        }

        liquidity = liquidity.mul(1e18).div(underlyingPrice);
        shortfall = shortfall.mul(1e18).div(underlyingPrice);

        uint256 outstandingDebt = ironBankOutstandingDebtStored();

        //repay debt if iron bank wants its money back
        //we need careful to not just repay the bare minimun as it will go over immediately again and loop here forever
        if(shortfall > debtThreshold){
            //note we only borrow 1 asset so can assume all our shortfall is from it
            return(false, Math.min(outstandingDebt, shortfall.mul(2))); //return double our shortfall
        }

        uint256 liquidityAvailable = want.balanceOf(address(ironBankToken));
        uint256 remainingCredit = Math.min(liquidity, liquidityAvailable);
        
        // if we have too much debt we return
        //overshoot incase of dust
        if(maxBorrow.mul(11).div(10) < outstandingDebt){
            amount = maxBorrow < outstandingDebt ?  outstandingDebt - maxBorrow : 0;
            if(amount >= debtThreshold){
                return (false, amount);
            }
            amount = 0;
        }

        //we move in 1/step increments
        uint256 minIncrement = maxBorrow.div(step);

        //we start at 1 to save some gas
        uint256 increment = 1;

        //iron bank borrow rate
        uint256 ironBankBR = ironBankBorrowRate(0, true);
        uint256 desiredBR = targetAPR.div(BLOCKSPERYEAR); //apr is per block

        uint256 maxCreditDesired = maxBorrow;

        //if sr is > iron bank we borrow more. else return
        if(desiredBR > ironBankBR){       
            if(maxCreditDesired < outstandingDebt){
                maxCreditDesired = outstandingDebt;
            }  
            remainingCredit = Math.min(maxCreditDesired.sub(outstandingDebt), remainingCredit);

            while(minIncrement.mul(increment) <= remainingCredit){
                ironBankBR = ironBankBorrowRate(minIncrement.mul(increment), false);
                if(desiredBR <= ironBankBR){
                    break;
                }

                increment++;
            }
            borrowMore = true;
            amount = minIncrement.mul(increment-1);

        }else{

            while(minIncrement.mul(increment) <= outstandingDebt){
                ironBankBR = ironBankBorrowRate(minIncrement.mul(increment), true);

                //we do increment before the if statement here
                increment++;
                if(desiredBR > ironBankBR){
                    break;
                }

            }
            borrowMore = false;

            //special case to repay all
            if(increment == 1){
                amount = outstandingDebt;
            }else{
                amount = minIncrement.mul(increment - 1);
            }

        }

        //we dont play with dust:
        if (amount < debtThreshold) { 
            amount = 0;
        }
     }
    

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        require(vault.creditAvailable() == 0, "Debt Ratio To Zero");

        //note: need to burn strategist and rewards so that vault tokens can't be withdrawn
        require(rewards == address(0), "Burn rewards");
        require(strategist == address(0), "Burn Strategist");


        //start off by borrowing or returning:
        (bool borrowMore, uint256 amount) = internalCreditOfficer();

        (uint256 profit, ) = pnl();

        if(!borrowMore){
            //we are reducing position so a good time to take profits
            profit = profit > buffer ? profit - buffer : 0;

            //add profit to amount we are reducing position by
            uint256 toWithdraw = amount.add(profit);

            uint256 withdrawn;
            if(toWithdraw > 0){
                withdrawn = _withdrawFromVault(toWithdraw);
            }


            if(amount > 0 && withdrawn > 0){
                SCErc20I(ironBankToken).repayBorrow(Math.min(amount, withdrawn));
            }
           
        }else{
            if(amount > 0){
                // on scale up we will only take profits from the amount we borrow
                SCErc20I(ironBankToken).borrow(amount);
            }
        }

        _profit = Math.min(profit, wantBalance());
        
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed){
        vault.withdraw();
        SCErc20I(ironBankToken).repayBorrow(Math.min(wantBalance(), ironBankOutstandingDebtCurrent()));
        _amountFreed = wantBalance();
    }

    function ethToWant(uint256 _amount) public override view returns (uint256) {
        return _amount;
    }

    //much simplified harvest trigger
    function harvestTrigger(uint256 callCostInWei) public view override returns (bool) {
        
        StrategyParams memory params = vault.strategies(address(this));
        // Should not trigger if we haven't waited long enough since previous harvest
        if (block.timestamp.sub(params.lastReport) < minReportDelay) return false;

        // Should trigger if hasn't been called in a while
        if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

        return false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {

        uint256 toInvest = wantBalance();
        if(toInvest > 0){
            vault.deposit();

        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        //should never run
    }

    function prepareMigration(address _newStrategy) internal override {
        require(false, "NO MIGRATE");
    }


    function protectedTokens()
        internal
        override
        view
        returns (address[] memory)
    {
    }
}

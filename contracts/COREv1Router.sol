pragma solidity 0.6.12;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@nomiclabs/buidler/console.sol";

import "./interfaces/IWETH9.sol";
import "./interfaces/IFeeApprover.sol";
// import "./uniswapv2/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './libraries/Math.sol';

import "./libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./ICoreVault.sol";


contract COREv1Router is Ownable {

    using SafeMath for uint256;
    mapping(address => uint256) public hardCORE;

    address public _coreToken;
    address public _coreWETHPair;
    IFeeApprover public _feeApprover;
    ICoreVault public _coreVault;
    IWETH public _WETH;
    address public _uniV2Factory;

    constructor(address coreToken, address WETH, address uniV2Factory, address coreWethPair, address feeApprover, address coreVault) public {
        _coreToken = coreToken;
        _WETH = IWETH(WETH);
        _uniV2Factory = uniV2Factory;
        _feeApprover = IFeeApprover(feeApprover);
        _coreWETHPair = coreWethPair;
        _coreVault = ICoreVault(coreVault);
        refreshApproval();
    }

    function refreshApproval() public {
        IUniswapV2Pair(_coreWETHPair).approve(address(_coreVault), uint(-1));
    }

    event FeeApproverChanged(address indexed newAddress, address indexed oldAddress);

    fallback() external payable {
        if(msg.sender != address(_WETH)){
             addLiquidityETHOnly(msg.sender, false);
        }
    }


    function addLiquidityETHOnly(address payable to, bool autoStake) public payable {
        hardCORE[msg.sender] = hardCORE[msg.sender].add(msg.value);

        uint256 buyAmount = msg.value.div(2);
        require(buyAmount > 0, "Insufficient ETH amount");
        _WETH.deposit{value : msg.value}();

        (uint256 reserveWeth, uint256 reserveCore) = getPairReserves();
        uint256 outCore = UniswapV2Library.getAmountOut(buyAmount, reserveWeth, reserveCore);
        
        _WETH.transfer(_coreWETHPair, buyAmount);

        (address token0, address token1) = UniswapV2Library.sortTokens(address(_WETH), _coreToken);
        IUniswapV2Pair(_coreWETHPair).swap(_coreToken == token0 ? outCore : 0, _coreToken == token1 ? outCore : 0, address(this), "");

        _addLiquidity(outCore, buyAmount, to, autoStake);

        _feeApprover.sync();
    }

    function _addLiquidity(uint256 coreAmount, uint256 wethAmount, address payable to, bool autoStake) internal {
        (uint256 wethReserve, uint256 coreReserve) = getPairReserves();

        uint256 optimalCoreAmount = UniswapV2Library.quote(wethAmount, wethReserve, coreReserve);

        uint256 optimalWETHAmount;
        if (optimalCoreAmount > coreAmount) {
            optimalWETHAmount = UniswapV2Library.quote(coreAmount, coreReserve, wethReserve);
            optimalCoreAmount = coreAmount;
        }
        else
            optimalWETHAmount = wethAmount;

        assert(_WETH.transfer(_coreWETHPair, optimalWETHAmount));
        assert(IERC20(_coreToken).transfer(_coreWETHPair, optimalCoreAmount));

        if (autoStake) {
            IUniswapV2Pair(_coreWETHPair).mint(address(this));
            _coreVault.depositFor(to, 0, IUniswapV2Pair(_coreWETHPair).balanceOf(address(this)));
        }
        else
            IUniswapV2Pair(_coreWETHPair).mint(to);
        

        //refund dust
        if (coreAmount > optimalCoreAmount)
            IERC20(_coreToken).transfer(to, coreAmount.sub(optimalCoreAmount));

        if (wethAmount > optimalWETHAmount) {
            uint256 withdrawAmount = wethAmount.sub(optimalWETHAmount);
            _WETH.withdraw(withdrawAmount);
            to.transfer(withdrawAmount);
        }
    }

    function changeFeeApprover(address feeApprover) external onlyOwner {
        address oldAddress = address(_feeApprover);
        _feeApprover = IFeeApprover(feeApprover);

        emit FeeApproverChanged(feeApprover, oldAddress);    
    }


    function getLPTokenPerEthUnit(uint ethAmt) public view  returns (uint liquidity){
        (uint256 reserveWeth, uint256 reserveCore) = getPairReserves();
        uint256 outCore = UniswapV2Library.getAmountOut(ethAmt.div(2), reserveWeth, reserveCore);
        uint _totalSupply =  IUniswapV2Pair(_coreWETHPair).totalSupply();

        (address token0, ) = UniswapV2Library.sortTokens(address(_WETH), _coreToken);
        (uint256 amount0, uint256 amount1) = token0 == _coreToken ? (outCore, ethAmt.div(2)) : (ethAmt.div(2), outCore);
        (uint256 _reserve0, uint256 _reserve1) = token0 == _coreToken ? (reserveCore, reserveWeth) : (reserveWeth, reserveCore);
        liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);


    }

    function getPairReserves() internal view returns (uint256 wethReserves, uint256 coreReserves) {
        (address token0,) = UniswapV2Library.sortTokens(address(_WETH), _coreToken);
        (uint256 reserve0, uint reserve1,) = IUniswapV2Pair(_coreWETHPair).getReserves();
        (wethReserves, coreReserves) = token0 == _coreToken ? (reserve1, reserve0) : (reserve0, reserve1);
    }

}
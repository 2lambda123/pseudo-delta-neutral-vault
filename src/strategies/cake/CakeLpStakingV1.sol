pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "pancakeswap-peripheral/contracts/interfaces/IPancakeRouter02.sol";
import "@pancakeswap-libs/pancake-swap-core/contracts/interfaces/IPancakePair.sol";
import "../common/interfaces/IMasterChef.sol";
import "../common/AbstractStrategy.sol";
import "../utils/StringUtils.sol";

contract CakeLpStakingV1 is AbstractStrategy {
    using SafeERC20 for IERC20;

    // Tokens used
    address public native;
    address public reward;
    address public stake;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public chef;
    uint256 public poolId;

    uint256 public lastHarvest;
    string public pendingRewardsFunctionName;

    // Routes
    address[] public rewardToNativeRoute;
    address[] public rewardToLp0Route;
    address[] public rewardToLp1Route;

    //Events
    event StratHarvest(
        address indexed harvester,
        uint256 stakeHarvested,
        uint256 tvl
    );
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    ///@dev
    ///@param _stake: the token which is staked in the pool
    ///@param _poolId: Pool id of the LP pool in cake swap
    ///@param _chef: master chef contract of the pancake swap protocol
    ///@param _commonAddresses: Has addresses common to all vaults, check Rivera Fee manager for more info
    ///@param _rewardToNativeRoute: Route to convert the reward tokens from the staking pool to native tokens of the blockchain
    ///@param _rewardToLp0Route: Route to convert the reward tokens from the staking pool to token 0 of the LP (Liquidity Pool or Liquidity Pair)
    ///@param _rewardToLp1Route: Route to convert the reward tokens from the staking pool to token 1 of the LP (Liquidity Pool or Liquidity Pair)
    constructor(
        address _stake,
        uint256 _poolId,
        address _chef,
        CommonAddresses memory _commonAddresses,
        address[] memory _rewardToNativeRoute,
        address[] memory _rewardToLp0Route,
        address[] memory _rewardToLp1Route
    ) AbstractStrategy(_commonAddresses) {
        stake = _stake;
        poolId = _poolId;
        chef = _chef;

        reward = _rewardToNativeRoute[0];
        native = _rewardToNativeRoute[_rewardToNativeRoute.length - 1];
        rewardToNativeRoute = _rewardToNativeRoute;

        // setup lp routing
        lpToken0 = IPancakePair(stake).token0();
        require(
            _rewardToLp0Route[0] == reward,
            "rewardToLp0Route[0] != reward"
        );
        require(
            _rewardToLp0Route[_rewardToLp0Route.length - 1] == lpToken0,
            "rewardToLp0Route[last] != lpToken0"
        );
        rewardToLp0Route = _rewardToLp0Route;

        lpToken1 = IPancakePair(stake).token1();
        require(
            _rewardToLp1Route[0] == reward,
            "rewardToLp1Route[0] != reward"
        );
        require(
            _rewardToLp1Route[_rewardToLp1Route.length - 1] == lpToken1,
            "rewardToLp1Route[last] != lpToken1"
        );
        rewardToLp1Route = _rewardToLp1Route;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused onlyVault {
        //Entire LP balance of the strategy contract address is deployed to the farm to earn CAKE
        uint256 stakeBal = IERC20(stake).balanceOf(address(this));

        if (stakeBal > 0) {
            IMasterChef(chef).deposit(poolId, stakeBal);
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external onlyVault {
        //Pretty Straight forward almost same as AAVE strategy
        uint256 stakeBal = IERC20(stake).balanceOf(address(this));

        if (stakeBal < _amount) {
            IMasterChef(chef).withdraw(poolId, _amount - stakeBal);
            stakeBal = IERC20(stake).balanceOf(address(this));
        }

        if (stakeBal > _amount) {
            stakeBal = _amount;
        }

        IERC20(stake).safeTransfer(vault, stakeBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external virtual {}

    function harvest() external virtual {
        _harvest();
    }

    function managerHarvest() external onlyManager {
        _harvest();
    }

    // compounds earnings and charges performance fee
    function _harvest() internal whenNotPaused {
        IMasterChef(chef).deposit(poolId, 0); //Deopsiting 0 amount will not make any deposit but it will transfer the CAKE rewards owed to the strategy.
        //This essentially harvests the yeild from CAKE.
        uint256 rewardBal = IERC20(reward).balanceOf(address(this)); //reward tokens will be CAKE. Cake balance of this strategy address will be zero before harvest.
        if (rewardBal > 0) {
            addLiquidity();
            uint256 stakeHarvested = balanceOfstake();
            deposit(); //Deposits the LP tokens from harvest

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, stakeHarvested, balanceOf());
        }
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        //Should convert the CAKE tokens harvested into WOM and BUSD tokens and depost it in the liquidity pool. Get the LP tokens and stake it back to earn more CAKE.
        uint256 rewardHalf = IERC20(reward).balanceOf(address(this)) / 2; //It says IUniswap here which might be inaccurate. If the address is that of pancake swap and method signatures match then the call should be made correctly.
        if (lpToken0 != reward) {
            //Using Uniswap to convert half of the CAKE tokens into Liquidity Pair token 0
            IPancakeRouter02(router).swapExactTokensForTokens(
                rewardHalf,
                0,
                rewardToLp0Route,
                address(this),
                block.timestamp
            );
        }

        if (lpToken1 != reward) {
            //Using Uniswap to convert half of the CAKE tokens into Liquidity Pair token 1
            IPancakeRouter02(router).swapExactTokensForTokens(
                rewardHalf,
                0,
                rewardToLp1Route,
                address(this),
                block.timestamp
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IPancakeRouter02(router).addLiquidity( //Liquidity is getting added into to the Liquidity Pair again. This will give the strategy more LP tokens.
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            block.timestamp
        );
    }

    // calculate the total underlaying 'stake' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfstake() + balanceOfPool();
    }

    // it calculates how much 'stake' this contract holds.
    function balanceOfstake() public view returns (uint256) {
        return IERC20(stake).balanceOf(address(this));
    }

    // it calculates how much 'stake' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        //_amount is the LP token amount the user has provided to stake
        (uint256 _amount, ) = IMasterChef(chef).userInfo(poolId, address(this));
        return _amount;
    }

    function setPendingRewardsFunctionName(
        string calldata _pendingRewardsFunctionName
    ) external onlyManager {
        //Interesting! function name that has to be used itself can be treated as an arguement
        pendingRewardsFunctionName = _pendingRewardsFunctionName;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        //Returns the rewards available to the strategy contract from the pool
        string memory signature = StringUtils.concat(
            pendingRewardsFunctionName,
            "(uint256,address)"
        );
        bytes memory result = Address.functionStaticCall(
            chef,
            abi.encodeWithSignature(signature, poolId, address(this))
        );
        return abi.decode(result, (uint256));
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external onlyVault {

        IMasterChef(chef).emergencyWithdraw(poolId);

        uint256 stakeBal = IERC20(stake).balanceOf(address(this));
        IERC20(stake).transfer(vault, stakeBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMasterChef(chef).emergencyWithdraw(poolId);
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(stake).safeApprove(chef, type(uint256).max);
        IERC20(reward).safeApprove(router, type(uint256).max);

        IERC20(lpToken0).safeApprove(router, 0);
        IERC20(lpToken0).safeApprove(router, type(uint256).max);

        IERC20(lpToken1).safeApprove(router, 0);
        IERC20(lpToken1).safeApprove(router, type(uint256).max);
    }

    function _removeAllowances() internal {
        IERC20(stake).safeApprove(chef, 0);
        IERC20(reward).safeApprove(router, 0);
        IERC20(lpToken0).safeApprove(router, 0);
        IERC20(lpToken1).safeApprove(router, 0);
    }

    function rewardToNative() external view returns (address[] memory) {
        return rewardToNativeRoute;
    }

    function rewardToLp0() external view returns (address[] memory) {
        return rewardToLp0Route;
    }

    function rewardToLp1() external view returns (address[] memory) {
        return rewardToLp1Route;
    }
}

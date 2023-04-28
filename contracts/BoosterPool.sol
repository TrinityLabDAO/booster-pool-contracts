// SPDX-License-Identifier: MIT
// Copyright (c) 2021 TrinityLabDAO

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
pragma solidity 0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "./libraries/TickMath.sol";
import "./libraries/LiquidityAmounts.sol";


/**
 * @title   Booster pool
 * @notice  A pool that provides liquidity on Uniswap V3.
 */
contract BoosterPool is
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback,
    ERC20,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    event OneAsset(
        address indexed token,
        uint256 amount
    );

    event Deposit(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event Withdraw(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice The event is called when there is a collection of fees from a uniswap.
     * @param feesToPool0 users reward received in token 0
     * @param feesToPool1 users reward received in token 1
     * @param feesToTreasuryA0 protocol 'A' commission from earned reward received in token 0, will be stored in the 'Treasury A'
     * @param feesToTreasuryA1 protocol 'A' commission from earned reward received in token 1, will be stored in the 'Treasury A'
     * @param feesToTreasuryB0 protocol 'B' commission from earned reward received in token 0, will be stored in the 'Treasury B'
     * @param feesToTreasuryB1 protocol 'B' commission from earned reward received in token 1, will be stored in the 'Treasury B'
     */
    event CollectFees(
        uint256 feesToPool0,
        uint256 feesToPool1,
        uint256 feesToTreasuryA0,
        uint256 feesToTreasuryA1,
        uint256 feesToTreasuryB0,
        uint256 feesToTreasuryB1
    );
    
    //event Snapshot(int24 tick, uint256 totalAmount0, uint256 totalAmount1, uint256 totalSupply);

    /**
     * @notice Events that change key protocol variables
     */
    event AddressA(address oldAddress, address newAddress);
    event AddressB(address oldAddress, address newAddress);
    event ProtocolFeeA(uint256 oldProtocolFee, uint256 newProtocolFee);
    event ProtocolFeeB(uint256 oldProtocolFee, uint256 newProtocolFee);
    event PendingGovernance(address candidate);
    event Governance(address oldGovernance, address newGovernance);
    event Strategy(address oldStrategy, address newStrategy);
    /**
     * @notice Protocol deactivation event, after that only withdrawals work
     */
    event Deactivate();

    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    int24 public immutable tickSpacing;

    address public governance;
    address public pendingGovernance;
    address public strategy;
    
    int24 public baseLower;
    int24 public baseUpper;

    address public addressA;
    address public addressB;
    uint256 public protocolFeeA;
    uint256 public protocolFeeB;

    uint256 public treasuryA0;
    uint256 public treasuryA1;

    uint256 public treasuryB0;
    uint256 public treasuryB1;

    bool public isDeactivated;

    /**
     * @param _pool Underlying Uniswap V3 pool
     * @param _addressB Address with access to Treasury A
     * @param _addressB Address with access to Treasury B
     * @param _protocolFeeA Protocol fee expressed as multiple of 1e-6, accumulates in the treasuryA
     * @param _protocolFeeB Protocol fee expressed as multiple of 1e-6, accumulates in the treasuryB
     * _protocolFeeA and _protocolFeeB in total must not exceed 1e-6
     * @param tokenName Token name
     * @param tokenSymbol Token symbol
     * @param _strategy Address that can rebalance 
     * @param _tickLower Position tick lower
     * @param _tickUpper Position tick upper
     */
    constructor(
        address _pool,
        address _addressA,
        address _addressB,
        uint256 _protocolFeeA,
        uint256 _protocolFeeB,
        string memory tokenName,
        string memory tokenSymbol,
        address _strategy,
        int24 _tickLower,
        int24 _tickUpper
    ) ERC20(tokenName, tokenSymbol) {
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(IUniswapV3Pool(_pool).token0());
        token1 = IERC20(IUniswapV3Pool(_pool).token1());
        int24 _tickSpacing = IUniswapV3Pool(_pool).tickSpacing();
        tickSpacing = _tickSpacing;

        governance = msg.sender;
        require(_strategy != address(0) && _strategy != address(this), "_strategy");
        strategy = _strategy;
        isDeactivated = false;
        require(_addressA != address(0) && _addressA != address(this), "_addressA");
        addressA = _addressA;
        require(_addressB != address(0) && _addressB != address(this), "_addressBto");
        addressB = _addressB;
        protocolFeeA = _protocolFeeA;
        protocolFeeB = _protocolFeeB; 
        require((_protocolFeeA + _protocolFeeB) < 1e6, "protocolFee");

         _checkRange(_tickLower, _tickUpper, _tickSpacing);
        baseLower = _tickLower;
        baseUpper = _tickUpper; 
    }

    //
    // EXTERNAL NON-VIEW
    //

    /**
     * @notice Deposit in one of two assets.
     * Part of the assets is exchanged in the Uniswap pool to obtain the required proportion.
     * Surplus will be returned to the user.
     * @dev The calculation uses the current price in the pool and
     * calculates the proportion for the deposit in a certain uniswap range at the initial moment.
     * The impact on the price and the proportion of the deposit is not taken into account, it only affects the size of the refund.
     * @param token Deposit token address
     * @param amount Max amount of token to deposit
     * @param to Recipient of shares
     * @return shares Number of shares minted
     * @return amount0 Amount of token0 deposited
     * @return amount1 Amount of token1 deposited
     */
    function depositOneAsset(
        address token,
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 shares, uint256 amount0, uint256 amount1){
        require(!isDeactivated, "deactivated"); 
        require(amount > 0 , "amount");
        require(token != address(0) && token != address(this), "token");
        require((address(token0) == token) || (address(token1) == token), "incorrect token");

        // Poke positions so vault's current holdings are up-to-date
        _poke(baseLower, baseUpper);

        //оценка
        (uint256 estimatedAmount0, uint256 estimatedAmount1) = estimatedAmountsForOneAsset(token, amount);

        uint256 startAmount0 = getBalance0();
        uint256 startAmount1 = getBalance1();

        //Transfer desired amount to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit OneAsset(token, amount);

        if(address(token0) == token){
            if(estimatedAmount0 < estimatedAmount1)
                _sellExact(token, amount - estimatedAmount0, 0);
            else
                _buyExact(token, estimatedAmount1, 0);
        }else{
            if(amount0 < estimatedAmount1)
                _buyExact(token, estimatedAmount0, 0);
            else
                _sellExact(token, amount - estimatedAmount1, 0);
        }
        //calculation of the desired deposit amount after the swap
        //the deposit amount is the current balance of the contract minus the starting balance of the contract
        uint256 desiredAmount0 = getBalance0() - startAmount0;
        uint256 desiredAmount1 = getBalance1() - startAmount1;

        (shares, amount0, amount1) = _calcSharesAndAmounts(desiredAmount0, desiredAmount1, startAmount0, startAmount1);
        require(shares > 0, "shares to low");
        //the amount of assets that was not placed in the pool and will be returned to the sender
        uint256 refund0 = getBalance0() - startAmount0 - amount0;
        uint256 refund1 = getBalance1() - startAmount1 - amount1;

        if(refund0 > 0)
            token0.safeTransfer(msg.sender, refund0);
        if(refund1 > 0)
            token1.safeTransfer(msg.sender, refund1);
        // Mint shares to recipient
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amount0, amount1);
        _reinvest(0, 0);
    }

    /**
     * @notice Deposits tokens in the current proportion of the uniswap pool in the set range.
     * @dev The user's tokens are immediately placed in the uniswap pool.
     * Also, along with this, there is a reinvestment of previously earned fees.
     * @param amount0Desired Max amount of token0 to deposit
     * @param amount1Desired Max amount of token1 to deposit
     * @param amount0Min Revert if resulting `amount0` is less than this
     * @param amount1Min Revert if resulting `amount1` is less than this
     * @param to Recipient of shares
     * @return shares Number of shares minted
     * @return amount0 Amount of token0 deposited
     * @return amount1 Amount of token1 deposited
     */
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 shares, uint256 amount0, uint256 amount1){
        require(!isDeactivated, "deactivated"); 
        require(amount0Desired > 0 || amount1Desired > 0, "amount0Desired or amount1Desired");
        require(to != address(0) && to != address(this), "to");

        // Poke positions so vault's current holdings are up-to-date
        _poke(baseLower, baseUpper);

        // Calculate amounts proportional to vault's holdings
        (shares, amount0, amount1) = _calcSharesAndAmounts(amount0Desired, amount1Desired, getBalance0(), getBalance1());
        require(shares > 0, "shares");
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");

        // Pull in tokens from sender
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);

        //Mint shares to recipient
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amount0, amount1);
        _reinvest(0, 0);
    }

    function calcSharesAndAmounts(uint256 amount0Desired, uint256 amount1Desired)
        external
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        _poke(baseLower, baseUpper);
        (shares, amount0, amount1) = _calcSharesAndAmounts(amount0Desired, amount1Desired, getBalance0(), getBalance1());
    }

    /**
     * @notice Withdraws tokens in proportion to the position in Uniswap.
     * @dev The dust that remains when reinvesting fees is not used in the calculations.
     * The bot monitors the accumulation of dust and, if necessary, reinvests with a swap
     * @param shares Shares burned by sender
     * @param amount0Min Revert if resulting `amount0` is smaller than this
     * @param amount1Min Revert if resulting `amount1` is smaller than this
     * @param to Recipient of tokens
     * @return amount0 Amount of token0 sent to recipient
     * @return amount1 Amount of token1 sent to recipient
     */
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares");
        require(to != address(0) && to != address(this), "to");
        uint256 BPtotalSupply = totalSupply();

        // Burn shares
        _burn(msg.sender, shares);

        //if the pool is deactivated, then the assets are taken from the contract storage, in proportion to the boosterPool tokens
        if(isDeactivated){
            // Calculate token amounts proportional to unused balances
            amount0 = getBalance0() * shares / BPtotalSupply;
            amount1 = getBalance1() * shares / BPtotalSupply;
        } else {
            // Withdraw proportion of liquidity from Uniswap pool
            (amount0, amount1) = _burnLiquidityShare(baseLower, baseUpper, shares, BPtotalSupply);
        }

        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");

        // Push tokens to recipient
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);

        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    /**
     * @notice The fees earned are withdrawn from Uniswap V3 
     * and the maximum possible liquidity is deposited into the position.
     * @param swapAmount the number of tokens to be exchanged. 
     * A positive or negative value indicates the direction of the swap 
     * (zeroForOne - The direction of the swap, true for token0 to token1, false for token1 to token0)
     * @param sqrtPriceLimitX96 - The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this value after the swap. If one for zero, the price cannot be greater than this value after the swap
     */
    function reinvest(
        int256 swapAmount,
        uint160 sqrtPriceLimitX96
    ) external nonReentrant {
        require(!isDeactivated, "deactivated"); 
        require(msg.sender == strategy, "strategy");
        _poke(baseLower, baseUpper);
        _reinvest(swapAmount, sqrtPriceLimitX96);
    }

    /**
     * @notice Updates positions. Can only be called by the strategy.
     * @param swapAmount the number of tokens to be exchanged. 
     * A positive or negative value indicates the direction of the swap 
     * (zeroForOne - The direction of the swap, true for token0 to token1, false for token1 to token0)
     * @param sqrtPriceLimitX96 - The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this value after the swap. If one for zero, the price cannot be greater than this value after the swap
     * @param tickLower new tick lower
     * @param tickUpper new tick upper
     */
    function rebalance(
        int256 swapAmount,
        uint160 sqrtPriceLimitX96,
        int24 tickLower,
        int24 tickUpper
    ) external nonReentrant {
        require(!isDeactivated, "deactivated"); 
        require(msg.sender == strategy, "strategy");   
        _checkRange(tickLower, tickUpper, tickSpacing);

        // Withdraw all current liquidity from Uniswap pool
        (uint128 baseLiquidity, , , , ) = _position(baseLower, baseUpper);
        _burnAndCollect(baseLower, baseUpper, baseLiquidity);
        
        // swap and mint liquidity to position
        _swapAndMint(swapAmount, sqrtPriceLimitX96, tickLower, tickUpper);
        (baseLower, baseUpper) = (tickLower, tickUpper);
    }

    /**
     * @notice calculates how many assets token0 and token1 can be obtained for BP tokens
     * @dev used with static call in frontend
     * @param amountBP Amount of BP tokens for whom the calculation
     * @return amount0 computed value of token0
     * @return amount1 computed value of token1
     */
    function getTotalAmounts(uint256 amountBP)
        external
        returns(uint256 amount0, uint256 amount1)
    {
        uint256 BPtotalSupply = totalSupply();
        if(BPtotalSupply > 0){
            _poke(baseLower, baseUpper);
            (amount0,  amount1) = _getPositionAmounts();
            (amount0,  amount1) = ((amount0 * amountBP / BPtotalSupply), (amount1 * amountBP / BPtotalSupply));
        } else {
            (amount0,  amount1) = (0,0);
        }
    }

    /**
     * @notice Amounts of token0 and token1 in the Uniswap V3 pool to be collected
     * @return collect0 amount of accrued fees in token0
     * @return collect1 amount of accrued fees in token1
     */
    function collectPositionFees()
        external
        returns(uint256 collect0, uint256 collect1)
    {
        _poke(baseLower, baseUpper);
        (,,collect0, collect1) = _burnAndCollect(baseLower, baseUpper, 0);
    }

    /**
     * @notice Used to collect accumulated protocol fees from the treasury A.
     * @param amount0 amount token0 to the collect
     * @param amount1 amount token1 to the collect
     * @param to Recipient of tokens
     */
    function collectTreasuryA(
        uint256 amount0,
        uint256 amount1,
        address to
    ) external onlyAddressA {
        treasuryA0 = treasuryA0 - amount0;
        treasuryA1 = treasuryA1 - amount1;
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);
    }

    /**
     * @notice Used to collect accumulated protocol fees from the treasury B.
     * @param amount0 amount token0 to the collect
     * @param amount1 amount token1 to the collect
     * @param to Recipient of tokens
     */
    function collectTreasuryB(
        uint256 amount0,
        uint256 amount1,
        address to
    ) external onlyAddressB {
        treasuryB0 = treasuryB0 - amount0;
        treasuryB1 = treasuryB1 - amount1;
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);
    }

    /**
     * @notice Removes tokens accidentally sent to this vault.
     * @param token token to the sweep
     * @param amount amount to the sweep
     * @param to Recipient of tokens
     */
    function sweep(
        IERC20 token,
        uint256 amount,
        address to
    ) external onlyGovernance {
        require(token != token0 && token != token1, "token");
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Used to set the strategy contract that determines the position
     * ranges and calls rebalance(). Must be called after this vault is
     * deployed.
     */
    function setStrategy(address newStrategy) external onlyGovernance {
        require(newStrategy != address(0) && newStrategy != address(this), "strategy");
        emit Strategy(strategy, newStrategy);
        strategy = newStrategy;
    }

    /**
     * @notice Setting a new address that will have access to Treasure A
     * @param newAddressA new address to use Treasury A
     */
    function setAddressA(address newAddressA) external onlyGovernance {
        require(newAddressA != address(0) && newAddressA != address(this), "addressA");
        emit AddressA(addressA, newAddressA);
        addressA = newAddressA;       
    }

    /**
     * @notice Setting a new address that will have access to Treasure B
     * @param newAddressB new address to use Treasury B
     */
    function setAddressB(address newAddressB) external onlyGovernance {
        require(newAddressB != address(0) && newAddressB != address(this), "addressB");
        emit AddressB(addressB, newAddressB);
        addressB = newAddressB;
    }

    /**
     * @notice Used to change the protocol fee charged on pool fees earned from
     * Uniswap, expressed as multiple of 1e-6.
     * @param newProtocolFeeA new fee value
     */
    function setProtocolFeeA(uint256 newProtocolFeeA) external onlyGovernance {
        require((newProtocolFeeA + protocolFeeB) < 1e6, "protocolFeeA");
        emit ProtocolFeeA(protocolFeeA, newProtocolFeeA);
        protocolFeeA = newProtocolFeeA;
    }

    /**
     * @notice Used to change the protocol fee charged on pool fees earned from
     * Uniswap, expressed as multiple of 1e-6.
     * @param newProtocolFeeB new fee value
     */
    function setProtocolFeeB(uint256 newProtocolFeeB) external onlyGovernance {
        require((newProtocolFeeB + protocolFeeA) < 1e6, "protocolFeeB");
        emit ProtocolFeeB(protocolFeeB, newProtocolFeeB);
        protocolFeeB = newProtocolFeeB;
    }

    /**
     * @notice The method disables the protocol, only the withdrawal of funds by users remains available.
     */
    function deactivateMode() external onlyGovernance {
        require(!isDeactivated, "deactivated"); 
        isDeactivated = true;
        (uint128 baseLiquidity, , , , ) = _position(baseLower, baseUpper);
        _burnAndCollect(baseLower, baseUpper, baseLiquidity);
        emit Deactivate();
    }

    /**
     * @notice Governance address is not updated until the new governance
     * address has called `acceptGovernance()` to accept this responsibility.
     * @param newGovernance new governance address
     */
    function setGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0) && newGovernance != address(this), "governance");
        pendingGovernance = newGovernance;
        emit PendingGovernance(pendingGovernance);
    }

    /**
     * @notice `setGovernance()` should be called by the existing governance
     * address prior to calling this function.
     */
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "pendingGovernance");
        emit Governance(governance, msg.sender);
        governance = msg.sender;    
    }

    //
    // EXTERNAL VIEW
    //

    /**
     * @notice Calculates the estimated amounts to deposit in a uniswap V3 from one of asset.
     * @dev the calculation has assumptions in the values ​​of priceRatio and poolRatio,
     * does not take into account the impact of the swap on the price and proportion in the uniswap pool
     * x - deposit expressed in token0 
     * y - deposit expressed in token1 
     * pool_x, pool_y - proportion of assets in the pool
     * 
     *               x 
     * price_ratio = ―         - proportion of assets at the current price
     *               y
     *
     *              pool_x 
     * pool_ratio = ――――――     - proportion of assets in the pool
     *              pool_y
     *
     *                    x 
     * deposit_x = ―――――――――――――――
     *                 price_ratio 
     *             1 + ―――――――――――
     *                 pool_ratio
     *
     *             x - deposit_x
     * deposit_y = ―――――――――――――
     *              price_ratio
     *
     * @param token deposit token address
     * @param amount desired deposit amount
     * @return amount0 estimated Amount of token0
     * @return amount1 estimated Amount of token1
     */
    function estimatedAmountsForOneAsset(
        address token,
        uint256 amount
    ) public view returns (uint256 amount0, uint256 amount1){

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(baseLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(baseUpper);
        uint256 calc_amount0;
        uint256 calc_amount1;
        if(address(token0) == token){
            calc_amount0 = amount;
            calc_amount1 = FullMath.mulDiv(amount, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);
        }else{
            calc_amount0 = FullMath.mulDiv(amount, 1 << 192, uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
            calc_amount1 = amount;
        }

        require(calc_amount0 > 0 , "LA 0");
        require(calc_amount1 > 0 , "LA 1");

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            1e18
        );

        amount0 = FullMath.mulDiv(calc_amount0 * amount0,
                            amount1 * calc_amount1,
                            amount1 * (calc_amount1 * amount0 + amount1 * calc_amount0));

        amount1 = FullMath.mulDiv(calc_amount0 - amount0,
                                calc_amount1,
                                calc_amount0);
    }

    /**
     * @notice Balance of token0 in vault not used in any position.
     */
    function getBalance0() public view returns (uint256) {
        return token0.balanceOf(address(this)) - treasuryA0 - treasuryB0;
    }

    /**
     * @notice Balance of token1 in vault not used in any position.
     */
    function getBalance1() public view returns (uint256) {
        return token1.balanceOf(address(this)) - treasuryA1 - treasuryB1;
    }

    //
    // UNISWAP V3 CALLBACKS
    //
    
    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }

    //
    // INTERNAL
    //

    /// @dev Do zero-burns to poke a position on Uniswap so earned fees are
    /// updated. Should be called if total amounts needs to include up-to-date
    /// fees.
    function _poke(int24 tickLower, int24 tickUpper) internal {
        (uint128 liquidity, , , , ) = _position(tickLower, tickUpper);
        if (liquidity > 0) {
            pool.burn(tickLower, tickUpper, 0);
        }
    }
    
    function _buyExact(
        address token,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 amountIn){
        bool zeroForOne = token == address(token0);
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            address(this),
            zeroForOne,
            -int256(amountOut),
            sqrtPriceLimitX96 == 0
            ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
            : sqrtPriceLimitX96,
            ""
        );
        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
        ? (uint256(amount0Delta), uint256(-amount1Delta))
        : (uint256(amount1Delta), uint256(-amount0Delta));
        // it's technically possible to not receive the full output amount,
        // so if no price limit has been specified, require this possibility away
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    function _sellExact(
        address token,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 amountOut){
        bool zeroForOne = token == address(token0);
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            sqrtPriceLimitX96 == 0
            ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
            : sqrtPriceLimitX96,
            ""
        );
        return uint256(-(zeroForOne ? amount1 : amount0));
    }
    
    function _reinvest(
        int256 swapAmount,
        uint160 sqrtPriceLimitX96
    ) internal {
        _burnAndCollect(baseLower, baseUpper, 0);
        // swap and mint liquidity (fees) to position
        _swapAndMint(swapAmount, sqrtPriceLimitX96, baseLower, baseUpper);
    }

    function _swapAndMint(
        int256 swapAmount,
        uint160 sqrtPriceLimitX96,
        int24 _baseLower,
        int24 _baseUpper
    ) internal {
        if (swapAmount != 0) {
            pool.swap(
                address(this),
                swapAmount > 0,
                swapAmount > 0 ? swapAmount : -swapAmount,
                sqrtPriceLimitX96,
                ""
            );
        }
        // Place base order on Uniswap
        uint128 liquidity = _liquidityForAmounts(_baseLower, _baseUpper, getBalance0(), getBalance1());
        if (liquidity > 0) {
            pool.mint(address(this), _baseLower, _baseUpper, liquidity, "");
        }
    }

    /// @dev Withdraws share of liquidity in a range from Uniswap pool.
    function _burnLiquidityShare(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares,
        uint256 BPtotalSupply
    ) internal returns (uint256 amount0, uint256 amount1) {
        (uint128 totalLiquidity, , , , ) = _position(tickLower, tickUpper);
        uint256 liquidity = uint256(totalLiquidity) * shares / BPtotalSupply;

        if (liquidity > 0) {
            (uint256 burned0, uint256 burned1, uint256 fees0, uint256 fees1) =
                _burnAndCollect(tickLower, tickUpper, _toUint128(liquidity));

            // Add share of fees
            amount0 = burned0 + (fees0 * shares / BPtotalSupply);
            amount1 = burned1 + (fees1 * shares / BPtotalSupply);
        }
    }

    /// @dev Calculates the largest possible `amount0` and `amount1` such that
    /// they're in the same proportion as total amounts, but not greater than
    /// `desiredAmount0` and `desiredAmount1` respectively.
    function _calcSharesAndAmounts(uint256 desiredAmount0, uint256 desiredAmount1, uint256 contractBalance0, uint256 contractBalance1)
        internal view
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint128 liquidityUser = _liquidityForAmounts(baseLower, baseUpper, desiredAmount0, desiredAmount1);
        uint256 BPtotalSupply = totalSupply();

        uint128 liquidityTotal = _getTotalLiquidity(contractBalance0, contractBalance1);

        // If total supply > 0, vault can't be empty
        assert(BPtotalSupply == 0 || liquidityTotal > 0 );

        (amount0, amount1) = _amountsForLiquidity(baseLower, baseUpper, liquidityUser);
        //adding one penny due to loss during conversion 
        (amount0, amount1) = ((amount0 + 1), (amount1 + 1));
        if (BPtotalSupply == 0) {
            // For first deposit, just use the liquidity desired      
            shares = liquidityUser;
        } else {
            shares = uint256(liquidityUser) * BPtotalSupply / liquidityTotal;        
        }
    }

    function _checkRange(int24 tickLower, int24 tickUpper,  int24 _tickSpacing) internal pure {
        require(tickLower < tickUpper, "tickLower < tickUpper");
        require(tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
        require(tickLower % _tickSpacing == 0, "tickLower % tickSpacing");
        require(tickUpper % _tickSpacing == 0, "tickUpper % tickSpacing");
    }

    /// @dev Withdraws liquidity from a range and collects all fees in the
    /// process.
    function _burnAndCollect(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        returns (
            uint256 burned0,
            uint256 burned1,
            uint256 feesToPool0,
            uint256 feesToPool1
        )
    {
        if (liquidity > 0) {
            (burned0, burned1) = pool.burn(tickLower, tickUpper, liquidity);
        }

        // Collect all owed tokens including earned fees
        (uint256 collect0, uint256 collect1) =
            pool.collect(
                address(this),
                tickLower,
                tickUpper,
                type(uint128).max,
                type(uint128).max
            );

        feesToPool0 = collect0 - burned0;
        feesToPool1 = collect1 - burned1;

        uint256 feesToTreasuryA0 = 0;
        uint256 feesToTreasuryA1 = 0;
        uint256 feesToTreasuryB0 = 0;
        uint256 feesToTreasuryB1 = 0;

        if ((protocolFeeA + protocolFeeB) > 0) {        
            feesToTreasuryA0 = feesToPool0 * protocolFeeA / 1e6;
            feesToTreasuryA1 = feesToPool1 * protocolFeeA / 1e6;
            feesToTreasuryB0 = feesToPool0 * protocolFeeB / 1e6;
            feesToTreasuryB1 = feesToPool1 * protocolFeeB / 1e6;

            treasuryA0 = treasuryA0 + feesToTreasuryA0;
            treasuryA1 = treasuryA1 + feesToTreasuryA1;
            treasuryB0 = treasuryB0 + feesToTreasuryB0;
            treasuryB1 = treasuryB1 + feesToTreasuryB1;

            feesToPool0 = feesToPool0 - feesToTreasuryA0 - feesToTreasuryB0;
            feesToPool1 = feesToPool1 - feesToTreasuryA1 - feesToTreasuryB1;
        }
        emit CollectFees(feesToPool0, feesToPool1, feesToTreasuryA0, feesToTreasuryA1, feesToTreasuryB0, feesToTreasuryB1);
    }

    /**
    * @notice calculates the liquidity value in the Uniswap V3 pool, taking into account the accrued fee minus the protocol commission
    * @return liquidity Total liquidity in pool and booster contract
    */
    function _getTotalLiquidity(uint256 contractBalance0, uint256 contractBalance1) 
        internal view returns (uint128 liquidity) {

        (uint128 liquidityInPosition, , , uint128 tokensOwed0, uint128 tokensOwed1) =
            _position(baseLower, baseUpper);
        uint256 oneMinusFee = uint256(1e6) - (protocolFeeA + protocolFeeB);

        uint256 fees0 = uint256(tokensOwed0) * oneMinusFee / 1e6;
        uint256 fees1 = uint256(tokensOwed1) * oneMinusFee / 1e6;
        uint256 amount0 = contractBalance0 + fees0;
        uint256 amount1 = contractBalance1 + fees1;

        uint128 liquidityToReinvest = _liquidityForAmounts(baseLower, baseUpper, amount0, amount1);
        //liquidity in position add liquidity from fees and contract balance
        liquidity = liquidityInPosition + liquidityToReinvest;
    }

    /**
     * @notice Amounts of token0 and token1 held in vault's position. Includes
     * owed fees but excludes the proportion of fees that will be paid to the
     * protocol. Doesn't include fees accrued since last poke.
     */
    function _getPositionAmounts()
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) =
            _position(baseLower, baseUpper);
        (amount0, amount1) = _amountsForLiquidity(baseLower, baseUpper, liquidity);

        // Subtract protocol fees
        uint256 oneMinusFee = uint256(1e6) - (protocolFeeA + protocolFeeB);
        amount0 = amount0 + (uint256(tokensOwed0) * oneMinusFee / 1e6);
        amount1 = amount1 + (uint256(tokensOwed1) * oneMinusFee / 1e6);
    }

    /// @dev Wrapper around `IUniswapV3Pool.positions()`.
    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        bytes32 positionKey = PositionKey.compute(address(this), tickLower, tickUpper);
        return pool.positions(positionKey);
    }

    /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) public view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    /// @dev Wrapper around `LiquidityAmounts.getLiquidityForAmounts()`.
    function _liquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) public view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                amount0,
                amount1
            );
    }

    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    //
    // MODIFIERS
    //

    modifier onlyGovernance {
        require(msg.sender == governance, "governance");
        _;
    }

    modifier onlyAddressA {
        require(msg.sender == addressA, "addressA");
        _;
    }

    modifier onlyAddressB {
        require(msg.sender == addressB, "addressB");
        _;
    }
}
/*
Name (symbol) - t.me/templatename
*/

// SPDX-License-Identifier: none
pragma solidity 0.8.23;

abstract contract Auth {
    event authorizationsChange(address wallet, bool onlyAuthorized);
    event OwnershipTransferred(address owner);

    address public owner;
    mapping (address => bool) internal authorizations;
    
    constructor(address _owner) {
        owner = _owner;
        authorizations[owner] = true;
        emit OwnershipTransferred(owner);
        emit authorizationsChange(owner, true);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!OWNER");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizations[msg.sender] == true, "!AUTHORIZED");
        _;
    }

    function isOwner(address account) public view returns (bool) {
        return account == owner;
    }

    function isAuthorized(address wallet) public view returns (bool) {
        return authorizations[wallet];
    }

    function authorize(address wallet) external onlyOwner {
        authorizations[wallet] = true;
        emit authorizationsChange(wallet, true);
    }

    function unauthorize(address wallet) external onlyOwner {
        authorizations[wallet] = false;
        emit authorizationsChange(wallet, false);
    }

    function renounceAuthorization() external onlyAuthorized {
        authorizations[msg.sender] = false;
        emit authorizationsChange(msg.sender, false);
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        // We can't forget to remove the authorization
        authorizations[owner] = false;
        emit authorizationsChange(owner, false);

        owner = newOwner;
        authorizations[newOwner] = true;
        emit OwnershipTransferred(newOwner);
        emit authorizationsChange(newOwner, true);
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
        authorizations[owner] = false;
        emit OwnershipTransferred(owner);
        emit authorizationsChange(owner, false);
    }
}

interface ERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface Factory {
    function createPair(address tokenA, address tokenB) external returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface Router {
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function addLiquidityETH(address, uint256, uint256, uint256, address, uint256) external payable returns (uint256, uint256, uint256);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new pool if it does not exist, then initializes if not initialized
    /// @param token0 The contract address of token0 of the pool
    /// @param token1 The contract address of token1 of the pool
    /// @param fee The fee amount of the v3 pool for the specified token pair
    /// @param sqrtPriceX96 The initial square root price of the pool as a Q64.96 value
    /// @return pool Returns the pool address based on the pair of tokens and fee, will return the newly created pool address if necessary
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
}

interface Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    // function initialize(uint160 sqrtPriceX96) external;
}

interface TokenDeployed {
    function addLiquidityETH(uint256 dexVersion, uint256 liquidityTokenAmount, uint24 poolFee) external payable;
}

contract DeployWithLiquidity {
    address payable immutable deployer;

    constructor(uint256 dexVersion) payable {
        require(msg.value >= 100000, "minimum is 100000 wei");

        // bytes memory bytecode = type(TemplateName).creationCode;
        Template newToken = new Template(dexVersion);
        address tokenAddress = address(newToken);
        deployer = payable(msg.sender);

        uint256 deployerBalance = ERC20(tokenAddress).balanceOf(msg.sender);
        uint256 liquidityTokenAmount = deployerBalance / 100 * 98; // 98% of totalSupply in liquidity
        
        TokenDeployed(tokenAddress).addLiquidityETH{value: msg.value}(
            dexVersion,
            liquidityTokenAmount,
            10000
        );
    }

    // If something out of the ordinary happens, remember that this function does not refer to the deployed token
    function deployerRescueToken(address token, uint256 amount) external {
        ERC20(token).transfer(deployer, amount);
    }

    // If something out of the ordinary happens, remember that this function does not refer to the deployed token
	function depoyerRescueEther() external {
        deployer.transfer(address(this).balance - 3);
    }
}

contract Template is Auth {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error InsufficientBalance();
    error InsufficientAllowance();

    address immutable internal wrapped;
    address constant internal DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant internal ZERO = 0x0000000000000000000000000000000000000000;

    string public name = "TemplateName";
    string public symbol = "TemplateSymbol";

    uint8 constant public decimals = 9;
    uint256 constant public totalSupply = 100_000_000 * (10 ** decimals);

    bool public limitRuleEnabled = true;
    uint256 public maxTransaction = totalSupply / 1_000 * 10; // 1% of total supply initially
    uint256 public maxWallet = totalSupply / 1_000 * 20;      // 2% of total supply initially

    mapping (address => uint256) public balanceOf;
    mapping (address => mapping(address => uint256)) public allowance;

    mapping (address => bool) public isPool;
    mapping (address => bool) public isFeeExempt;
    mapping (address => bool) public isLimitExempt;
    
    uint256 public projectFee = 60; // 6% fee
    uint256 constant internal feeDenominator = 1_000; // 100%
    address payable public feeReceiver;

    address[] public pools;
    address public mainPool;
    uint24 private mainPoolFee = 10000; // 1% pool fee in V3 or V4;

    address immutable public poolManager; // V3
    address immutable public factory;
    address immutable public router;
    uint256 private launchedAt;

    // Contract swap does not work in v3 or v4
    bool public contractSwapEnabled = false; 
    bool internal inContractSwap;

    modifier swapping() {
        inContractSwap = true;
        _;
        inContractSwap = false;
    }

    uint256 public smallSwapThreshold = totalSupply / 1000; // 0,1% of total supply initially
    uint256 public largeSwapThreshold = totalSupply / 500;  // 0,2% of total supply initially
    uint256 public swapThreshold = smallSwapThreshold;
    
    constructor(uint256 dexVersion) Auth(tx.origin) payable {
        address deployer = tx.origin;
        feeReceiver = payable(deployer);

        (wrapped, factory, router, poolManager) = getChainDexConfig(dexVersion);

        isFeeExempt[deployer] = true;
        isFeeExempt[router] = true;
        isFeeExempt[address(this)] = true;
        
        isLimitExempt[deployer] = true;
        isLimitExempt[router] = true;
        isLimitExempt[address(this)] = true;
        isLimitExempt[DEAD] = true;
        isLimitExempt[ZERO] = true;

        if (dexVersion == 2) {
            contractSwapEnabled = true;
            _createNewPool(wrapped, 2, 0);
        } else if (dexVersion == 3) {
            _createNewPool(wrapped, 3, mainPoolFee);
        }

        allowance[address(this)][router] = type(uint256).max;
        emit Approval(address(this), router, type(uint256).max);
        
        if (poolManager != address(0)) {
            // V3
            allowance[address(this)][poolManager] = type(uint256).max;
            emit Approval(address(this), poolManager, type(uint256).max);

            isFeeExempt[poolManager] = true;
            isLimitExempt[poolManager] = true;
        }

        unchecked {
            balanceOf[deployer] += totalSupply;
            emit Transfer(address(0), deployer, totalSupply);
        }
    }

    receive() external payable {}

    function updateTokenDetails(string calldata newName, string calldata newSymbol) external onlyAuthorized {
        name = newName;
        symbol = newSymbol;
    }

    function getCirculatingSupply() external view returns (uint256) {
        return totalSupply - balanceOf[DEAD] - balanceOf[ZERO];
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////// TRANSFER //////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[sender][msg.sender];

        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();

            unchecked {
                allowance[sender][msg.sender] = allowed - amount;
            }
        }

        return _transferFrom(sender, recipient, amount);
    }

    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        if (balanceOf[sender] < amount) revert InsufficientBalance();

        bool recipientIsPool = isPool[recipient];
        bool senderIsPool = isPool[sender];

        if (launchedAt == 0 && recipientIsPool) {
            // First addLiquidity
            require(isAuthorized(tx.origin), "!AUTH");
            launchedAt = block.number; // Enable trade
        }

        if (recipientIsPool && contractSwapEnabled && !inContractSwap) {
            uint256 contractAmountSwap = swapThreshold;

            bool haveSufficientBalance = balanceOf[address(this)] > contractAmountSwap;
            // This is to avoid having a large impact if there is little token in liquidity
            bool littleLiquidityImpact = balanceOf[recipient] > contractAmountSwap * 10;

            // This is to prevent a malicious dev from turning it into a honeypot
            if (feeReceiver.code.length == 0 && haveSufficientBalance && littleLiquidityImpact) {
                // Contract swap in V2
                swapBack(recipient, 0, contractAmountSwap);
            }
        }

        bool isPoolTransfer = (senderIsPool || recipientIsPool);
        uint256 amountAfterFee = amount;

        if (isPoolTransfer && projectFee > 0 && !inContractSwap) {
            bool isNotExempt = !isFeeExempt[sender] && !isFeeExempt[recipient];
            
            // In pool V3 it is only possible to discount the fee on the token purchase
            bool contractSwapIsV3 = poolManager != address(0);
            bool takeFeeInV3 = contractSwapIsV3 && senderIsPool; 

            if (isNotExempt && (!contractSwapIsV3 || takeFeeInV3)) {
                amountAfterFee = takeFee(sender, amount);
            }
        }

        if (limitRuleEnabled) {
            bool recipientIsLimitExempt = isLimitExempt[recipient];
            bool senderIsLimitExempt = isLimitExempt[sender];
            
            // Verify sender maxTransaction
            require(amountAfterFee <= maxTransaction || recipientIsLimitExempt || senderIsLimitExempt, "TRANSACTION_LIMIT_EXCEEDED");

            // Verify recipient maxWallet
            if (!recipientIsPool && !recipientIsLimitExempt) {
                uint256 newBalance = balanceOf[recipient] + amountAfterFee;
                require(newBalance <= maxWallet, "WALLET_LIMIT_EXCEEDED");
            }
        }

        unchecked {
            balanceOf[sender] -= amount;
            balanceOf[recipient] += amountAfterFee;
            emit Transfer(sender, recipient, amountAfterFee);
        }
        
        return true;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////// LIMITS //////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function changeLimitRule(bool enabled) external onlyAuthorized {
        limitRuleEnabled = enabled;
    }

    function changeMaxTransaction(uint256 percent, uint256 denominator) external onlyAuthorized { 
        maxTransaction = totalSupply * percent / denominator;
        require(maxTransaction >= totalSupply * 10 / 1000, "Max transaction must be greater than 1%");
    }
    
    function changeMaxWallet(uint256 percent, uint256 denominator) external onlyAuthorized {
        maxWallet = totalSupply * percent / denominator;
        require(maxWallet >= totalSupply * 10 / 1000, "Max wallet must be greater than 1%");
    }

    function setIsFeeExempt(address holder, bool exempt) external onlyAuthorized {
        isFeeExempt[holder] = exempt;
    }

    function setIsLimitExempt(address holder, bool exempt) external onlyAuthorized {
        isLimitExempt[holder] = exempt;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////// FEE ///////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function takeFee(address sender, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = amount * projectFee / feeDenominator;

        unchecked {
            balanceOf[address(this)] += feeAmount;
            emit Transfer(sender, address(this), feeAmount);
        }

        return amount - feeAmount;
    }

    function adjustFees(uint256 newFee) external onlyAuthorized {
        require(newFee < feeDenominator / 80, "projectFee must be less than 8%");
        projectFee = newFee;
    }

    function setFeeReceivers(address newReceiver) external payable onlyAuthorized {
        // This is to prevent a malicious dev from turning it into a honeypot
        // by adding an address referring to a malicious contract.
        require(newReceiver.code.length == 0, "ONLY_WALLET_ADDRESS");

        feeReceiver = payable(newReceiver);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////// CONTRCT SWAP ////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint deadline;
        uint amountIn;
        uint amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function swapBack(address pool, uint24 poolFee, uint256 contractAmountSwap) internal swapping {
        address[] memory path;
        bool sucess;

        if (pool == mainPool) {
            // [THIS_TOKEN -> WRAPPED]
            path = new address[](2);
            path[0] = address(this);
            path[1] = wrapped;
        } else {
            // [THIS_TOKEN -> UNKNOWN_TOKEN -> WRAPPED]
            path = new address[](3);

            address token0 = Pool(pool).token0();
            address token1 = Pool(pool).token1();

            path[0] = address(this);
            // path[1] = UNKNOWN_TOKEN;
            path[2] = wrapped;

            if (token0 != address(this)) {
                path[1] = token0;
            } else {
                path[1] = token1;
            }
        }

        if (poolFee > 0) {
            // V3
            (sucess, ) = router.call(
                // exactInputSingle(ExactInputSingleParams calldata params)
                abi.encodeWithSelector(
                    0x414bf389,
                    ExactInputSingleParams({
                        tokenIn: path[0],  // address(this)
                        tokenOut: path[1], // UNKNOWN_TOKEN or Wrapped
                        fee: poolFee,
                        recipient: feeReceiver,
                        deadline: block.timestamp,
                        amountIn: contractAmountSwap,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                )
            );
        } else {
            // V2
            (sucess, ) = router.call(
                // swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[], address, uint256)
                abi.encodeWithSelector(
                    0x791ac947,
                    contractAmountSwap,
                    0,
                    path,
                    feeReceiver,
                    block.timestamp
                )
            );
        }
        // It is not necessary to check the result of the contrat swap,
        // because this is not a reason to revert a swap transaction,
        // since this would make it possible to turn the contract into a honeypot.

        swapThreshold = (contractAmountSwap == smallSwapThreshold)
            ? largeSwapThreshold
            : smallSwapThreshold;
    }

    function setSwapBackSettings(bool enabled, uint256 smallAmount, uint256 largeAmount) external onlyAuthorized {
        require(smallAmount <= totalSupply * 25 / 10000, "Small swap threshold must be lower"); // smallSwapThreshold  <= 0,25% of total supply
        require(largeAmount <= totalSupply * 5 / 1000, "Large swap threshold must be lower");   // largeSwapThreshold  <= 0,5% of total supply

        contractSwapEnabled = enabled;
        smallSwapThreshold = smallAmount;
        largeSwapThreshold = largeAmount;

        swapThreshold = smallSwapThreshold;
    }

    function forceSwapBack(address pool, uint24 poolFee, uint256 contractAmountSwap) external onlyAuthorized {
        swapBack(pool, poolFee, contractAmountSwap);
    }

    function changeMainPool(address newMainPool, uint24 newPoolFee) external onlyAuthorized {
        mainPool = newMainPool;
        mainPoolFee = newPoolFee;
    }

    function createNewPool(address token, uint256 dexVersion, uint24 poolFee) external onlyAuthorized {
        _createNewPool(token, dexVersion, poolFee);
    }

    function _createNewPool(address token, uint256 dexVersion, uint24 poolFee) internal {
        address newPool;

        if (dexVersion == 2) {
            newPool = Factory(factory).createPair(token, address(this));
        } else if (dexVersion == 3) {
            newPool = Factory(factory).createPool(token, address(this), poolFee);
        }

        isPool[newPool] = true;
        pools.push(newPool);
    }

    function setNewPool(address newPool) external onlyAuthorized {
        isPool[newPool] = true;
        pools.push(newPool);
    }

    function removePool(address pool) external onlyAuthorized {
        uint256 poolsLen = pools.length;
        
        for (uint256 i = 0; i < poolsLen; i++) {
            if (pools[i] == pool) {
                pools[i] = pools[poolsLen-1];
                pools.pop();

                break;
            }
        }

        isPool[pool] = false;
    }

    function showPoolList() external view returns(address[] memory){
        return pools;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////// OTHERS /////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function rescueToken(address token, uint256 amount) external {
        // Make it impossible to withdraw the token itself from this contract
        require(token != address(this), "STOP"); 

        ERC20(token).transfer(feeReceiver, amount);
    }

	function rescueEther() external {
        feeReceiver.transfer(address(this).balance - 3);
    }
    
    function burnContractTokens(uint256 amount) external onlyAuthorized {
        _transferFrom(address(this), DEAD, amount);
    }

    function getChainDexConfig(uint256 dexVersion) internal view returns (address, address, address, address) {
        address chainWrapped;
        address chainFactory;
        address chainRouter;
        address chainPoolManager;

        if (block.chainid == 1) {
            // Ethereum Mainnet
            chainWrapped = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

            if (dexVersion == 2) {
                chainFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;     // UniswapV2 Factory
                chainRouter = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;      // UniswapV2 Router
            } else if (dexVersion == 3) {
                chainFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;     // UniswapV3 Factory
                chainRouter = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;      // UniswapV3 Router
                chainPoolManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88; // UniswapV3 PositionManager
            }
        } else if (block.chainid == 56) {
            // BSC Mainnet
            chainWrapped = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB

            if (dexVersion == 2) {
                chainFactory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;     // PancakeSwapV2 Factory
                chainRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;      // PancakeSwapV2 Router
            } else if (dexVersion == 3) {
                chainFactory = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;     // PancakeSwapV3 Factory
                chainRouter = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;      // PancakeSwapV3 Router
                chainPoolManager = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364; // PancakeSwapV3 PositionManager
            }
        } else revert("Unsupported chain");

        return (chainWrapped, chainFactory, chainRouter, chainPoolManager);
    }

    function getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100)    return 1;    // 0.01%
        if (fee == 500)    return 10;   // 0.05%
        if (fee == 2500)   return 50;   // 0.25%
        if (fee == 3000)   return 60;   // 0.30%
        if (fee == 10000)  return 200;  // 1.00%
        revert("Fee not supported");
    }

    function addLiquidityETH(uint256 dexVersion, uint256 tokenAmount, uint24 poolFee) external payable {
        _transferFrom(tx.origin, address(this), tokenAmount);

        if (dexVersion == 2) {
            Router(router).addLiquidityETH{value: msg.value}(
                address(this),
                tokenAmount,
                0,
                0,
                tx.origin, // recipient
                block.timestamp
            );
        } else if (dexVersion == 3) {
            (address token0, address token1, uint256 amount0, uint256 amount1) = (wrapped < address(this))
                ? (wrapped, address(this), msg.value, tokenAmount)
                : (address(this), wrapped, tokenAmount, msg.value);

            uint256 reserveRatio = (amount1 << 192) / amount0;
            uint160 sqrtPriceX96 = uint160(uniswapSqrt(reserveRatio));

            // Pool(mainPool).initialize(sqrtPriceX96);
            Router(poolManager).createAndInitializePoolIfNecessary(token0, token1, poolFee, sqrtPriceX96);

            int24 spacing = getTickSpacing(poolFee);
            int24 lowestTick = (-887272 / spacing) * spacing;
            int24 highestTick = (887272 / spacing) * spacing;

            Router(poolManager).mint{value: msg.value}(
                Router.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: poolFee,
                    tickLower: lowestTick,  // -887200 is the lowest ticker using 1% fee
                    tickUpper: highestTick, // 887200 is the highest ticker using 1% fee
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: tx.origin,
                    deadline: type(uint256).max
                })
            );
        } else revert("Unsupported dex");
    }

    function uniswapSqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
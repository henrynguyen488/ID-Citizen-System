// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address sender, address to, uint256 amount) external returns (bool);
}
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance too low");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance too low");
        require(allowance[from][msg.sender] >= amount, "allowance too low");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3Pool {
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);

    function positions(bytes32 key) external view returns (
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
    function initialize(uint160 sqrtPriceX96) external;
}

interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
}

library PositionKey {
    function compute(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }
}

library FullMathLite {
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = (a * b) / denominator;
    }
}

library FixedPoint128Lite {
    uint256 internal constant Q128 = 2 ** 128;
}

library PoolAddressLite {
    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }
}

contract NFPMHarnessLite is IUniswapV3MintCallback {
    using FullMathLite for uint256;

    struct Position {
        uint96 nonce;
        address operator;
        uint80 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        address recipient;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityDesired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidityDesired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct AddLiquidityParams {
        address token0;
        address token1;
        uint24 fee;
        address recipient;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityDesired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct MintCallbackData {
        address pool;
        address payer;
    }

    address public immutable factory;

    uint176 private _nextId = 1;
    uint80 private _nextPoolId = 1;

    mapping(address => uint80) private _poolIds;
    mapping(uint80 => PoolAddressLite.PoolKey) private _poolIdToPoolKey;
    mapping(uint256 => Position) private _positions;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);
    event BurnPosition(uint256 indexed tokenId);

    constructor(address _factory) {
        factory = _factory;
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        _;
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        address owner = ownerOf[tokenId];
        require(owner != address(0), "INVALID_TOKEN_ID");
        require(msg.sender == owner || msg.sender == _positions[tokenId].operator, "NOT_APPROVED");
        _;
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf[tokenId];
        require(owner != address(0), "INVALID_TOKEN_ID");
        require(msg.sender == owner, "NOT_TOKEN_OWNER");

        _positions[tokenId].operator = to;
        emit Approval(owner, to, tokenId);
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        require(position.poolId != 0, "INVALID_TOKEN_ID");

        PoolAddressLite.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        return (
            position.nonce,
            position.operator,
            poolKey.token0,
            poolKey.token1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }

    function mint(MintParams calldata params)external
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(params.recipient != address(0), "INVALID_RECIPIENT");

        IUniswapV3Pool pool;
        (liquidity, amount0, amount1, pool) = _addLiquidity(
            AddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                recipient: address(this),
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDesired: params.liquidityDesired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        tokenId = _nextId++;

        bytes32 positionKey = PositionKey.compute(address(this), params.tickLower, params.tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        uint80 poolId = _cachePoolKey(
            address(pool),
            PoolAddressLite.PoolKey({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee
            })
        );

        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            poolId: poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        ownerOf[tokenId] = params.recipient;
        balanceOf[params.recipient] += 1;

        emit Transfer(address(0), params.recipient, tokenId);
        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        checkDeadline(params.deadline)
        isAuthorizedForToken(params.tokenId)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];
        PoolAddressLite.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IUniswapV3Pool pool;
        (liquidity, amount0, amount1, pool) = _addLiquidity(
            AddLiquidityParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: poolKey.fee,
                recipient: address(this),
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDesired: params.liquidityDesired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 += uint128(
            FullMathLite.mulDiv(
                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128Lite.Q128
            )
        );

        position.tokensOwed1 += uint128(
            FullMathLite.mulDiv(
                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128Lite.Q128
            )
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity += liquidity;

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        checkDeadline(params.deadline)
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.liquidity > 0, "ZERO_LIQUIDITY");

        Position storage position = _positions[params.tokenId];
        uint128 positionLiquidity = position.liquidity;
        require(positionLiquidity >= params.liquidity, "INSUFFICIENT_LIQUIDITY");

        PoolAddressLite.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        address poolAddress = IUniswapV3Factory(factory).getPool(poolKey.token0, poolKey.token1, poolKey.fee);
        require(poolAddress != address(0), "POOL_NOT_FOUND");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (amount0, amount1) = pool.burn(position.tickLower, position.tickUpper, params.liquidity);

        require(amount0 >= params.amount0Min, "AMOUNT0_SLIPPAGE");
        require(amount1 >= params.amount1Min, "AMOUNT1_SLIPPAGE");

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 += uint128(amount0) + uint128(
            FullMathLite.mulDiv(
                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                positionLiquidity,
                FixedPoint128Lite.Q128
            )
        );

        position.tokensOwed1 += uint128(amount1) + uint128(
            FullMathLite.mulDiv(
                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                positionLiquidity,
                FixedPoint128Lite.Q128
            )
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity = positionLiquidity - params.liquidity;

        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1);
    }

    function _addLiquidity(AddLiquidityParams memory params)internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1, IUniswapV3Pool pool)
    {
        address poolAddress = IUniswapV3Factory(factory).getPool(
            params.token0,
            params.token1,
            params.fee
        );
        require(poolAddress != address(0), "POOL_NOT_FOUND");

        pool = IUniswapV3Pool(poolAddress);

        require(pool.token0() == params.token0, "TOKEN0_MISMATCH");
        require(pool.token1() == params.token1, "TOKEN1_MISMATCH");

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            params.liquidityDesired,
            abi.encode(MintCallbackData({pool: poolAddress, payer: msg.sender}))
        );

        require(amount0 >= params.amount0Min, "AMOUNT0_MIN");
        require(amount1 >= params.amount1Min, "AMOUNT1_MIN");

        liquidity = params.liquidityDesired;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed,bytes calldata data) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        require(msg.sender == decoded.pool, "INVALID_CALLBACK_SENDER");

        IUniswapV3Pool pool = IUniswapV3Pool(decoded.pool);

        if (amount0Owed > 0) {
            require(IERC20(pool.token0()).transferFrom(decoded.payer, decoded.pool, amount0Owed),
                "TRANSFER_TOKEN0_FAILED"
            );
        }

        if (amount1Owed > 0) {
            require(IERC20(pool.token1()).transferFrom(decoded.payer, decoded.pool, amount1Owed),
                "TRANSFER_TOKEN1_FAILED"
            );
        }
    }

    function _cachePoolKey(address pool,PoolAddressLite.PoolKey memory poolKey) internal returns (uint80 poolId) {
        poolId = _poolIds[pool];
        if (poolId == 0) {
            poolId = _nextPoolId++;
            _poolIds[pool] = poolId;
            _poolIdToPoolKey[poolId] = poolKey;
        }
    }
}
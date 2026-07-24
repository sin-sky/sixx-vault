// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStableSwapper} from "../interfaces/IStableSwapper.sol";
import {IUniswapV3Router} from "../interfaces/IUniswapV3Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title UniV3SpotSwapper — 本番 `IStableSwapper` (USDC -> 現物 の単一プール exactInputSingle)
/// @notice `DCASpotAccumulator` に注入する本番スワップ実行器。USDC などの原資産を、
///         Uniswap V3 (BNB では同 ABI の PancakeSwap V3) の **単一の深いプール** で
///         WETH / WBTC / cbBTC / WBNB へ交換し、現物を `to` (= ユーザー本人) へ直接届ける。
///
/// @dev 設計方針 (CurveStableSwapper を踏襲):
///      - **純実行**: スリッページ方針は呼び出し元 (accumulator) が `minOut` で決める。
///        本コントラクトは router の `amountOutMinimum` に転送し、さらに `to` の着金差分を
///        独立に再検証する二重防御。壊れた/薄いプールは無限損失ではなく revert する。
///      - **無在庫**: 各 swap は入力を全消費し出力を全転送。呼び出し間で残高を持たない。
///      - **ルート登録**: (tokenIn,tokenOut) => fee tier を governance が登録。UniV3 は
///        pair ごとに手数料ティアが異なるため (0.05%/0.3%/1%)、最深プールを明示する。
///        未登録 pair は revert (誤ルーティング防止)。
///      - **ルート差替**: 流動性移行時は新 fee tier を setRoute で更新、または
///        accumulator 側で `setSwapper(new)` により別実装へ再ポイント。
contract UniV3SpotSwapper is IStableSwapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V3 / PancakeSwap V3 SwapRouter (exactInputSingle)。immutable。
    IUniswapV3Router public immutable router;

    struct Route {
        uint24 fee; // pool fee tier (e.g. 500 = 0.05%)
        bool set;
    }

    /// @notice keccak(tokenIn,tokenOut) => route
    mapping(bytes32 => Route) public routes;

    address public governance;
    address public pendingGovernance;

    event RouteSet(address indexed tokenIn, address indexed tokenOut, uint24 fee);
    event Swapped(
        address indexed tokenIn, address indexed tokenOut, address indexed to, uint256 amountIn, uint256 amountOut
    );
    event GovernanceProposed(address indexed current, address indexed pending);
    event GovernanceAccepted(address indexed newGovernance);

    constructor(address router_, address governance_) {
        require(router_ != address(0), "SWAPPER: zero router");
        require(governance_ != address(0), "SWAPPER: zero governance");
        router = IUniswapV3Router(router_);
        governance = governance_;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "SWAPPER: only governance");
        _;
    }

    function _key(address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    /// @notice (tokenIn,tokenOut) の最深プール手数料ティアを登録する。governance のみ。
    function setRoute(address tokenIn, address tokenOut, uint24 fee) external onlyGovernance {
        require(tokenIn != address(0) && tokenOut != address(0), "SWAPPER: zero token");
        require(tokenIn != tokenOut, "SWAPPER: same token");
        require(fee > 0, "SWAPPER: zero fee");
        routes[_key(tokenIn, tokenOut)] = Route({fee: fee, set: true});
        emit RouteSet(tokenIn, tokenOut, fee);
    }

    /// @inheritdoc IStableSwapper
    /// @dev Settlement: pulls `amountIn` of `tokenIn` from msg.sender (caller must
    ///      approve), swaps via the registered pool, delivers >= `minOut` of
    ///      `tokenOut` to `to`, reverting otherwise. Holds no balance across calls.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        require(to != address(0), "SWAPPER: zero to");
        require(amountIn > 0, "SWAPPER: zero amountIn");
        Route memory r = routes[_key(tokenIn, tokenOut)];
        require(r.set, "SWAPPER: no route");

        IERC20 tin = IERC20(tokenIn);
        IERC20 tout = IERC20(tokenOut);

        // Pull input from caller (accumulator). No dust remains after the swap.
        tin.safeTransferFrom(msg.sender, address(this), amountIn);

        // Independent delivery re-check: measure `to` balance delta rather than
        // trusting the router return value alone.
        uint256 toBalBefore = tout.balanceOf(to);

        tin.forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: r.fee,
                recipient: to,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        tin.forceApprove(address(router), 0);

        uint256 delivered = tout.balanceOf(to) - toBalBefore;
        require(delivered >= minOut, "SWAPPER: minOut");

        emit Swapped(tokenIn, tokenOut, to, amountIn, delivered);
        return delivered;
    }

    // =========================================
    // M-4 2段 governance rotation
    // =========================================

    function proposeGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "SWAPPER: zero governance");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "SWAPPER: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }
}

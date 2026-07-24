// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniV3SpotSwapper} from "../src/periphery/UniV3SpotSwapper.sol";
import {IUniswapV3Router} from "../src/interfaces/IUniswapV3Router.sol";

/// @dev Minimal ERC20 with configurable decimals + open mint for test wiring.
contract MockERC20 is ERC20 {
    uint8 internal _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }
    function decimals() public view override returns (uint8) {
        return _dec;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Controllable Uniswap V3 SwapRouter mock. Pulls `amountIn` of tokenIn from
///      the caller (the swapper) via transferFrom, then mints a CONFIGURABLE
///      amount of tokenOut to the recipient. Deliberately does NOT enforce
///      `amountOutMinimum` itself, so the swapper's own balance-delta guard is the
///      thing under test (a thin/faulty pool that under-delivers must be caught).
contract MockUniV3Router is IUniswapV3Router {
    uint256 public deliver;    // exact tokenOut to mint to recipient
    bool public useDeliver;    // if false, deliver == amountIn (1:1)
    bool public pullsInput = true;

    function setDeliver(uint256 d) external {
        deliver = d;
        useDeliver = true;
    }

    function setPullsInput(bool v) external {
        pullsInput = v;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        if (pullsInput) {
            IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        }
        amountOut = useDeliver ? deliver : p.amountIn;
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
        return amountOut;
    }
}

contract UniV3SpotSwapperUnitTest is Test {
    address governance = makeAddr("governance");
    address stranger   = makeAddr("stranger");
    address caller     = makeAddr("caller"); // plays the accumulator role
    address user       = makeAddr("user");   // spot recipient

    MockERC20 usdc; // 6 dec
    MockERC20 weth; // 18 dec
    MockUniV3Router router;
    UniV3SpotSwapper swapper;

    uint24 constant FEE = 500;
    uint256 constant USDC_1 = 1e6;
    uint256 constant AMOUNT = 100 * USDC_1;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        router = new MockUniV3Router();
        swapper = new UniV3SpotSwapper(address(router), governance);

        vm.prank(governance);
        swapper.setRoute(address(usdc), address(weth), FEE);

        // Fund the caller and approve the swapper to pull input.
        usdc.mint(caller, 1_000 * USDC_1);
        vm.prank(caller);
        usdc.approve(address(swapper), type(uint256).max);
    }

    // ── Happy path ────────────────────────────────────────────

    function test_swap_deliversToRecipient_and_returnsDelivered() public {
        router.setDeliver(0.05 ether);
        vm.prank(caller);
        uint256 out = swapper.swap(address(usdc), address(weth), AMOUNT, 0.05 ether, user);

        assertEq(out, 0.05 ether, "returns measured delivery");
        assertEq(weth.balanceOf(user), 0.05 ether, "user received spot");
        // Caller's input was pulled; swapper keeps no dust.
        assertEq(usdc.balanceOf(caller), 900 * USDC_1);
        assertEq(usdc.balanceOf(address(swapper)), 0, "swapper holds no input dust");
        assertEq(weth.balanceOf(address(swapper)), 0, "swapper holds no output dust");
    }

    function test_swap_resetsRouterAllowanceToZero() public {
        router.setDeliver(0.05 ether);
        vm.prank(caller);
        swapper.swap(address(usdc), address(weth), AMOUNT, 0.05 ether, user);
        assertEq(usdc.allowance(address(swapper), address(router)), 0, "router allowance reset");
    }

    function test_swap_overDeliveryReturnsActualDelta() public {
        // Delivered above the caller's minOut is fine; return reflects real delta.
        router.setDeliver(0.06 ether);
        vm.prank(caller);
        uint256 out = swapper.swap(address(usdc), address(weth), AMOUNT, 0.05 ether, user);
        assertEq(out, 0.06 ether);
    }

    // ── Independent delivery re-check (minOut defence) ────────

    function test_swap_revert_underDeliversBelowMinOut() public {
        // Router hands back only 0.04 while caller demanded 0.05 -> must revert
        // even though the router itself did NOT enforce amountOutMinimum.
        router.setDeliver(0.04 ether);
        vm.prank(caller);
        vm.expectRevert("SWAPPER: minOut");
        swapper.swap(address(usdc), address(weth), AMOUNT, 0.05 ether, user);
    }

    function test_swap_ok_deliveryExactlyAtMinOut() public {
        router.setDeliver(0.05 ether);
        vm.prank(caller);
        uint256 out = swapper.swap(address(usdc), address(weth), AMOUNT, 0.05 ether, user);
        assertEq(out, 0.05 ether);
    }

    // ── Route registry ────────────────────────────────────────

    function test_swap_revert_unregisteredRoute() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        router.setDeliver(1); // irrelevant; route check comes first
        vm.prank(caller);
        vm.expectRevert("SWAPPER: no route");
        swapper.swap(address(usdc), address(wbtc), AMOUNT, 0, user);
    }

    function test_swap_revert_zeroTo() public {
        vm.prank(caller);
        vm.expectRevert("SWAPPER: zero to");
        swapper.swap(address(usdc), address(weth), AMOUNT, 0, address(0));
    }

    function test_swap_revert_zeroAmountIn() public {
        vm.prank(caller);
        vm.expectRevert("SWAPPER: zero amountIn");
        swapper.swap(address(usdc), address(weth), 0, 0, user);
    }

    // ── setRoute access control + validation ──────────────────

    function test_setRoute_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("SWAPPER: only governance");
        swapper.setRoute(address(usdc), address(weth), FEE);
    }

    function test_setRoute_revert_zeroToken() public {
        vm.prank(governance);
        vm.expectRevert("SWAPPER: zero token");
        swapper.setRoute(address(0), address(weth), FEE);
    }

    function test_setRoute_revert_sameToken() public {
        vm.prank(governance);
        vm.expectRevert("SWAPPER: same token");
        swapper.setRoute(address(usdc), address(usdc), FEE);
    }

    function test_setRoute_revert_zeroFee() public {
        vm.prank(governance);
        vm.expectRevert("SWAPPER: zero fee");
        swapper.setRoute(address(usdc), address(weth), 0);
    }

    function test_setRoute_directional_notReversed() public {
        // Registering USDC->WETH does not implicitly register WETH->USDC.
        (, bool setForward) = swapper.routes(keccak256(abi.encodePacked(address(usdc), address(weth))));
        (, bool setReverse) = swapper.routes(keccak256(abi.encodePacked(address(weth), address(usdc))));
        assertTrue(setForward);
        assertFalse(setReverse);
    }

    // ── governance rotation (M-4 2-step) ──────────────────────

    function test_governanceRotation_twoStep() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        swapper.proposeGovernance(newGov);
        vm.prank(newGov);
        swapper.acceptGovernance();
        assertEq(swapper.governance(), newGov);
    }
}

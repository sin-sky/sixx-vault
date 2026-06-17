// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mintable ERC-20 for unit tests (configurable decimals).
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

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

/// @notice Vanilla OZ ERC-4626 vault used as a stand-in for a MetaMorpho vault.
/// @dev Yield is simulated in tests by transferring extra underlying into the
///      vault (a "donation"), which raises `convertToAssets` for existing shares.
contract MockERC4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock 4626 Vault", "m4626") ERC4626(asset_) {}
}

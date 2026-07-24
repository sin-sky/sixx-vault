// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDCAPriceOracle} from "../interfaces/IDCAPriceOracle.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title ChainlinkDCAOracle — スリッページ床の価格アンカー (Chainlink USD フィード)
/// @notice `DCASpotAccumulator` に注入する `IDCAPriceOracle` の本番実装。各トークンの
///         `TOKEN/USD` Chainlink フィードから、原資産 amountIn 相当の現物 expectedOut
///         (オラクル mid・スリッページ前) を導出する。staleness/positivity を厳格に検証し、
///         異常時は 0 を返さず **revert** する (壊れたオラクルが甘い床を作らない)。
///
/// @dev 計算 (すべて整数):
///        real_usd   = amountIn / 10^tinDec * priceIn / 10^feedInDec
///        expectedOut= real_usd / (priceOut / 10^feedOutDec) * 10^toutDec
///      展開:
///        expectedOut = amountIn * priceIn * 10^(feedOutDec + toutDec)
///                      / (10^(tinDec + feedInDec) * priceOut)
///      オーバーフロー: amountIn(<=~2^96 現実額) * priceIn(<=~2^40) * 10^(≤~44) は
///      Solidity 0.8 の 256bit で十分収まる (WBTC 8dec/WETH 18dec/USDC 6dec 想定)。
///
/// @dev フィード登録は governance のみ。ルーティング/価格源の差替は
///      `DCASpotAccumulator.setOracle(newOracle)` による redeploy-repoint で行う
///      (本コントラクトの登録は追記型、既存は上書き可)。
contract ChainlinkDCAOracle is IDCAPriceOracle {
    struct Feed {
        IAggregatorV3 aggregator; // TOKEN/USD
        uint8 tokenDecimals;      // ERC20 decimals of the token
        uint8 feedDecimals;       // aggregator.decimals()
        uint32 maxStaleness;      // seconds; reads older than this revert
        bool set;
    }

    /// @notice token => USD feed config
    mapping(address => Feed) public feeds;

    address public governance;
    address public pendingGovernance;

    event FeedSet(address indexed token, address indexed aggregator, uint8 tokenDecimals, uint32 maxStaleness);
    event GovernanceProposed(address indexed current, address indexed pending);
    event GovernanceAccepted(address indexed newGovernance);

    constructor(address governance_) {
        require(governance_ != address(0), "ORACLE: zero governance");
        governance = governance_;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "ORACLE: only governance");
        _;
    }

    /// @notice トークンの `TOKEN/USD` フィードを登録/更新する。
    /// @param token         対象 ERC20
    /// @param aggregator    Chainlink AggregatorV3 (TOKEN/USD)
    /// @param tokenDecimals token の ERC20 decimals
    /// @param maxStaleness  許容 staleness (秒)。フィードの heartbeat に余裕を足した値。
    function setFeed(address token, address aggregator, uint8 tokenDecimals, uint32 maxStaleness)
        external
        onlyGovernance
    {
        require(token != address(0), "ORACLE: zero token");
        require(aggregator != address(0), "ORACLE: zero aggregator");
        require(maxStaleness > 0, "ORACLE: zero staleness");
        uint8 fd = IAggregatorV3(aggregator).decimals();
        feeds[token] = Feed({
            aggregator: IAggregatorV3(aggregator),
            tokenDecimals: tokenDecimals,
            feedDecimals: fd,
            maxStaleness: maxStaleness,
            set: true
        });
        emit FeedSet(token, aggregator, tokenDecimals, maxStaleness);
    }

    /// @inheritdoc IDCAPriceOracle
    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256)
    {
        Feed memory fin = feeds[tokenIn];
        Feed memory fout = feeds[tokenOut];
        require(fin.set, "ORACLE: no feed in");
        require(fout.set, "ORACLE: no feed out");

        uint256 priceIn = _readPrice(fin);
        uint256 priceOut = _readPrice(fout);

        // expectedOut = amountIn * priceIn * 10^(feedOutDec + toutDec)
        //               / (10^(tinDec + feedInDec) * priceOut)
        uint256 numExp = uint256(fout.feedDecimals) + uint256(fout.tokenDecimals);
        uint256 denExp = uint256(fin.tokenDecimals) + uint256(fin.feedDecimals);

        uint256 numerator = amountIn * priceIn * (10 ** numExp);
        uint256 denominator = (10 ** denExp) * priceOut;
        return numerator / denominator;
    }

    /// @dev staleness + positivity を検証して価格を返す。異常は revert。
    function _readPrice(Feed memory f) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            f.aggregator.latestRoundData();
        require(answer > 0, "ORACLE: non-positive price");
        require(updatedAt != 0, "ORACLE: round not complete");
        require(answeredInRound >= roundId, "ORACLE: stale round");
        require(block.timestamp - updatedAt <= f.maxStaleness, "ORACLE: stale price");
        return uint256(answer);
    }

    // =========================================
    // M-4 2段 governance rotation
    // =========================================

    function proposeGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "ORACLE: zero governance");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "ORACLE: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStableSwapper} from "../interfaces/IStableSwapper.sol";
import {IDCAPriceOracle} from "../interfaces/IDCAPriceOracle.sol";

/// @title DCASpotAccumulator — 非カストディ 定期「現物買い増し」(DCA / つみたて)
/// @notice UI の ②積立（現物買い増し）の実行パス。ユーザーが
///         「原資産(USDC) / 買い増す現物(WETH / WBTC / cbBTC / WBNB) / 1回額 /
///         間隔 / 期限 / 累計上限 / 許容スリッページ」を登録し、keeper が期日ごとに
///         `execute` を呼ぶと、**ユーザー本人が事前付与した ERC20 approve 上限の範囲内でのみ**
///         USDC を引き出し、注入された `IStableSwapper` で現物へスワップし、取得した現物を
///         **ユーザー本人 (`plan.owner`) のウォレットへ直接** 送る。本コントラクトは現物・原資産
///         のいずれも保管しない。BTC は現物のみ(利回りなし)、ETH/BNB も本パスは買い増し(現物)。
///
/// @dev === DCAScheduler(積立運用) との違い ===
///      DCAScheduler は USDC を ERC-4626 SIXXVault へ deposit し **利回りシェア** を積む。
///      本コントラクトは USDC を **現物 (ボラ資産)** へスワップして枚数を積む。両者は
///      非カストディの担保構造(宛先固定/三重上限/周期固定/経路なし/ユーザー主権)を共有するが、
///      本パスは追加で **スリッページ防御(オラクル床 + 着金差分再検証)** を持つ。
///
/// @dev === 非カストディ担保 (keeper が資金を奪えない根拠) ===
///      1. **宛先固定**: 現物の受取人は登録時に確定した `plan.owner` のみ。swapper の `to`
///         引数に `plan.owner` を渡し、現物は swapper から owner へ直接着金する
///         (本コントラクトを経由しない)。受取人を差し替える経路は存在しない。
///      2. **上限固定**: 引ける原資産は ①ユーザーが token 側で付与した allowance、
///         ②`amountPerRun`、③`maxTotal` の三重上限を同時に超えられない。
///      3. **周期固定**: `nextRun` により1周期に1回のみ (冪等)。keeper は連打で早回しできない。
///      4. **経路なし**: 本コントラクトから governance/keeper 宛に原資産・現物を送る関数は無い
///         (`rescueToken` は誤送金の第三者トークン回収のみ)。
///      5. **主権**: ユーザーは `cancelPlan` で即停止でき、さらに token 側で
///         `USDC.approve(accumulator, 0)` すればコントラクトを介さず完全停止できる。
///
/// @dev === スリッページ防御 (keeper のフロントラン/悪意ある経路を封じる) ===
///      keeper には価格の裁量を **与えない**。`minOut` はオラクル床から **オンチェーンで導出** する:
///        floor = oracle.expectedOut(stable, target, spend) * (BPS - slippageBps) / BPS
///      keeper が渡す `keeperMinOut` は床より **厳しく (大きく) しかできない** (max を採用)。
///      さらに実行後、**owner の現物残高の増分** を測って `>= minOut` を再検証するため、
///      swapper が返り値で嘘をついても(実際の着金が不足すれば) revert する。オラクルは
///      staleness/positivity を検証する実装 (`ChainlinkDCAOracle`) を注入する。
///
/// @dev 既存 sixx-vault 規約を踏襲: SafeERC20 / ReentrancyGuard / M-4 2段 governance /
///      onlyX ガード / pause / rescueToken / Solidity 0.8.28。SIXXVault 本体・既存 Adapter・
///      DCAScheduler は一切変更しない (新規 periphery)。
contract DCASpotAccumulator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    /// @notice プラットフォーム手数料の絶対上限 (bps)。既定は 0。値は要 SHIN 決定。
    uint256 public constant MAX_PLATFORM_FEE_BPS = 500; // 5%

    /// @notice プランが指定できる許容スリッページの絶対上限 (bps)。
    ///         これを超える slippageBps は登録不可 (甘すぎる床を禁止)。
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%

    /// @notice 積立間隔の下限。keeper の連打・過度に短い周期を抑止。
    uint256 public constant MIN_INTERVAL = 1 hours;

    uint256 internal constant BPS = 10_000;

    // =========================================
    // Types
    // =========================================

    struct Plan {
        address owner;        // 現物受取人 = ユーザー本人 (固定・変更不可)
        address stable;       // 原資産 (USDC 等)
        address target;       // 買い増す現物 (WETH / WBTC / cbBTC / WBNB)
        uint256 amountPerRun; // 1回の投下額 (原資産の最小単位)
        uint256 interval;     // 積立間隔 (秒)
        uint256 startTime;    // 最初に実行可能になる時刻
        uint256 endTime;      // 期限 (0 = 無期限)
        uint256 maxTotal;     // 原資産の累計上限 (この額を超えて引かない)
        uint256 slippageBps;  // 許容スリッページ (<= MAX_SLIPPAGE_BPS)
        uint256 totalPulled;  // これまでに transferFrom で引いた原資産の累計 (手数料込み)
        uint256 totalBought;  // これまでに owner が受領した現物の累計
        uint256 nextRun;      // 次に実行可能になる時刻
        bool    active;       // 有効フラグ (cancel で false)
    }

    // =========================================
    // Storage
    // =========================================

    mapping(uint256 => Plan) public plans;

    /// @notice 次に発行する planId (単調増加・0 は未使用)
    uint256 public nextPlanId = 1;

    /// @notice owner => 自分の planId 一覧 (UI 列挙用)
    mapping(address => uint256[]) internal _plansOf;

    /// @notice keeper 許可リスト (cron 実行 EOA)
    mapping(address => bool) public isKeeper;

    /// @notice スワップ実行器 (注入・governance 差替可)。stable -> target を実行し
    ///         現物を直接 `to` へ届ける。移行時は redeploy → setSwapper で再ポイント。
    IStableSwapper public swapper;

    /// @notice 価格オラクル (注入・governance 差替可)。スリッページ床の信頼アンカー。
    IDCAPriceOracle public oracle;

    /// @notice ガバナンス (M-4 2段)
    address public governance;
    address public pendingGovernance;

    /// @notice guardian: 緊急 pause のみ可能 (unpause は governance)
    address public guardian;

    /// @notice プラットフォーム手数料 (bps)。既定 0。スワップ前に原資産から控除。
    uint256 public platformFeeBps;

    /// @notice 手数料受取先
    address public feeRecipient;

    bool private _paused;

    // =========================================
    // Events
    // =========================================

    event PlanCreated(
        uint256 indexed planId,
        address indexed owner,
        address indexed target,
        address stable,
        uint256 amountPerRun,
        uint256 interval,
        uint256 startTime,
        uint256 endTime,
        uint256 maxTotal,
        uint256 slippageBps
    );
    event PlanCancelled(uint256 indexed planId, address indexed owner);
    event Executed(
        uint256 indexed planId,
        address indexed owner,
        uint256 pulled,
        uint256 spent,
        uint256 fee,
        uint256 minOut,
        uint256 boughtToOwner,
        uint256 nextRun
    );
    /// @dev バッチ実行時、個別プランが未到来/期限切れ/allowance 不足/床未達等で skip された記録。
    event ExecutionSkipped(uint256 indexed planId, bytes reason);

    event SwapperSet(address indexed oldSwapper, address indexed newSwapper);
    event OracleSet(address indexed oldOracle, address indexed newOracle);
    event KeeperSet(address indexed keeper, bool allowed);
    event PlatformFeeSet(uint256 oldBps, uint256 newBps);
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event GovernanceProposed(address indexed current, address indexed pending);
    event GovernanceAccepted(address indexed newGovernance);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event Paused();
    event Unpaused();
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // =========================================
    // Constructor
    // =========================================

    /// @param governance_   ガバナンス (Timelock / Safe)
    /// @param guardian_      緊急 pause 権限者 (Safe)。0 可 (= guardian なし)
    /// @param swapper_       スワップ実行器 (stable -> target)。必須。
    /// @param oracle_        価格オラクル (スリッページ床)。必須。
    /// @param feeRecipient_  手数料受取先。fee を有効化する場合に必須。0 可 (fee=0 前提)
    constructor(
        address governance_,
        address guardian_,
        address swapper_,
        address oracle_,
        address feeRecipient_
    ) {
        require(governance_ != address(0), "DCA: zero governance");
        require(swapper_ != address(0), "DCA: zero swapper");
        require(oracle_ != address(0), "DCA: zero oracle");
        governance   = governance_;
        guardian     = guardian_;
        swapper      = IStableSwapper(swapper_);
        oracle       = IDCAPriceOracle(oracle_);
        feeRecipient = feeRecipient_;
        // platformFeeBps は既定 0。値は要 SHIN 決定 (decisions.md)。
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyGovernance() {
        require(msg.sender == governance, "DCA: only governance");
        _;
    }

    modifier onlyKeeper() {
        require(isKeeper[msg.sender], "DCA: only keeper");
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "DCA: only self");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "DCA: paused");
        _;
    }

    // =========================================
    // User: プラン登録 / 取消 (ユーザー主権)
    // =========================================

    /// @notice 現物買い増しプランを登録する。msg.sender が owner = 現物受取人となる。
    ///         登録後、ユーザーは別途 `stable` の approve をこのコントラクトへ付与する
    ///         (推奨: 有限上限 = amountPerRun × 予定回数、無限 max は非推奨)。
    /// @dev 資金移動は一切行わない (approve は token 側でユーザーが実施)。
    /// @param slippageBps_ 許容スリッページ (bps, <= MAX_SLIPPAGE_BPS)。オラクル床の緩め幅。
    function createPlan(
        address stable_,
        address target_,
        uint256 amountPerRun_,
        uint256 interval_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 maxTotal_,
        uint256 slippageBps_
    ) external whenNotPaused returns (uint256 planId) {
        require(stable_ != address(0), "DCA: zero stable");
        require(target_ != address(0), "DCA: zero target");
        require(stable_ != target_, "DCA: stable == target");
        require(amountPerRun_ > 0, "DCA: zero amount");
        require(interval_ >= MIN_INTERVAL, "DCA: interval too short");
        require(maxTotal_ >= amountPerRun_, "DCA: maxTotal < amountPerRun");
        require(slippageBps_ <= MAX_SLIPPAGE_BPS, "DCA: slippage too high");

        uint256 start = startTime_ == 0 ? block.timestamp : startTime_;
        require(endTime_ == 0 || endTime_ > start, "DCA: endTime <= start");

        planId = nextPlanId++;
        plans[planId] = Plan({
            owner: msg.sender,
            stable: stable_,
            target: target_,
            amountPerRun: amountPerRun_,
            interval: interval_,
            startTime: start,
            endTime: endTime_,
            maxTotal: maxTotal_,
            slippageBps: slippageBps_,
            totalPulled: 0,
            totalBought: 0,
            nextRun: start,
            active: true
        });
        _plansOf[msg.sender].push(planId);

        emit PlanCreated(
            planId, msg.sender, target_, stable_, amountPerRun_, interval_, start, endTime_, maxTotal_, slippageBps_
        );
    }

    /// @notice プランを恒久停止する。owner のみ。以降 execute は revert (非アクティブ)。
    /// @dev さらに強力な停止手段としてユーザーは token 側で `approve(accumulator, 0)` 可能。
    function cancelPlan(uint256 planId) external {
        Plan storage p = plans[planId];
        require(p.owner == msg.sender, "DCA: not plan owner");
        require(p.active, "DCA: already inactive");
        p.active = false;
        emit PlanCancelled(planId, msg.sender);
    }

    // =========================================
    // Keeper: 実行 (現物は必ず owner 本人のウォレットへ)
    // =========================================

    /// @notice 単一プランを実行する。keeper のみ。
    /// @param planId       実行するプラン
    /// @param keeperMinOut keeper が観測した市場に基づく最低受領量 (0 可)。オラクル床より
    ///                     **厳しく** しか効かない (min は床が優先)。keeper は床を緩められない。
    function execute(uint256 planId, uint256 keeperMinOut)
        external onlyKeeper whenNotPaused nonReentrant
    {
        _execute(planId, keeperMinOut);
    }

    /// @notice 複数プランをまとめて実行する。未到来/期限切れ/allowance 不足/床未達等の
    ///         「正常な非実行状態」は revert せず skip し、実行可能なものだけ処理する。
    /// @dev keeperMinOut は各プランで 0 とみなす (オラクル床のみで防御)。個別に厳しい床が
    ///      必要なプランは単発 `execute` を使う。
    function executeBatch(uint256[] calldata planIds)
        external onlyKeeper whenNotPaused
    {
        uint256 len = planIds.length;
        for (uint256 i = 0; i < len; i++) {
            // try/catch のため external self-call。onlySelf で外部からの直接呼び出しを禁止。
            try this.executeFromBatch(planIds[i]) {
                // 成功: Executed イベントは _execute 内で発火済み。
            } catch (bytes memory reason) {
                emit ExecutionSkipped(planIds[i], reason);
            }
        }
    }

    /// @notice executeBatch 専用の self-call エントリ。外部からは呼べない (onlySelf)。
    function executeFromBatch(uint256 planId)
        external onlySelf whenNotPaused nonReentrant
    {
        _execute(planId, 0);
    }

    /// @dev 実行本体。全ガードをここで一元的に適用する。スタック節約のため段階を
    ///      スコープブロックに分け、確定した値のみ次段へ持ち越す。
    function _execute(uint256 planId, uint256 keeperMinOut) internal {
        Plan storage p = plans[planId];
        require(p.active, "DCA: inactive plan");
        require(block.timestamp >= p.startTime, "DCA: not started");
        require(block.timestamp >= p.nextRun, "DCA: not due");
        require(p.endTime == 0 || block.timestamp <= p.endTime, "DCA: plan expired");

        // 引く額 = min(1回額, 残り上限)。最終回は端数トップアップ。maxTotal を厳格遵守。
        uint256 pullAmount;
        {
            uint256 remaining = p.maxTotal - p.totalPulled;
            require(remaining > 0, "DCA: cap reached");
            pullAmount = p.amountPerRun <= remaining ? p.amountPerRun : remaining;
        }

        // 冪等: 次回実行時刻を「今」から interval 先へ。連続 catch-up を防ぐ (Effects first)。
        p.nextRun = block.timestamp + p.interval;
        p.totalPulled += pullAmount;

        // 手数料 (既定 0) を控除して実投下額を確定。
        uint256 fee = platformFeeBps == 0 ? 0 : (pullAmount * platformFeeBps) / BPS;
        uint256 spendAmount = pullAmount - fee;
        require(spendAmount > 0, "DCA: spend zero");

        // 買付を実行し、owner が実際に受領した現物量を確定 (着金差分で再検証)。
        uint256 minOut;
        uint256 bought;
        (minOut, bought) = _buyForOwner(p, spendAmount, fee, keeperMinOut);

        p.totalBought += bought;
        emit Executed(planId, p.owner, pullAmount, spendAmount, fee, minOut, bought, p.nextRun);
    }

    /// @dev 資金移動 + スワップ + 着金再検証。スタック分離のため本体から切り出し。
    ///      非カストディ担保: `from` も現物受取人も `p.owner` に固定され差替経路が無い。
    function _buyForOwner(Plan storage p, uint256 spendAmount, uint256 fee, uint256 keeperMinOut)
        internal
        returns (uint256 minOut, uint256 bought)
    {
        address owner_ = p.owner;
        address stable_ = p.stable;
        address target_ = p.target;

        // スリッページ床をオンチェーン導出 (keeper の裁量ゼロ)。
        {
            uint256 expected = oracle.expectedOut(stable_, target_, spendAmount);
            require(expected > 0, "DCA: oracle zero");
            uint256 floorOut = (expected * (BPS - p.slippageBps)) / BPS;
            require(floorOut > 0, "DCA: floor zero");
            // keeper は床を「厳しく」しかできない。
            minOut = keeperMinOut > floorOut ? keeperMinOut : floorOut;
        }

        IERC20 stableToken = IERC20(stable_);

        // ユーザーの allowance 上限内で原資産 (手数料込み) を引く (三重上限の①)。
        stableToken.safeTransferFrom(owner_, address(this), spendAmount + fee);
        if (fee > 0) {
            require(feeRecipient != address(0), "DCA: no fee recipient");
            stableToken.safeTransfer(feeRecipient, fee);
        }

        // owner の現物残高増分を測る (swapper の返り値に依存しない着金検証)。
        uint256 balBefore = IERC20(target_).balanceOf(owner_);

        // swapper に spendAmount を都度承認 → 現物を owner へ直接届けさせる (宛先固定)。
        stableToken.forceApprove(address(swapper), spendAmount);
        swapper.swap(stable_, target_, spendAmount, minOut, owner_);
        stableToken.forceApprove(address(swapper), 0); // 余り承認を残さない (防御的)

        // 着金差分を独立に再検証。swapper が返り値で嘘をついても実着金不足なら revert。
        bought = IERC20(target_).balanceOf(owner_) - balBefore;
        require(bought >= minOut, "DCA: slippage");
    }

    // =========================================
    // Views
    // =========================================

    /// @notice owner のプラン ID 一覧
    function plansOf(address owner_) external view returns (uint256[] memory) {
        return _plansOf[owner_];
    }

    /// @notice プラン全フィールドを memory 構造体で返す (13 フィールドの多値 getter を
    ///         スタックに展開せず 1 メモリコピーで読めるようにする off-chain/テスト向け view)。
    function getPlan(uint256 planId) external view returns (Plan memory) {
        return plans[planId];
    }

    /// @notice プランが今この瞬間に実行可能か (keeper の事前フィルタ用)。
    /// @dev allowance/残高/オラクル床までは判定しない (実行時に確定)。
    function isDue(uint256 planId) external view returns (bool) {
        Plan storage p = plans[planId];
        if (!p.active) return false;
        if (block.timestamp < p.startTime) return false;
        if (block.timestamp < p.nextRun) return false;
        if (p.endTime != 0 && block.timestamp > p.endTime) return false;
        if (p.totalPulled >= p.maxTotal) return false;
        return true;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    // =========================================
    // Governance: swapper / oracle / keeper / fee 設定
    // =========================================

    /// @notice スワップ実行器を差し替える (Curve/Uniswap 流動性移行時の redeploy 対応)。
    function setSwapper(address newSwapper) external onlyGovernance {
        require(newSwapper != address(0), "DCA: zero swapper");
        emit SwapperSet(address(swapper), newSwapper);
        swapper = IStableSwapper(newSwapper);
    }

    /// @notice 価格オラクルを差し替える (フィード移行時の redeploy 対応)。
    function setOracle(address newOracle) external onlyGovernance {
        require(newOracle != address(0), "DCA: zero oracle");
        emit OracleSet(address(oracle), newOracle);
        oracle = IDCAPriceOracle(newOracle);
    }

    /// @notice keeper の許可/剥奪。keeper は資金を奪えない (§非カストディ担保)。
    function setKeeper(address keeper, bool allowed) external onlyGovernance {
        require(keeper != address(0), "DCA: zero keeper");
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice プラットフォーム手数料 (bps) を設定。上限 MAX_PLATFORM_FEE_BPS。既定 0。
    function setPlatformFee(uint256 newBps) external onlyGovernance {
        require(newBps <= MAX_PLATFORM_FEE_BPS, "DCA: fee too high");
        require(newBps == 0 || feeRecipient != address(0), "DCA: no fee recipient");
        emit PlatformFeeSet(platformFeeBps, newBps);
        platformFeeBps = newBps;
    }

    function setFeeRecipient(address newRecipient) external onlyGovernance {
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    // =========================================
    // Governance: M-4 2段 rotation
    // =========================================

    function proposeGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "DCA: zero governance");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "DCA: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    function setGuardian(address newGuardian) external onlyGovernance {
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    // =========================================
    // Circuit breaker
    // =========================================

    /// @notice 緊急停止: createPlan / execute を止める。既存プランの資金は影響なし
    ///         (資金は常にユーザー保有)。guardian または governance。
    function pause() external {
        require(msg.sender == governance || msg.sender == guardian, "DCA: unauthorized");
        _paused = true;
        emit Paused();
    }

    function unpause() external onlyGovernance {
        _paused = false;
        emit Unpaused();
    }

    // =========================================
    // Rescue (誤送金トークン回収・二重防御)
    // =========================================

    /// @notice 誤ってこのコントラクトに送られた ERC20 を回収する。governance のみ。
    /// @dev 通常フローで原資産・現物は滞留しない (execute は単一 tx 内で完結し、現物は
    ///      swapper から owner へ直接着金する)。仮に端数が残っても回収可能。ユーザーの
    ///      現物は各自のウォレットにあり本コントラクトは保持しない (横領不可)。
    function rescueToken(address token, address to) external onlyGovernance returns (uint256 amount) {
        require(to != address(0), "DCA: zero recipient");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}

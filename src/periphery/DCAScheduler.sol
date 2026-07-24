// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DCAScheduler — 非カストディ 積立(DCA / つみたて) スケジューラ
/// @notice ユーザーが「原資産(USDC) / 対象 SIXXVault / 1回額 / 間隔 / 期限 / 上限」を登録し、
///         keeper が期日ごとに `execute` を呼ぶと、**ユーザー本人が事前に付与した ERC20 approve
///         上限の範囲内でのみ** USDC を引き出し、対象 SIXXVault へ deposit する。発行される
///         シェアは **ユーザー本人 (`plan.owner`) に直接帰属** し、本コントラクトは一切保管しない。
///
/// @dev === 非カストディ担保 (keeper が資金を奪えない根拠) ===
///      1. **宛先固定**: シェアの受取人は登録時に確定した `plan.owner` のみ。keeper/governance
///         が受取人を差し替える経路は存在しない (`vault.deposit(amount, plan.owner)`)。
///      2. **上限固定**: 引ける原資産は ①ユーザーが token 側で付与した allowance、②`amountPerRun`、
///         ③`maxTotal` の3重上限を**同時に**超えられない。keeper は金額を任意に増やせない。
///      3. **周期固定**: `nextRun` により1周期に1回のみ (冪等)。keeper は連打で早回しできない。
///      4. **経路なし**: 本コントラクトから governance/keeper 宛に原資産・シェアを送る関数は存在
///         しない (`rescueToken` は誤送金の第三者トークン回収のみ・後述で二重防御)。
///      5. **主権**: ユーザーは `cancelPlan` で即停止でき、さらに token 側で
///         `USDC.approve(scheduler, 0)` すれば本コントラクトの呼び出し自体が無効化される
///         (コントラクトを介さないユーザー単独の最終停止手段)。
///      通常フローで原資産が本コントラクトに滞留するのは execute の**単一トランザクション内のみ**
///      (transferFrom → deposit は atomic。deposit revert 時は transferFrom も巻き戻る)。
///
/// @dev 既存 sixx-vault 規約を踏襲: SafeERC20 / ReentrancyGuard / M-4 2段 governance /
///      onlyX ガード / pause / rescueToken / Solidity 0.8.28。**Adapter ではない** ため
///      IStrategyAdapter は実装しない。SIXXVault 本体・既存 Adapter は一切変更しない。
contract DCAScheduler is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    /// @notice プラットフォーム手数料の絶対上限 (bps)。既定は 0。値は要 SHIN 決定。
    uint256 public constant MAX_PLATFORM_FEE_BPS = 500; // 5%

    /// @notice 積立間隔の下限。keeper の連打・過度に短い周期を抑止。
    uint256 public constant MIN_INTERVAL = 1 hours;

    uint256 internal constant BPS = 10_000;

    // =========================================
    // Types
    // =========================================

    struct Plan {
        address owner;        // シェア受取人 = ユーザー本人 (固定・変更不可)
        address asset;        // 原資産 (USDC 等) — vault.asset() と一致必須
        address vault;        // 対象 SIXXVault (ERC-4626)
        uint256 amountPerRun; // 1回の積立額 (原資産の最小単位)
        uint256 interval;     // 積立間隔 (秒)
        uint256 startTime;    // 最初に実行可能になる時刻
        uint256 endTime;      // 期限 (0 = 無期限)
        uint256 maxTotal;     // 累計上限 (この額を超えて引かない)
        uint256 totalDeposited; // これまでに deposit した累計 (手数料差引後の deposit 額)
        uint256 totalPulled;    // これまでに transferFrom で引いた累計 (手数料込み)
        uint256 nextRun;      // 次に実行可能になる時刻
        bool    active;       // 有効フラグ (cancel で false)
    }

    // =========================================
    // Storage
    // =========================================

    /// @notice planId => Plan
    mapping(uint256 => Plan) public plans;

    /// @notice 次に発行する planId (単調増加・0 は未使用)
    uint256 public nextPlanId = 1;

    /// @notice owner => 自分の planId 一覧 (UI 列挙用)
    mapping(address => uint256[]) internal _plansOf;

    /// @notice keeper 許可リスト (cron 実行 EOA)。resgister は governance のみ。
    mapping(address => bool) public isKeeper;

    /// @notice ガバナンス (M-4 2段)
    address public governance;
    address public pendingGovernance;

    /// @notice guardian: 緊急 pause のみ可能 (unpause は governance)
    address public guardian;

    /// @notice プラットフォーム手数料 (bps)。既定 0。deposit 前に原資産から控除。
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
        address indexed vault,
        uint256 amountPerRun,
        uint256 interval,
        uint256 startTime,
        uint256 endTime,
        uint256 maxTotal
    );
    event PlanCancelled(uint256 indexed planId, address indexed owner);
    event Executed(
        uint256 indexed planId,
        address indexed owner,
        uint256 pulled,
        uint256 deposited,
        uint256 fee,
        uint256 sharesToOwner,
        uint256 nextRun
    );
    /// @dev バッチ実行時、個別プランが未到来/期限切れ/allowance 不足等で skip された記録。
    event ExecutionSkipped(uint256 indexed planId, bytes reason);

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
    /// @param feeRecipient_  手数料受取先。手数料を有効化する場合に必須。0 可 (fee=0 前提)
    constructor(address governance_, address guardian_, address feeRecipient_) {
        require(governance_ != address(0), "DCA: zero governance");
        governance   = governance_;
        guardian     = guardian_;
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

    /// @notice 積立プランを登録する。呼び出し元 (msg.sender) が owner = シェア受取人となる。
    ///         登録後、ユーザーは別途 `asset` の approve をこのコントラクトへ付与する必要がある
    ///         (推奨: 有限上限 = amountPerRun × 予定回数、無限 max は非推奨)。
    /// @dev 資金移動は一切行わない (approve は token 側でユーザーが実施)。
    function createPlan(
        address asset_,
        address vault_,
        uint256 amountPerRun_,
        uint256 interval_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 maxTotal_
    ) external whenNotPaused returns (uint256 planId) {
        require(vault_ != address(0), "DCA: zero vault");
        require(asset_ != address(0), "DCA: zero asset");
        require(IERC4626(vault_).asset() == asset_, "DCA: asset/vault mismatch");
        require(amountPerRun_ > 0, "DCA: zero amount");
        require(interval_ >= MIN_INTERVAL, "DCA: interval too short");
        require(maxTotal_ >= amountPerRun_, "DCA: maxTotal < amountPerRun");

        uint256 start = startTime_ == 0 ? block.timestamp : startTime_;
        require(endTime_ == 0 || endTime_ > start, "DCA: endTime <= start");

        planId = nextPlanId++;
        plans[planId] = Plan({
            owner: msg.sender,
            asset: asset_,
            vault: vault_,
            amountPerRun: amountPerRun_,
            interval: interval_,
            startTime: start,
            endTime: endTime_,
            maxTotal: maxTotal_,
            totalDeposited: 0,
            totalPulled: 0,
            nextRun: start,
            active: true
        });
        _plansOf[msg.sender].push(planId);

        emit PlanCreated(planId, msg.sender, vault_, amountPerRun_, interval_, start, endTime_, maxTotal_);
    }

    /// @notice プランを恒久停止する。owner のみ。以降 execute は revert (非アクティブ)。
    /// @dev さらに強力な停止手段としてユーザーは token 側で `approve(scheduler, 0)` 可能
    ///      (コントラクトを介さない完全にユーザー主権の無効化)。
    function cancelPlan(uint256 planId) external {
        Plan storage p = plans[planId];
        require(p.owner == msg.sender, "DCA: not plan owner");
        require(p.active, "DCA: already inactive");
        p.active = false;
        emit PlanCancelled(planId, msg.sender);
    }

    // =========================================
    // Keeper: 実行 (資金は必ず owner 本人の vault ポジションへ)
    // =========================================

    /// @notice 単一プランを実行する。keeper のみ。§非カストディ担保の 1〜3 を強制。
    function execute(uint256 planId)
        external onlyKeeper whenNotPaused nonReentrant
    {
        _execute(planId);
    }

    /// @notice 複数プランをまとめて実行する。未到来/期限切れ/allowance 不足等の
    ///         「正常な非実行状態」は revert せず skip し、実行可能なものだけ処理する
    ///         (1件の失敗でバッチ全体が失敗しない運用要件)。
    /// @dev 各プランは self-call 経由で個別に nonReentrant/whenNotPaused ガードされる。
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
        _execute(planId);
    }

    /// @dev 実行本体。全ガードをここで一元的に適用する。
    function _execute(uint256 planId) internal {
        Plan storage p = plans[planId];
        require(p.active, "DCA: inactive plan");
        require(block.timestamp >= p.startTime, "DCA: not started");
        require(block.timestamp >= p.nextRun, "DCA: not due");
        require(p.endTime == 0 || block.timestamp <= p.endTime, "DCA: plan expired");

        // 上限までの残り。ここで maxTotal を厳格に守る (keeper は超過不可)。
        uint256 remaining = p.maxTotal - p.totalPulled;
        require(remaining > 0, "DCA: cap reached");

        // 引く額 = min(1回額, 残り上限)。最終回は端数トップアップ。
        uint256 pullAmount = p.amountPerRun <= remaining ? p.amountPerRun : remaining;

        // 冪等: 次回実行時刻を「今」から interval 先へ。連続 catch-up を防ぐ。
        p.nextRun = block.timestamp + p.interval;
        p.totalPulled += pullAmount;

        // 手数料 (既定 0)。deposit 前に原資産から控除。
        uint256 fee = platformFeeBps == 0 ? 0 : (pullAmount * platformFeeBps) / BPS;
        uint256 depositAmount = pullAmount - fee;
        require(depositAmount > 0, "DCA: deposit zero");

        p.totalDeposited += depositAmount;

        IERC20 token = IERC20(p.asset);
        address vault_ = p.vault;
        address owner_ = p.owner;

        // ユーザーの allowance 上限内で原資産を引く (三重上限の①)。
        // @dev Slither: arbitrary-send-erc20 (High) は本設計では FALSE POSITIVE。
        //      `from` = owner_ は createPlan で msg.sender に束縛され plan 単位で不変
        //      (差し替え経路なし)。かつ発行シェアの受取人も同一 owner_。よって keeper が
        //      どの plan を叩いても「その plan 所有者本人の資金を、本人の vault ポジションへ」
        //      しか動かせず、keeper/第三者は利得ゼロ。任意送金ではなく登録済み本人からの pull。
        token.safeTransferFrom(owner_, address(this), pullAmount);

        if (fee > 0) {
            require(feeRecipient != address(0), "DCA: no fee recipient");
            token.safeTransfer(feeRecipient, fee);
        }

        // vault が本コントラクトから depositAmount を pull できるよう都度承認。
        token.forceApprove(vault_, depositAmount);
        // シェアは owner 本人へ直接 mint (非カストディ担保②宛先固定)。
        uint256 shares = IERC4626(vault_).deposit(depositAmount, owner_);
        // 余り承認を残さない (deposit は厳密に depositAmount を引くが防御的に 0 化)。
        token.forceApprove(vault_, 0);

        emit Executed(planId, owner_, pullAmount, depositAmount, fee, shares, p.nextRun);
    }

    // =========================================
    // Views
    // =========================================

    /// @notice owner のプラン ID 一覧
    function plansOf(address owner_) external view returns (uint256[] memory) {
        return _plansOf[owner_];
    }

    /// @notice プランが今この瞬間に実行可能か (keeper の事前フィルタ用)。
    /// @dev allowance/残高までは判定しない (実行時 transferFrom で確定)。
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
    // Governance: keeper / fee 設定
    // =========================================

    /// @notice keeper の許可/剥奪。keeper は資金を奪えない (§非カストディ担保) が、
    ///         実行トリガー権限のため governance が管理する。
    function setKeeper(address keeper, bool allowed) external onlyGovernance {
        require(keeper != address(0), "DCA: zero keeper");
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice プラットフォーム手数料 (bps) を設定。上限 MAX_PLATFORM_FEE_BPS。
    /// @dev 既定 0。値は要 SHIN 決定 (decisions.md)。fee>0 の場合は feeRecipient 必須。
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
    /// @dev 通常フローで原資産は滞留しない (execute は単一 tx 内で全額 deposit)。
    ///      仮に端数が残っても回収可能。ユーザーのシェアは vault 側でユーザーが保有し、
    ///      本コントラクトは決して保持しないため rescue の対象にならない (横領不可)。
    function rescueToken(address token, address to) external onlyGovernance returns (uint256 amount) {
        require(to != address(0), "DCA: zero recipient");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}

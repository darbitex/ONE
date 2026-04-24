# ONE Aptos — R4 Post-Mainnet Adversarial Audit

**Round**: R4 (post-mainnet)
**Date**: 2026-04-24
**Target**: `0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387::ONE` (sealed)
**Source**: self-audit (Claude in-session) + external R4 submissions from Qwen3.6, DeepSeek, Kimi, Claude 4.7 fresh.
**Contract status**: immutable. All findings are disclosure-only.
**Tracking**: see `AUDIT_R4_TRACKING.md` for per-auditor responses verbatim.

---

## Verification results (before adversarial pass)

### V-01 — Bytecode parity: VERIFIED
Fresh compile of `sources/ONE.move` (named address `ONE=0x85ee9c43...`) produces byte-identical output to on-chain bytecode.

```
on-chain ONE.mv  sha256 = 5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a
local rebuild    sha256 = 5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a
size             14173 bytes (identical)
```

Implication: all prior R1-R3.1 findings and rejections apply directly to deployed behavior. Independently re-verified by Claude 4.7 R4 auditor.

### V-02 — Sealing: VERIFIED (three-layer defense)
1. `destroy_cap` tx `0x529f06db…2954fbb` executed 2026-04-24.
2. `is_sealed()` view returns `true`.
3. No `ResourceCap` struct present in account resources (only `Registry`, `0x1::account::Account`, `0x1::code::PackageRegistry`).
4. Account `authentication_key = 0x00…00` — no external private-key signer exists for @ONE.

### V-03 — Pyth dependency immutability: VERIFIED
Pyth package `0x7e78…b387` also has `authentication_key = 0x00…00` — cryptographically immutable.

### V-04 — Live state matches `DEPLOYMENT.md`

| View | Chain response | Expected |
|---|---|---|
| `is_sealed()` | `true` | ✓ |
| `totals()` | `(510000000, 0, 1e18, 0, 0)` | ✓ trove debt 5.10 ONE, empty SP, no liquidations |
| `reserve_balance()` | `0` | ✓ |
| `metadata_addr()` | `0xee5ebaf6ff851955…fadc4` | ✓ |
| `trove_of(0x0047)` | `(1108000000, 510000000)` | ✓ 11.08 APT / 5.10 ONE |
| `close_cost(0x0047)` | `510000000` | ✓ equals trove.debt |

---

## Finding summary table

| ID | Severity | Source | Title |
|---|---|---|---|
| R4-M-01 | MEDIUM | Claude 4.7 fresh | Stale-oracle asymmetry in "value-neutral" redemption framing |
| R4-L-01 | LOW | self + DeepSeek + Claude | WARNING (3) text imprecision: "~5%" should be "~2.5%" |
| R4-L-02 | LOW | Kimi | MIN_DEBT trove redemption fragmentation (exact `one_amt = 1.0101…` required) |
| R4-L-03 | LOW | Kimi | `MIN_P_THRESHOLD` cliff can block liquidation even when `total_sp > debt` |
| R4-L-04 | LOW | Kimi + Claude | `redeem_from_reserve` breaks `total_debt == Σ(trove.debt)` invariant — observability gap |
| R4-D-01 | DESIGN | self + all auditors | Bootstrap bad-debt risk: zero-SP + single trove = no liquidation possible |
| R4-I-01 | INFO | self + Claude + Qwen | PackageRegistry `upgrade_policy=compatible` misleading — immutability is cryptographic |
| R4-I-02 | INFO | self + DeepSeek + Claude | `sp_of` view aborts where `sp_settle` saturates |
| R4-I-03 | INFO | self + DeepSeek + Claude | MIN_DEBT applies per-call, not per-trove-total |
| R4-I-04 | INFO | self + Claude | Theoretical `coll_usd × 10000` u128 overflow (sub-realistic) |
| R4-I-05 | INFO | Kimi | Asymptotic `reward_index_coll` u128 overflow (sibling to I-04, different accumulator) |
| R4-I-06 | INFO | Claude | Zero-debt residual trove (post-full-redeem) UX edge — requires `close_trove` to reclaim |
| R4-I-07 | INFO | Claude | No `withdraw_collateral` / `reduce_debt` — partial delever forces self-redeem or close+reopen |
| R4-I-08 | INFO | Claude | Pyth confidence check is instantaneous (publication-time), not time-integrated; 60s staleness is sole time defense |
| R4-I-09 | INFO | Gemini 3 Flash | SP position row with `initial_balance = 0` persists in `sp_positions` smart table — minor state bloat, no fund risk |

**Cumulative**: 0 CRITICAL / 0 HIGH / 1 MEDIUM (disclosure-precision) / 4 LOW / 1 DESIGN / 9 INFO. All mitigations are off-chain (disclosure + frontend); no in-place patches possible (sealed).

---

## Findings

### R4-M-01 — Stale-oracle asymmetry in "value-neutral" redemption framing
**Severity**: MEDIUM (disclosure-precision + bootstrap-amplified wealth transfer; not a solvency / peg-break)
**Source**: Claude 4.7 fresh
**Location**: `redeem_impl` (line 330-356), `price_8dec` (line 168-194), `redeem` entry (line 374), `WARNING` const clause (9)

**Scenario**. Pyth cache has `(P_stored, ts_stored)`. Market has moved by Δ% since `ts_stored` but within the 60-second staleness window. Alice calls the bare `redeem(one_amt, target)` entry — **not** `redeem_pyth` — so no fresh VAA is submitted. `price_8dec()` returns `P_stored`.

Economic trace (assume P_market = P_stored × (1 + Δ), Δ > 0):
- `net = one_amt × (1 − 0.01)` (1% fee)
- `coll_out = net × 1e8 / P_stored` APT raw
- Alice's APT value at market: `net × (1 + Δ)` USD
- Alice's ONE cost at ~$1/ONE: `one_amt` = `net × 1/0.99` ≈ `net × 1.0101` USD
- **Net profit to Alice**: `net × (Δ − 0.01)` USD. Break-even at Δ = 1%. Above 1%, pure extraction.

Target trove's perspective:
- Debt reduced by `net` (accounted at $1/ONE)
- Collateral reduced by `net × 1e8 / P_stored` APT, worth `net × (1 + Δ)` at market
- **Target's net loss**: `net × Δ` of market-value equity

Protocol:
- Burns the 1% fee (25% always; 75% more if SP empty, 75% to SP indices otherwise)
- Protocol reserve/solvency unaffected (pool trades ONE supply for APT collateral at oracle-neutral rate)

**Why this is NOT a peg-break**: Alice's extraction is from the trove owner, not from the protocol reserve. `total_debt`, `product_factor`, `reward_index_*` all update consistently. The AMM peg (`redeem_from_reserve` route) is unchanged.

**Why this is NOT covered by WARNING (9)**: Clause (9) says redemption is *"value-neutral at oracle spot price"*. Technically true but misleading — most readers parse "spot" as market spot. Under a 60s pull-oracle lag window, oracle spot ≠ market spot, and the caller gets to pick *when* to act. Alice doesn't refresh Pyth because she **benefits** from the staleness; she exploits whatever VAA is cached, whoever posted it.

**Bootstrap amplification**: the current state has one trove. All redemption extraction falls on the genesis owner. In mature state, extraction is diluted across many troves (caller picks any, still extracts — but per-owner impact is smaller in expectation).

**Why MEDIUM, not HIGH**:
- 1% fee is the designed absorption band (matches Liquity V1 behavior against Chainlink lag).
- Protocol remains solvent; target retains value-at-oracle-spot.
- Target has a cheap defense: call `pyth::update_price_feeds_with_funder` directly before expected volatility (costs only Pyth update fee + gas).
- The attack requires APT volatility > 1% in 60s, which is common but not constant.

**Why MEDIUM, not LOW**:
- Bootstrap phase (low volume, low third-party Pyth refresh cadence) makes 60s window routinely stale.
- Single-trove concentration makes per-owner exposure high.
- Per-call extraction of 1-3% against protocol's only trove is meaningful.

**Related finding**: R4-I-08 (Pyth confidence check is publication-time, not time-integrated). Confidence gate does not prevent this because `conf` at publication was narrow; the staleness alone is the surface.

**Disclosure & mitigation path (sealed contract)**:
1. **`DEPLOYMENT.md`**: dedicated "Oracle-lag redemption disclosure" section explaining 60s window, "oracle spot ≠ market spot", caller-side timing optionality, 1% fee as partial absorption.
2. **Frontend Redeem page**:
   - Header banner when Pyth `ts_stored + 60 − now < 20` (i.e., Pyth is getting stale): *"Pyth feed is X seconds old. Consider refreshing before redeeming."*
   - Explicit "Refresh oracle" button triggering `pyth::update_price_feeds_with_funder` on its own (cheap, no redeem attached) — used by trove owners as a preemptive defense.
   - Redeemer-side disclosure: *"Redemption executes at the oracle's last-stored price, which may lag market up to 60 seconds. You may receive more or less APT than the current market rate would imply."*
3. **Frontend Trove page**: for trove owners, surface the Pyth freshness and a "Refresh oracle now" button as part of trove-defense UX.
4. **WARNING-derived user docs** should reword clause (9) to say *"value-neutral at oracle-recorded spot (which may lag market spot by up to 60 seconds)"*. The on-chain text cannot be edited.

---

### R4-L-01 — WARNING (3) text imprecision: "~5%" should be "~2.5%" for zero-reserve boundary
**Severity**: LOW (on-chain documentation defect; no protocol behavior change)
**Source**: self + DeepSeek + Claude 4.7 fresh (3/4 auditors; Qwen did not flag)
**Location**: `WARNING` const, clause (3)

**Claim in WARNING (3)**: *"At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero"*.

**Actual liquidation waterfall** (liquidator 2.5% of debt value, reserve 2.5% of debt value, SP absorbs remainder):

| CR band (coll_usd / debt) | Liquidator | Reserve | SP |
|---|---|---|---|
| CR ≥ 150% | not liquidatable | — | — |
| 5% ≤ CR < 110% | 2.5% of debt | 2.5% of debt | remainder > 0 |
| 2.5% ≤ CR < 5% | 2.5% of debt | partial (≤ 2.5%) | **0** |
| CR < 2.5% | **entire remaining coll** | **0** | **0** |

- SP first hits zero at CR ≈ 5% (matches WARNING).
- **Reserve first hits zero at CR ≈ 2.5%** (NOT 5% as text implies).
- Liquidator takes 100% only at CR < 2.5%.

On-chain text conflates two boundaries. WARNING is more pessimistic than reality between CR 2.5% and 5%.

**Disclosure path**: frontend About page + `DEPLOYMENT.md` notes clarify actual two-boundary waterfall. Contract sealed — no patch.

---

### R4-L-02 — MIN_DEBT trove redemption fragmentation
**Severity**: LOW (redemption UX; no fund loss)
**Source**: Kimi
**Location**: `redeem_impl` line 331 (`assert!(one_amt >= MIN_DEBT, E_AMOUNT)`) + line 344 (`assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN)`)

**Scenario**. Trove T opened at exactly MIN_DEBT = 1 ONE (100,000,000 raw). A redeemer wants to fully clear T:
- `one_amt = 100_000_000` → `net = 99_000_000` → target debt becomes `1_000_000` ∈ (0, MIN_DEBT) → **ABORT E_DEBT_MIN**.
- Any `one_amt` in the range `[100_000_000, 101_010_100]` aborts — a "dead zone" where partial redeem leaves residual debt < MIN_DEBT but > 0.
- Only `one_amt = 101_010_101` exactly (= `100_000_000 × 100/99`, rounded) reduces target debt to 0 and succeeds.

This unintuitive amount requires an off-chain solver; naive "burn 1 ONE to clear 1 ONE" attempts abort.

**Adversarial angle**: attacker opens many MIN_DEBT troves (each requires 2 APT at MCR=200%, so capital is real) to fragment the redemption flow. Large redeemers must issue many precisely-calibrated small redemptions, paying 1% fee per call. Griefing, not theft.

**Disclosure path**: frontend Redeem flow must compute the exact `one_amt` to drive a target trove to 0 or ≥ MIN_DEBT residual, and warn if the target is at MIN_DEBT: *"This trove has minimum debt. Full redemption requires burning exactly 1.0101… ONE (101,010,101 raw). Lower amounts will be rejected."*

---

### R4-L-03 — `MIN_P_THRESHOLD` cliff can block liquidation even when `total_sp > debt`
**Severity**: LOW (liquidation DX / liveness; no fund loss)
**Source**: Kimi
**Location**: `liquidate` line 418-419 (`new_p = product_factor * (total_before - debt) / total_before; assert!(new_p >= MIN_P_THRESHOLD)`)

**Scenario**. After many prior liquidations, `product_factor` has decayed toward the cliff (MIN_P_THRESHOLD = 1e9). Even if `total_sp > debt` satisfies the strict inequality, the post-liquidation `new_p` can still fall below MIN_P_THRESHOLD, aborting `E_P_CLIFF`.

Kimi's worked example: with pf = 1.5e9 (near-cliff), debt = 5 × 10^8, total_sp = 5 × 10^8 + 1: `new_p = 1.5e9 × 1 / 500000001 ≈ 3`, aborts.

**Reachability**: requires many prior liquidations to push pf near 1e9. Fresh bootstrap state has pf = 1e18, so this does not apply to current state. Becomes relevant only in mature protocol state.

**Disclosure path**: frontend Liquidation UI should compute `new_p` pre-submission and surface: *"Stability Pool is too small relative to this trove's debt after prior liquidations. Liquidation is temporarily frozen until SP grows."*

---

### R4-L-04 — `total_debt` observability gap (redeem_from_reserve)
**Severity**: LOW (observability / integrator misinterpretation; no fund loss)
**Source**: Kimi (INFO) + Claude 4.7 fresh (LOW, promoted)
**Location**: `redeem_from_reserve` lines 389-392 (comment documents intentional omission)

**Observation**. `redeem_from_reserve` burns circulating ONE without decrementing `total_debt`. The field `total_debt` is defined as `Σ(t.debt for t in live troves)`, not circulating supply. The source comment makes this explicit, but the view `totals()` returns `total_debt` without semantic context.

**Risk**: an analytics dashboard / aggregator / integrator treating `totals()[0]` as a proxy for circulating ONE supply will **overreport** supply after any reserve-redemption event. Circulating supply must be read from `fungible_asset::supply(metadata)` directly, not from `totals()`.

**Disclosure path**: `DEPLOYMENT.md` explicit semantics note — *"`total_debt` = sum of live trove debts; circulating ONE supply should be read via `fungible_asset::supply(metadata)`. The two diverge after every `redeem_from_reserve` call (supply decreases; total_debt unchanged). This gap is the intended reserve-drain mechanic."*

---

### R4-D-01 — Bootstrap bad-debt risk (zero SP + single genesis trove)
**Severity**: DESIGN / OPERATIONAL (unanimous across 4/4 R4 auditors; severity range DESIGN → LOW → MEDIUM across auditor opinions)
**Source**: self (DESIGN), DeepSeek (LOW), Kimi (MEDIUM), Claude 4.7 fresh (INFO extension), Qwen (misclassified CRIT — rejected)

**Pre-state** (current mainnet): `total_sp = 0`, one trove (genesis, 11.08 APT / 5.10 ONE, owned by 0x0047).

**Core observation**: `liquidate` requires `total_sp > debt` (strict). With SP empty, **no trove is liquidatable at any CR**. If APT drops ~26% (to ~$0.69), genesis trove crosses LIQ_THRESHOLD (150%) but remains unliquidatable. Protocol enters bad-debt accumulation with no on-chain recovery until SP is seeded or trove is voluntarily closed.

**Extension from Kimi — DOS amplification via exact-debt SP deposit**:
An attacker could `sp_deposit(exactly debt)` → `total_sp = debt` → strict `>` fails → every liquidate aborts. Attacker's SP sits locked but has zero profit potential (no liquidation occurs). Honest liquidator must deposit **strictly more** than attacker's contribution PLUS full debt, and attacker can `sp_withdraw` between honest deposit and liquidate txs, reverting progress.

Self-limiting: attacker locks `debt` worth of capital for zero profit — not economically rational except for pure griefers. Any honest actor with ≥ `debt + 1` fresh capital wins (attacker withdrawal doesn't help if honest alone covers `debt`).

**Extension from DeepSeek + Claude — permissionless-liquidation race**:
A second-mover attacker (under APT crash) could (a) open their own trove at MCR ≥ 200%, (b) mint ONE, (c) sp_deposit that ONE, (d) liquidate the now-unhealthy genesis trove, capturing the 2.5% bonus at genesis owner's expense. This is *designed permissionless liquidation*, not an exploit — the genesis owner has equal access to defenses (add_collateral, self-redeem, sp_deposit).

**Extension from Claude — first-liquidator capital gate**:
For current genesis trove (5.10 ONE debt), the first liquidator needs:
- ~10.2 APT to open their own trove at MCR=200% (minting 5.10+ ONE)
- Because `route_fee_fa` burns fees (and SP is empty, so 100% burn on any mint), they receive only 99% of mint.
- They must acquire the shortfall (~0.10 ONE) from the secondary market (Darbitex pool at `0x630a4cb9...`).
- Sum: ~$10 of APT + ~$0.10 from secondary = ~$10.10 total capital at bootstrap prices.

This makes the first liquidation meaningfully capital-intensive relative to the $0.13 bonus (2.5% × 5.10 ONE). Not profitable at current scale — requires APT to drop enough to make the genesis trove liquidatable AND the bonus to exceed capital costs.

**Disclosure & operational mitigation (sealed contract)**:
1. **`DEPLOYMENT.md`**: dedicated "Operational risks at bootstrap" section with DOS narrative + first-liquidator capital math + preemption options.
2. **Frontend Home / About**: prominent banner while `total_sp == 0 AND active_trove_count ≤ 1`: *"Stability Pool is empty. Liquidations are currently impossible. ONE may trade off-peg if the sole trove becomes unhealthy. Seed the Stability Pool to restore liquidation capacity."*
3. **Operator action** (separate decision for the user): seed SP with a nominal amount (e.g., 1-2 ONE once secondary-market ONE is available). Current genesis owner wallet has 0.049 ONE — insufficient; would require acquiring ONE from Darbitex pool first.

---

### R4-I-01 — PackageRegistry `upgrade_policy = compatible` is misleading (INFORMATIONAL)
**Severity**: INFO (external-observer-misleading; immutability unaffected)
**Source**: self + Claude 4.7 fresh; Qwen raised same (LOW-01)
**Location**: on-chain `PackageRegistry` resource

On-chain state: `upgrade_policy: {policy: 1}` (compatible), `upgrade_number: 0`.

Policy `1` ≠ `2 (immutable)`. An external reviewer reading only PackageRegistry could conclude the package is upgradable. Not true — immutability is guaranteed by:
- **Layer 2** — `auth_key = 0x00…00` (no external signer)
- **Layer 3** — `ResourceCap` resource absent (signer capability destroyed via `destroy_cap`)

Only layers 2+3 provide cryptographic immutability. Layer 1 (policy) is not a safety property for resource-account + destroy_cap pattern.

**Disclosure path**: `DEPLOYMENT.md` explicit 3-layer walkthrough. External verifiers should be guided through all three checks.

---

### R4-I-02 — `sp_of` view aborts where `sp_settle` saturates (INFORMATIONAL / DX)
**Severity**: INFO (UX only; user funds not at risk)
**Source**: self + DeepSeek + Claude 4.7 fresh
**Location**: `sp_of` lines 576-585 vs `sp_settle` saturation branch (lines 242-249)

`sp_settle` saturates pending rewards at `u64::MAX` and emits `RewardSaturated`. The read-only `sp_of` view does raw `as u64` casts that **abort** on overflow.

Asymptotic only: WARNING (2) territory, requires >> 1.8e19 raw units of pending rewards (decades of fee accrual at implausible volumes). Frontend can abort when displaying such a position; user can still call `sp_claim`/`sp_withdraw` (both use `sp_settle`, which saturates).

**Disclosure path**: `DEPLOYMENT.md` note alongside WARNING (2). Frontend should catch abort and display saturation message with CLI `sp_claim` pointer.

---

### R4-I-03 — MIN_DEBT enforced on added debt, not total (INFORMATIONAL)
**Severity**: INFO (UX limitation, no protocol risk)
**Source**: self + DeepSeek + Claude 4.7 fresh
**Location**: `open_impl` line 272

`debt >= MIN_DEBT` is applied to the **added** debt per call, not to the trove's total debt post-op. A user with an existing 5-ONE trove cannot incrementally borrow +0.5 ONE in a single `open_trove` call.

Combined with the absence of any `reduce_debt` / `withdraw_collateral` function (see R4-I-07), users wanting sub-1-ONE adjustments must either (a) batch multiple ≥1-ONE borrows, or (b) use `add_collateral` for collateral-only top-ups (no MIN_DEBT gate), or (c) self-redeem.

**Disclosure path**: frontend Trove page tooltip.

---

### R4-I-04 — Theoretical `coll_usd × 10000` u128 overflow (INFORMATIONAL)
**Severity**: INFO (sub-realistic; no practical risk)
**Source**: self + Claude 4.7 fresh
**Location**: lines 285, 414 (MCR check, LIQ_THRESHOLD check)

At `coll = u64::MAX` and pathological `price_8dec ≈ 9.2e26`, `coll_usd × 10000` can exceed u128::MAX. Requires simultaneously holding >> all APT supply as collateral AND APT priced at >> $1e18 per coin. Impossible.

Claude 4.7 fresh addition: the existing expo-negative assertion at line 178 (`assert!(i64::get_is_negative(&e_i64), E_PRICE_EXPO)`) keeps `price_8dec` realistically bounded. The theoretical overflow requires bypassing this assertion (which would require Pyth guardian collusion to emit a zero-expo feed) — so not reachable under the guardian assumption.

**Disclosure path**: `DEPLOYMENT.md` note alongside WARNING (2) asymptotic bounds.

---

### R4-I-05 — Asymptotic `reward_index_coll` u128 overflow (INFORMATIONAL)
**Severity**: INFO (liveness only; no fund loss)
**Source**: Kimi
**Location**: `liquidate` line 444-445 (`r.reward_index_coll = r.reward_index_coll + (sp_coll as u128) * r.product_factor / (total_before as u128)`)

`reward_index_coll` is a u128 accumulator. Per-liquidation delta is bounded by `sp_coll × pf / total_before`. In pathological states (very large `sp_coll`, small `total_before`, pf near PRECISION), per-step delta can approach 1e29, and many such extreme liquidations could asymptotically overflow u128::MAX ≈ 3.4e38.

Move arithmetic overflow aborts (does not silently wrap), so overflow would permanently freeze the liquidation path rather than corrupt state.

**Reachability**: requires thousands-to-billions of extreme liquidations, each with near-max sp_coll ratio. Not realistic under normal operation. Sibling to R4-I-04 but on a different accumulator.

**Disclosure path**: `DEPLOYMENT.md` asymptotic-bounds note.

---

### R4-I-06 — Zero-debt residual trove UX edge (INFORMATIONAL)
**Severity**: INFO (UX; no fund loss)
**Source**: Claude 4.7 fresh
**Location**: `redeem_impl` line 344 (allows `t.debt == 0` as valid post-state)

**Observation**. After a full redemption that zeroes a trove's debt (`t.debt = 0, t.collateral > 0`), the trove row persists in `r.troves`. The owner must subsequently call `close_trove` to reclaim the collateral. In this state:
- Not re-redeemable (`assert!(t.debt >= net, E_TARGET)` with `t.debt = 0` and `net ≥ MIN_DEBT` aborts)
- Not liquidatable (`coll_usd * 10000 < LIQ_THRESHOLD_BPS * 0` trivially false → `E_HEALTHY`)
- Can `add_collateral` further (no CR check, no oracle)
- `close_trove` returns full collateral at no ONE cost (burn branch skipped via `if (t.debt > 0)`)

**Disclosure path**: frontend Trove page should detect zero-debt state and surface a prominent *"Close & withdraw all collateral"* CTA. Expose the state in trove-list UI so owners don't forget.

---

### R4-I-07 — No `withdraw_collateral` / `reduce_debt` — partial delever forces self-redeem or close+reopen (INFORMATIONAL)
**Severity**: INFO (DX; no fund loss)
**Source**: Claude 4.7 fresh

**Observation**. Available trove ops are: open (adds both coll + debt), `add_collateral` (coll-only), `redeem` (partial coll-for-debt swap at oracle, 1% fee), `close_trove` (full exit), `liquidate` (forced exit). There is no `withdraw_collateral_partial` or `repay_debt_partial`.

A user who wants to partially deleverage (e.g., reduce 5-ONE debt to 3-ONE without closing) must:
- Self-redeem: burn 2+ ONE of their own ONE against their own trove (subject to MIN_DEBT end-state and 1% fee), or
- Close + reopen (1% mint fee again on reopen).

Liquity V1's `adjustTrove` is the closest analog ONE lacks.

**Disclosure path**: frontend Trove page should offer a "self-redeem to delever" flow that wraps this pattern with fee disclosure.

---

### R4-I-09 — SP position row with zero `initial_balance` persists permanently (INFORMATIONAL)
**Severity**: INFO (state bloat; no fund loss)
**Source**: Gemini 3 Flash
**Location**: `sp_settle` (lines 222-254), `sp_withdraw` (lines 500-515)

**Observation**. If a user deposits a small amount to SP (e.g., `initial_balance = 5 × 10^7` raw = 0.5 ONE), and subsequent liquidations push `product_factor` toward MIN_P_THRESHOLD (1e9), the saturated `new_balance = initial × pf / snap_p` can round down to 0 via u64 truncation:
- `new_balance = 5 × 10^7 × 10^9 / 10^18 = 5 × 10^-2 → truncates to 0`

After sp_settle writes `pos.initial_balance = 0`:
- `sp_withdraw` requires `amt > 0` at entry and `pos.initial_balance >= amt` — **always fails** for zero-balance rows.
- `sp_claim` short-circuits (`if (snap_p == 0 || initial == 0) { ...update snapshots... return; }`) — no reward claim, but position is never removed.
- `sp_deposit` from the same user adds to the zero-balance row (incrementing), reviving the position.

The row persists in `r.sp_positions` smart table permanently unless the user re-deposits. Move smart tables do not reclaim storage for removed entries, but a lingering zero-balance entry is never removed to begin with.

**Reachability**: requires (a) sub-1-ONE SP deposit and (b) product_factor decay near the cliff. Both rare in mature operation, essentially impossible in the current bootstrap state (pf = 1e18, SP = 0).

**Impact**: minor, open-ended state bloat if many small depositors experience near-cliff liquidation chains. No economic harm to the user (they already lost their deposit to liquidations proportionally; the zero row is just a trailing record).

**Disclosure path**: `DEPLOYMENT.md` asymptotic-behavior note. Frontend can detect `sp_of(addr) == (0, 0, 0)` with an existing row (via attempted sp_withdraw) and surface: *"Your SP position has been fully consumed by liquidations. Re-deposit to reactivate."*

---

### R4-I-08 — Pyth confidence check is instantaneous, not time-integrated (INFORMATIONAL)
**Severity**: INFO (supports M-01 analysis)
**Source**: Claude 4.7 fresh
**Location**: `price_8dec` line 186 (`assert!((conf as u128) * 10000 <= (MAX_CONF_BPS as u128) * raw, E_PRICE_UNCERTAIN)`)

**Observation**. The 2% confidence gate is evaluated using the `conf` published by Pyth at `ts_stored`. It reflects publication-time uncertainty, not time-since-publication divergence. A price published with narrow confidence and then allowed to stale for 60 seconds still passes the conf check cleanly — nothing in the oracle path warns about time-lag-induced market drift.

The 60-second `STALENESS_SECS` check is the **only** defense against time-delayed divergence. This directly enables R4-M-01: alert callers exploit stale-but-high-confidence prices without any confidence-based alarm.

**Disclosure path**: covered by R4-M-01 disclosure package (the oracle-lag risk note ties both findings together).

---

## Observations confirmed as non-findings (all 4 R4 auditors concur)

- **Reentrancy immunity**: ONE is non-dispatchable (`option::none()` at line 132); APT has `EAPT_NOT_DISPATCHABLE`. No FA hook path back into ONE module.
- **Signer/capability leakage**: no function reads `@ONE`'s `ResourceCap` besides `destroy_cap`. Post-destroy the cap is gone; no other code derives a signer for `@ONE`. `ExtendRef`s are scoped to child objects only.
- **Liquity-P index math**: `reward_index_coll += sp_coll × product_factor / total_before` uses OLD `product_factor` and OLD `total_before` — mathematically required form.
- **SP reset-on-empty** (line 481-483): safe because `total_sp == 0` implies `sp_positions` table is empty (sp_withdraw removes entries at `initial_balance == 0`).
- **route_fee_fa dust handling**: 0-amt destroyed via `destroy_zero`; sub-4 amounts skip burn but still route to SP pool or burn-on-empty correctly.
- **Redemption target selection**: documented as WARNING (9). Value-neutral at oracle spot (modulo M-01 on the "oracle spot ≠ market spot" framing).
- **Bootstrap front-run immunity**: between publish and destroy_cap, external actors could call public entries but no entry exposes `ResourceCap` — no capability-theft path.

---

## Gemini 3 Flash findings — 2 claimed CRIT/MED rejected as re-raises

Gemini 3 Flash submitted 1 CRIT + 2 MED + 1 LOW + 1 INFO. Disposition:

| Gemini 3 Flash claim | Disposition | Reason |
|---|---|---|
| CRIT — Permanent collateral lock (supply < debt "musical chairs") | REJECTED (re-raise of WARNING 4) | Documented designed peg-pressure mechanism. Users acquire 1% close-deficit from secondary market (Darbitex pool). Redemption allows burning ONE for APT at spot. No "lock" — just cost transfer. Hyperbolic framing. |
| MED — Redemption target abuse (no health-based priority) | REJECTED (re-raise of WARNING 9) | Value-neutrality at oracle spot documented. Math: redemption monotonically *improves* CR for any healthy target (verified). Caller choice of target does not reduce protocol resilience. |
| MED — SP state bloat (initial_balance → 0 persists) | ACCEPTED as R4-I-09 (INFO, not MED) | Real but minor. Reclassified to INFO per severity rubric — no fund loss, sub-realistic reachability. |
| LOW — WARNING-3 math discrepancy | = R4-L-01 | Confirmation. |
| INFO — Dust-limit redemption griefing | = R4-L-02 (Kimi's, at lower severity) | Confirmation. |

Net Gemini 3 Flash actionable findings: 1 (INFO, R4-I-09).

---

## Qwen3.6 findings (REJECTED en bloc)

Qwen3.6 submitted 2 CRIT + 3 HIGH + 4 MED. All rejected:

| Qwen claim | Disposition | Reason |
|---|---|---|
| CRIT-01 SP-empty deadlock | FALSE escalation of R4-D-01 | Proposed fix ("burn debt without token burn") breaks supply=debt invariant; unsound |
| CRIT-02 staleness manipulation | FALSE | Pyth VAAs are guardian-signed; attacker cannot inject custom price. Proposed circuit breaker would worsen bad-debt under crashes |
| HIGH-01 satoshi truncation | FALSE (reversed math) | Integer division rounds DOWN → favors protocol, not attacker. MIN_DEBT guard blocks dust redeems |
| HIGH-02 product_factor overflow | FALSE (reversed math) | pf = pf × (total−debt)/total ≤ pf; monotonically decreasing. Cliff guard at 1e9. u128 overflow impossible |
| HIGH-03 fee-activation grief | FALSE | SP-empty path burns fees (line 214-215); nothing "parks" to retroactively claim |
| MED-01 MIN_DEBT raise | REJECTED AS SPEC | Retail-first design; pre-committed (see `feedback_one_min_debt.md`) |
| MED-02 reentrancy guards | FALSE | Solidity pattern applied to non-dispatchable Move FAs; not applicable |
| MED-03 expo bounds | FALSE | Existing check at line 180 (`abs_e <= 18`) missed by auditor |
| MED-04 static WARNING | NON-FINDING | Immutable const in sealed bytecode; cannot be dynamic by construction |
| INFO-02 destroy_cap hash not published | FACTUALLY WRONG | IS published in DEPLOYMENT.md § "Deploy transactions" + AUDIT_R4_SUBMISSION.md § 1 |

Net Qwen actionable findings: 0. See `AUDIT_R4_TRACKING.md` for full rebuttal.

---

## Cumulative disclosure plan for `DEPLOYMENT.md`

Required additions:

1. **Known post-mainnet notes (R4)**: R4-L-01 (WARNING-3 text), R4-L-04 (total_debt semantics), R4-I-01 (upgrade_policy framing), R4-I-02 (sp_of vs sp_settle), R4-I-03 (MIN_DEBT per-call), R4-I-04 (asymptotic u128 MCR check), R4-I-05 (asymptotic reward_index_coll), R4-I-07 (no withdraw_collateral), R4-I-08 (Pyth conf instantaneous).
2. **Oracle-lag redemption disclosure (R4-M-01)**: dedicated section on pull-oracle semantics, 60s window, caller-timing optionality, fee as absorption band, trove-owner refresh-button defense.
3. **Operational risks at bootstrap (R4-D-01)**: SP-empty liquidation impossibility, APT threshold (~$0.69), DOS amplification via exact-debt SP deposit, first-liquidator capital cost.
4. **Immutability verification walkthrough**: 3-layer defense (policy vs auth vs capability) to guide external verifiers past the misleading `upgrade_policy = compatible` registry flag.
5. **`total_debt` semantic note**: `totals()[0]` = sum of live trove debts; circulating supply via `fungible_asset::supply(metadata)`.

---

## Frontend disclosure plan

- **Home / About page**: SP-empty banner; immutability 3-layer explainer; live-state widget showing Pyth freshness.
- **Trove page**: oracle-refresh button (R4-M-01 defense); zero-debt residual detection + close CTA (R4-I-06); self-redeem delever flow (R4-I-07); MIN_DEBT per-call tooltip (R4-I-03).
- **Redeem page**: Pyth freshness banner + stale warning (R4-M-01); MIN_DEBT target-trove exact-amount calculator (R4-L-02); documented disclosure text.
- **Stability Pool page**: cliff warning when pf near MIN_P_THRESHOLD (R4-L-03); sp_of saturation graceful fallback (R4-I-02).
- **Liquidation page** (when built): pre-flight `new_p` check (R4-L-03); capital-cost estimator for first liquidation.

---

## R4 verdict

**GREEN with 1 MEDIUM disclosure-gap (M-01).** Zero CRITICAL, zero HIGH. The sealed v0.1.3 bytecode is economically sound and structurally immutable. All findings translate to off-chain disclosure + frontend additions. No migration pressure; v0.1.3 remains the live deployment.

Decision gate: re-audit only if (a) Pyth announces breaking API change (WARNING 8 triggers), or (b) trove/SP state evolves beyond current R4 baseline in a way exposing new surface (first non-genesis trove, first non-zero SP, first liquidation).

**5/8 R4 external auditor roster complete** (Qwen3.6 — 0 actionable, DeepSeek — GREEN, Kimi — GREEN + 3 LOW / 2 INFO new, Claude 4.7 fresh — GREEN with 1 MED + 2 LOW + 3 INFO new, Gemini 3 Flash — claimed CRIT/2 MED rejected as re-raises of existing WARNINGs + 1 INFO new + 2 confirmations). Remaining slots: Gemini 3.1, Grok, GPT — pending.

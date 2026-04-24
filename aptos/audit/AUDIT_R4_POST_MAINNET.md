# ONE Aptos — R4 Post-Mainnet Adversarial Audit

**Auditor**: Claude (in-session, fresh pass on deployed bytecode)
**Date**: 2026-04-24
**Target**: `0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387::ONE` (sealed)
**Prior rounds**: R1 (8 auditors), R2 (Claude), R3 + R3.1 (Gemini 3.1, Claude) — all GREEN.
**Contract status**: immutable. Findings are disclosure-only.

---

## Verification results (before adversarial pass)

### V-01 — Bytecode parity: VERIFIED
Fresh compile of `sources/ONE.move` (named address ONE=0x85ee9c43...) produces byte-identical output to on-chain bytecode.

```
on-chain ONE.mv  sha256 = 5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a
local rebuild    sha256 = 5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a
size             14173 bytes (identical)
```

Implication: all prior R1-R3.1 findings and rejections apply directly to deployed behavior. No source-vs-bytecode drift.

### V-02 — Sealing: VERIFIED (three-layer defense)
1. `destroy_cap` tx `0x529f06db…2954fbb` executed 2026-04-24.
2. `is_sealed()` view returns `true`.
3. No `ResourceCap` struct present in account resources (only `Registry`, `0x1::account::Account`, `0x1::code::PackageRegistry`).
4. Account `authentication_key = 0x00…00` — no external private-key signer exists for @ONE.

### V-03 — Pyth dependency immutability: VERIFIED
Pyth package `0x7e78…b387` also has `authentication_key = 0x00…00` — cryptographically immutable. Consistent with existing memory (`feedback_chainlink_aptos_gated.md`, `feedback_immutability_framing.md`).

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

## New findings (not in R1-R3.1)

### R4-L-01 — WARNING (3) text imprecision: "~5%" should read "~2.5%"
**Severity**: LOW (on-chain documentation defect; no protocol behavior change)
**Location**: `WARNING` const in source line 62, clause (3)

**Claim in WARNING (3)**:
> "At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero"

**Actual math** in `liquidate` (lines 405-470):
- Liquidator share target: `LIQ_LIQUIDATOR_BPS/10000 × LIQ_BONUS_BPS/10000 = 2.5% × 10% = 0.25% of debt_usd`… wait, scaled: `liq_share_usd = debt × 0.1 × 0.25 = debt × 0.025` → liquidator receives APT worth **2.5% of debt value**.
- Reserve share target: same 2.5% of debt value.
- Seize cap: `total_seize_coll = min(coll, (debt + 10% bonus) × 1e8 / price)`.

Undercollateralized case (coll_usd < 1.1 × debt): `total_seize_coll = coll`. Then:

| CR band (coll_usd / debt) | Liquidator | Reserve | SP |
|---|---|---|---|
| CR ≥ 150% | n/a (not liquidatable) | — | — |
| 5% ≤ CR < 110% | 2.5% of debt | 2.5% of debt | remainder |
| 2.5% ≤ CR < 5% | 2.5% of debt | partial (up to remainder) | **0** |
| CR < 2.5% | **full remaining coll** (≤ 2.5% of debt) | **0** | **0** |

So:
- SP first hits zero at CR ≈ 5% (matches WARNING text).
- Reserve first hits zero at CR ≈ 2.5% (NOT 5% as WARNING implies).
- Liquidator-takes-all at CR < 2.5% (NOT 5%).

The WARNING conflates two different boundaries. Factually the stronger claim ("liquidator takes entire remaining collateral, reserve and SP receive zero") is only true at CR < 2.5%.

**Practical impact**: minimal. Liquidations at CR < 5% are already exceptional (indicate catastrophic collateral crash). The text is more conservative than reality (implies zero reserve at less-bad CR than actual), which is arguably defensible as a "protection disclosure" but is not precise.

**Disclosure path**: add clarifying note to `DEPLOYMENT.md` and frontend `About` page that the on-chain WARNING (3) text over-states the zero-reserve boundary — actual transition is at CR ≈ 2.5%, not ≈ 5%. Contract sealed; no patch possible.

---

### R4-D-01 — Bootstrap bad-debt risk (OPERATIONAL)
**Severity**: DESIGN / OPERATIONAL (not a protocol bug; state of the live system)

Current mainnet state:
- `total_sp = 0` (no stability pool depositors)
- `total_debt = 5.10 ONE` concentrated entirely in the genesis trove (11.08 APT / 5.10 ONE, owned by 0x0047)
- APT at deploy ≈ $0.9328 → genesis trove CR ≈ 202.6%

Liquidation requires `total_sp > debt` (line 415). With SP at zero, **no trove can be liquidated by anyone, ever, at this state** — `E_SP_INSUFFICIENT` aborts.

If APT/USD drops below ~$0.69 (a ~26% decline from current), the genesis trove crosses LIQ_THRESHOLD (150% CR) and becomes "healthy-to-liquidate" by health-check but `total_sp=0` blocks execution. Protocol enters bad-debt accumulation with no on-chain recovery until:

1. SP is seeded (requires someone to `sp_deposit ≥ debt` ONE),
2. Genesis trove is voluntarily closed (requires operator to acquire ~5.151 ONE on secondary = 5.10 debt + 1% close deficit; Darbitex pool `0x630a4cb9…` holds 5 ONE at 1:1 with USDC and is the secondary venue), or
3. More troves are opened by other users (still doesn't help if they're also unliquidatable).

**This is not a bug** — it's the designed "SP-priority" liquidation model, and WARNING (3) generally mentions bad-debt accumulation past the cliff. However, the bootstrap-specific operational risk (single-trove, zero-SP launch) is not called out explicitly.

**Disclosure path**: add "Operational risks at bootstrap" section to `DEPLOYMENT.md`:
- Operator commits to monitor APT price against the liquidation threshold of the genesis trove.
- Consider seeding SP with a nominal amount (e.g., 1-2 ONE via `sp_deposit`) once sufficient ONE becomes available, so that automatic liquidation becomes possible.
- Alternative mitigation: close genesis trove via open-market acquisition if APT approaches the threshold.

---

### R4-I-01 — upgrade_policy = "compatible" on PackageRegistry (INFORMATIONAL)
**Severity**: INFO (external-observer-misleading; immutability is unaffected)

On-chain PackageRegistry reports:
```
upgrade_policy: {'policy': 1}  # compatible
upgrade_number: 0
```

Policy `1` = compatible (not `2` = immutable). An external observer reading only the PackageRegistry might conclude the package is upgradable. It is not — immutability is guaranteed by the **capability layer** (no ResourceCap) and **auth layer** (auth_key=0x0), not by the policy flag.

The three-layer defense (policy + auth + capability) is standard for resource-account + destroy_cap patterns, but only layers 2+3 provide the actual cryptographic immutability guarantee.

**Disclosure path**: `DEPLOYMENT.md` already notes "ResourceCap consumed on 2026-04-24" and "cryptographically immutable" — strengthen by explicitly breaking down the 3-layer defense for reviewers who inspect the PackageRegistry.

---

### R4-I-02 — `sp_of` view aborts where `sp_settle` saturates (INFORMATIONAL / DX)
**Severity**: INFO (UX only; user funds are not at risk)
**Location**: lines 576-585 (`sp_of`) vs 242-249 (`sp_settle` saturation branch)

`sp_settle` intentionally saturates pending rewards at `u64::MAX` (WARNING 2 territory — asymptotic multi-decade accrual):
```move
let pending_one = (if (one_trunc) u64_max else raw_one) as u64;
```

The read-only `sp_of` view, however, performs raw `as u64` casts that **abort** on overflow:
```move
let p_one = (...(raw_one) as u256) / (snap_p as u256)) as u64;
```

Consequence: if a position's true pending rewards (in raw u256) exceed `u64::MAX`, the view aborts and any frontend reading `sp_of` for that address fails. The user can still successfully call `sp_claim` / `sp_withdraw` (both use `sp_settle`, which saturates).

**Realism**: WARNING (2) notes this is an asymptotic concern — requires ≥ ~1.8e19 raw units of pending rewards, which represents many decades of fee accrual at implausible volumes. Not a practical risk.

**Disclosure path**: document in `DEPLOYMENT.md` alongside WARNING (2) as a known frontend-abort edge. Frontend can catch the abort and display a saturation message pointing user to CLI `sp_claim`.

---

### R4-I-03 — MIN_DEBT enforced on added debt, not total (INFORMATIONAL)
**Severity**: INFO (UX limitation, no protocol risk)
**Location**: line 272 — `assert!(debt >= MIN_DEBT, E_DEBT_MIN);` inside `open_impl`

The MIN_DEBT = 1 ONE floor is applied to `debt` (the *added* amount in this call), not to the trove's *total* debt post-operation. Implication: a user with an existing 5 ONE trove cannot call `open_trove(coll_amt=0, debt=50_000_000)` to borrow an additional 0.5 ONE — they must borrow ≥ 1 ONE per call.

This was confirmed with prior auditors as a dust-prevention design choice (Kimi R1, Claude R1). The behavior is consistent with MIN_DEBT applying to "any borrow act", not "final position size".

**Minor surprise** for frontend DX: users wanting to incrementally increase debt by sub-1-ONE amounts must either (a) batch multiple +1-ONE borrows, or (b) add collateral only (via `add_collateral`, which has no MIN check other than amt > 0).

**Disclosure path**: document in frontend `About` page and Trove-page tooltip.

---

### R4-I-04 — Theoretical `coll_usd × 10000` u128 overflow at astronomical prices (INFORMATIONAL)
**Severity**: INFO (sub-realistic; no practical risk)
**Location**: lines 285, 414 (MCR check, LIQ_THRESHOLD check)

```move
assert!(coll_usd * 10000 >= MCR_BPS * (new_debt as u128), E_COLLATERAL);
```

With `coll` bounded to `u64::MAX ≈ 1.8e19`, `price_8dec()` bounded to ~`9.2e26` (worst case when abs_e=0 and raw=i64::MAX), `coll_usd = coll × price / 1e8` can reach ~`1.6e38`. Then `coll_usd × 10000 ≈ 1.6e42` which exceeds u128::MAX (~3.4e38).

**Realism**: requires simultaneous (a) holding >> all APT supply as collateral (1.8e11 APT ≈ 100× total APT supply) and (b) APT priced at >> $1e18 per coin. Impossible by many orders of magnitude.

Same pattern present in `liquidate` health check and `trove_health` view.

**Disclosure path**: document alongside WARNING (2) as an asymptotic u128 bound. Sibling finding to existing saturation warnings.

---

## Observations confirmed as non-findings

- **Reentrancy immunity**: both ONE and APT are non-dispatchable FAs (ONE: `create_primary_store_enabled_fungible_asset` with `option::none()` for hooks; APT: `EAPT_NOT_DISPATCHABLE` per Kimi R1). No FA hook path back into ONE module during deposit/withdraw.
- **SignerCapability leakage**: no code path reads `@ONE`'s `ResourceCap` besides `destroy_cap`. Cap is inaccessible post-destroy.
- **Liquity-P index math**: verified correct for both fee accrual (`route_fee_fa` indexing) and liquidation collateral distribution (`liquidate` reward_index_coll update uses OLD product_factor and OLD total_before — mathematically required).
- **Redemption target selection**: caller-specified behavior documented in WARNING (9). Previously raised as CRITICAL by Gemini R3, reclassified INFO/accepted at R3.1. Re-audit confirms no hidden attack surface.
- **Pyth confidence check**: `conf × 10000 ≤ MAX_CONF_BPS × raw` is scale-invariant (conf and raw share the price's expo). Correct per Pyth docs.
- **SP reset-on-empty (line 481-483)**: safe because `total_sp == 0` implies `sp_positions` table is empty (smart_table entries removed by sp_withdraw when `initial_balance == 0`).
- **route_fee_fa dust handling**: 0-amount early return via `destroy_zero`; sub-4-unit amounts skip burn but still route to SP pool or burn-on-empty correctly.
- **Bootstrap front-run immunity**: between publish and destroy_cap, external actors could call public entries but no entry exposes `ResourceCap` — no capability-theft path.

---

## Cumulative disclosure additions recommended for `DEPLOYMENT.md`

Add a new section **"Known post-mainnet documentation / UX notes (R4)"**:

1. WARNING (3) on-chain text over-states the zero-reserve CR boundary as "~5%"; actual boundary is "~2.5%" (R4-L-01).
2. Effective immutability is delivered by `destroy_cap` + `auth_key=0x0`, **not** by `upgrade_policy=compatible` (R4-I-01).
3. `sp_of` view aborts on u64 overflow where `sp_settle` saturates — asymptotic only, not reachable in practice (R4-I-02).
4. `MIN_DEBT` applies to added debt per call, not trove totals — incremental sub-1-ONE borrows are blocked (R4-I-03).
5. `coll_usd × 10000` sub-realistic u128 overflow bound (R4-I-04).

Add a new section **"Operational risks at bootstrap"** (R4-D-01):

- `total_sp = 0` at deploy means the genesis trove is un-liquidatable if APT crashes below the threshold.
- Monitor APT/USD and seed SP or close genesis trove before CR approaches 150%.

---

## Summary table

| ID | Severity | Class | Patch required? | Disclosure action |
|---|---|---|---|---|
| V-01 | — | Verification | — | Cited in report |
| V-02 | — | Verification | — | Cited in report |
| V-03 | — | Verification | — | Cited in report |
| V-04 | — | Verification | — | Cited in report |
| R4-L-01 | LOW | Doc precision | No (sealed) | DEPLOYMENT.md + frontend |
| R4-D-01 | DESIGN | Operational | No (design) | DEPLOYMENT.md operational section |
| R4-I-01 | INFO | Doc clarification | No | DEPLOYMENT.md emphasis |
| R4-I-02 | INFO | DX | No | DEPLOYMENT.md + frontend catch |
| R4-I-03 | INFO | UX | No | Frontend tooltip |
| R4-I-04 | INFO | Asymptotic bound | No | DEPLOYMENT.md note |

**R4 verdict: GREEN.** Zero CRITICAL/HIGH/MEDIUM findings. One LOW (documentation text), one DESIGN observation (bootstrap operational), four INFO. Deployed bytecode is cryptographically equivalent to reviewed source and all prior-round findings apply directly. No new attack surface identified.

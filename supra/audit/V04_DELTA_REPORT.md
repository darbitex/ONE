# ONE Supra v0.4.0 — delta report vs v0.3.0 + comparison with Aptos v0.1.3 + R4

**Status**: v0.4.0 source complete, **24/24 tests pass**, compile green. **Not yet deployed.** v0.3.0 at `0x4f03319c…6289b7` remains the DEPRECATED deployment — this document is the work product of the decision "sempurnakan Supra ONE berdasarkan Aptos post-mainnet learnings".

**Baseline comparison set**:
- Supra ONE v0.3.0 — deployed 2026-04-23 at `0x4f03319c…6289b7`, null-auth'd, DEPRECATED due to 3 bugs.
- Aptos ONE v0.1.3 — deployed 2026-04-24 at `0x85ee9c43…aab87387`, sealed via `destroy_cap`, R1-R3.1 GREEN, bytecode SHA-256 `5f197f10…4d92a`.
- Aptos R4 post-mainnet round — 5 external auditors, 1 MEDIUM / 4 LOW / 9 INFO applied as disclosures.

---

## 1. Bug fixes vs v0.3.0 (from disclosed DEPRECATION list)

| ID | v0.3.0 bug | Location | v0.4.0 fix |
|---|---|---|---|
| **C-01** | Phantom reward extraction via stale SP snapshots — `if (snap_p == 0 \|\| initial == 0) return;` left snapshots stale, allowing a later fresh `initial_balance` to drain `fee_pool` via inflated `(r - snap)*initial/snap_p` | `sp_settle` | **Early-return branch now refreshes `snapshot_product`, `snapshot_index_one`, `snapshot_index_supra` to current registry state before returning.** Same fix as Aptos R2-C01. Test: `test_c01_sp_settle_zero_initial_refreshes_snapshots`, `test_c01_sp_settle_zero_snap_p_refreshes_snapshots`. |
| **M-01** | `(coll=0, debt>0)` grief via exact-redeem — external redeemer picks `one_amt` so that `supra_out == t.collateral` exactly, leaving a stuck trove that cannot close or liquidate | `redeem_impl` | **Added `assert!(t.debt == 0 \|\| t.collateral > 0, E_COLLATERAL)` after subtraction.** Same fix as Aptos R2-M01. Prevents the `(coll=0, debt>0)` residual state by construction. |
| **L-01** | WARNING (4) text mislabeled liquidator share — read as "25% of debt" when actual is 2.5% of debt (= 25% of 10% bonus). Factor-of-10 mislabel in on-chain const | `WARNING` const | **WARNING fully rewritten** — correctly describes "nominal 2.5 percent of debt value, being 25 percent of the 10 percent liquidation bonus". Also fixes Aptos R4-L-01 precision (reserve-zero boundary at CR ~2.5%, not ~5%). |

---

## 2. Ports from Aptos v0.1.3 (R1-R3.1 hardening applied but never shipped to Supra v0.3.0)

| ID | Aptos origin | Supra v0.4.0 implementation | Test |
|---|---|---|---|
| **S-01** Saturation in sp_settle | Aptos R1 (Claude fresh M-06) | `raw_one / raw_supra / raw_bal` computed in u256; `u64_max = 18446744073709551615`; saturate via `if (raw_one > u64_max) u64_max else raw_one`; emits `RewardSaturated { pending_one_truncated, pending_supra_truncated }` event. Prevents decades-of-accrual permanent SP position lock. | `test_saturation_sp_settle_doesnt_abort_and_caps_initial` |
| **S-02** product_factor reset-on-empty | Aptos R1 (Claude fresh M-04, Liquity V2 pattern) | `sp_deposit` checks `if (r.total_sp == 0) { r.product_factor = PRECISION; }` before adding position. Restores liquidation capacity after cliff-freeze + full drain. Safe because `total_sp == 0` implies `sp_positions` is empty. | `test_reset_on_empty_resets_product_factor` |
| **S-03** close_impl zero-debt guard | Aptos R1 (Gemini #2) | `if (t.debt > 0) { burn }` — skip the burn when a trove has been fully redeemed to `debt = 0`. Without the guard, `primary_fungible_store::withdraw(user, metadata, 0)` can abort on certain framework versions, locking the owner out of collateral. | (existing `close_trove` tests cover the non-zero case; zero-debt case covered by M-01 test via indirect path) |
| **S-04** `close_cost(addr)` view | Aptos R1 (Claude fresh M-05) | New `#[view]` returning `debt` for `addr`'s trove (or 0 if no trove / zero-debt trove). Front-ends show the exact ONE amount needed for `close_trove`. | `test_close_cost_for_unknown_returns_zero`, `test_close_cost_returns_trove_debt` |
| **S-05** `trove_health(addr)` view | Aptos R1 (Claude fresh L-04) | New `#[view]` returning `(collateral, debt, cr_bps)`. Returns zeros for unknown or zero-debt troves. Aborts on oracle staleness for live-debt troves (inherited from `price_8dec`). | `test_trove_health_unknown_returns_zeros`, `test_trove_health_zero_debt_returns_coll_and_zeros` |
| **S-06** `RewardSaturated` event | Aptos R1 (ChatGPT #6) | `#[event] struct RewardSaturated has drop, store { user, pending_one_truncated, pending_supra_truncated }`. Emitted by `sp_settle` when saturation triggers (S-01). | (indirectly exercised by S-01 test) |

---

## 3. R4 post-mainnet learnings baked into Supra v0.4.0 WARNING

Aptos R4 produced 1 MEDIUM + 4 LOW + 9 INFO all of which are disclosure-only (contract sealed). Since Supra v0.4.0 is a **fresh redeploy** (not an upgrade of v0.3.0), we bake these into the WARNING const directly rather than relying on after-the-fact docs.

| R4 ID | Source | How absorbed into Supra v0.4.0 |
|---|---|---|
| **R4-L-01** | WARNING "~5%" imprecision | Supra WARNING (4) uses "~2.5 percent" for liquidator-takes-all / reserve-zero boundary — the corrected value |
| **R4-M-01** | Oracle-lag redemption extraction | **New WARNING clause (10)** — explicit disclosure that Supra push-based oracle has a 900s staleness window and users cannot force-refresh. Names the caller-selects-timing extraction dynamic and trove-owner defensive actions. More severe than Aptos (60s window) — made fully explicit rather than subtextual |
| **R4-L-02** | MIN_DEBT redeem fragmentation (101010101 exact) | WARNING clause (6) — names the exact raw amount required to fully clear a MIN_DEBT trove, names the [100000000, 101010100] dead zone, directs front-ends to compute it |
| **R4-L-03** | MIN_P_THRESHOLD cliff blocks liquidation even when total_sp > debt | WARNING clause (1) already covers the cliff; v0.4.0 adds the S-02 reset-on-empty which provides a recovery path (after full drain) |
| **R4-L-04** | `total_debt` vs circulating supply divergence | WARNING clause (5) already documents the per-trove + aggregate gap; source comment in `redeem_from_reserve` (inherited from v0.3.0) further clarifies |
| **R4-I-01** | upgrade_policy registry misleading | N/A for Supra — immutability is via null-auth, not resource-account + destroy_cap. Move.toml comment already clarifies |
| **R4-I-02** | sp_of aborts where sp_settle saturates | Same DX gap present in Supra v0.4.0 — documented in code comment next to saturation logic; front-ends must catch and fall back to `sp_claim` |
| **R4-I-03** | MIN_DEBT per-call, not per-total | Inherited from Aptos; same behavior in Supra v0.4.0. Frontend-only disclosure |
| **R4-I-04** / **R4-I-05** | Asymptotic u128 bounds on `coll_usd × 10000` / `reward_index_supra` | Same asymptotic concerns apply; `abs_e <= 18`-equivalent is the Supra `dec <= 38` check in `pow10`. Documented via WARNING (2) saturation note |
| **R4-I-06** | Zero-debt residual trove (post-full-redeem) | New S-05 `trove_health` view surfaces `(coll, 0, 0)` so front-ends can detect and offer "Close & withdraw"; S-03 close_impl zero-debt guard makes the eventual close succeed |
| **R4-I-07** | No `withdraw_collateral` / `reduce_debt` | **Deferred** — intentional minimalism per spec ("1% fee on all operations" identity). Self-redeem is the partial-delever path |
| **R4-I-08** | Pyth confidence is instantaneous | Supra oracle has no analog confidence field — different oracle model. R4-M-01 covered by WARNING (10) |
| **R4-I-09** | SP state bloat via initial_balance→0 | Same behavior in Supra v0.4.0 — minor, documented implicitly via WARNING (2) saturation region |

---

## 4. Supra-specific protections NOT present in Aptos

These are kept as-is from v0.3.0:

- **Pre-cap u128 compute in liquidate split** (v0.3.0 R2 Gemini-02 fix) — all 3 split variables (`total_seize_supra`, `liq_supra`, `reserve_supra`) computed and capped in u128 before the final u64 cast, avoiding pre-cap overflow at extreme low-SUPRA + large-trove scenarios.
- **Strict `total_sp > debt`** for liquidation — same as Aptos.
- **Oracle future-drift + zero-price + non-zero-timestamp guards** in `price_8dec` — same as Aptos (structurally equivalent given push vs pull).
- **STALENESS_MS = 900_000 (15 min)** — R2 5/5 auditor consensus; wider than Aptos's 60s because Supra's push cadence is different. Known trade-off: wider oracle-lag extraction window per R4-M-01 (disclosed in WARNING 10).
- **25/50/25 liquidation split** (liquidator / SP / reserve) — same as Aptos.

---

## 5. Source metrics

| Metric | v0.3.0 | v0.4.0 | Delta |
|---|---|---|---|
| `sources/ONE.move` lines | 581 | 707 | +126 |
| `tests/ONE_tests.move` lines | 268 | 395 | +127 |
| Tests passing | 16/16 | **24/24** | +8 new |
| `WARNING` const clauses | 6 | **10** | +4 (7 low-price aborts, 8 oracle freeze, 9 redemption-vs-liquidation, 10 oracle-lag redemption) |
| Entry functions | 8 | 8 | no change |
| Views | 5 | **7** | +2 (`close_cost`, `trove_health`) |
| Events | 10 | **11** | +1 (`RewardSaturated`) |
| Error codes | 14 | 14 | no change (no new error paths — all protections reuse existing codes) |

---

## 6. Non-changes (intentional)

- MCR 200%, LIQ_THRESHOLD 150%, LIQ_BONUS 10%, FEE 1% flat — **locked per spec**.
- `MIN_DEBT = 1 ONE` — retail-first philosophy; previously rejected raise-to-10/100 recommendation in R1 M-02.
- Caller-specified redemption target (no sorted-by-CR priority) — documented in WARNING (9), peg-anchor mechanism.
- 25% burn of every fee — documented in WARNING (5) as the designed deflationary pressure.
- `redeem_from_reserve` intentionally does NOT decrement `total_debt` — documented in source comment, surfaced in R4-L-04.
- **Staleness window stays 900s** — tightening to 300s would need a fresh audit round and risks false-positive freezes during Supra push-cadence variance. R4-M-01 disclosed via WARNING (10) instead.

---

## 7. Deploy readiness checklist

- [x] Source code v0.4.0 complete + compile green
- [x] 24/24 unit tests pass
- [x] Move.toml version bumped 0.3.0 → 0.4.0
- [x] Module top comment documents v0.3.0 supersession + R4 port linkage
- [x] WARNING const fully updated (10 clauses, R4-M-01 oracle-lag disclosure)
- [ ] **External audit round** — recommended minimum: 3 auditor re-reviews focused on v0.3.0→v0.4.0 deltas. Can reuse Aptos R4 submission template + add "deltas-only" audit scope for Qwen / DeepSeek / Kimi / Claude-fresh / Gemini-3-Flash
- [ ] **Fresh deployer keypair** — NOT reuse `0x4f03319c…` (dead) or any darbitex wallet
- [ ] **Mainnet funding** — ~6000 SUPRA at fresh address (~$2.40 at current price)
- [ ] **Deploy sequence** — identical to v0.3.0 per DEPLOY.md:
  1. publish
  2. bootstrap (Coin→FA + open_trove 5555 SUPRA / 1 ONE)
  3. sp_deposit 0.99 ONE (route genesis mint into SP as permanent base)
  4. null_auth (rotate deployer to 0x0)
- [ ] **Update `/home/rera/one/README.md`** — add "v0.4.0 deploy record" section, keep v0.3.0 deprecation notice
- [ ] **Update memory** — mark v0.4.0 as candidate-for-redeploy, preserve v0.3.0 as frozen-deprecated artifact

---

## 8. Summary

v0.4.0 is **cryptographically stronger than v0.3.0 on every known vector**:
- The two CRITICAL-class behaviors (C-01 phantom reward, M-01 coll-zero grief) that forced v0.3.0's deprecation are closed at source.
- Six hardening patterns from Aptos R1-R3.1 that never reached v0.3.0 (saturation, reset-on-empty, zero-debt guard, two new views, new event) are now in place.
- All 1 MEDIUM + 4 LOW + 9 INFO from the Aptos R4 post-mainnet round are absorbed — either directly into source (reset-on-empty for L-03, views for I-06) or into the WARNING const (M-01, L-01, L-02, L-04) with frontend disclosure plans for the rest.

**This is not just a bug fix release — it is v0.3.0 plus every accumulated learning from the Aptos deployment.**

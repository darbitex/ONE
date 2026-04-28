# ONE — immutable stablecoin

> ## ⚠️ Sui chain DEPRECATED — successor: [`darbitex/D`](https://github.com/darbitex/D)
>
> ONE Sui v0.1.0 (`0x9f39a102…`) remains live + sealed and supports wind-down (close_trove, sp_withdraw, redeem_from_reserve). **No new mints recommended.** All new Sui activity should use **D v0.2.0** at [`darbitex/D`](https://github.com/darbitex/D), which fixes V1's reward-dilution-on-donation issue and improves depositor yield (25/75 → 10/90 fee split, agnostic donation primitive).
>
> Aptos and Supra ONE remain canonical and continue to be the recommended deployments on those chains.
>
> See [`darbitex/D` README](https://github.com/darbitex/D/blob/main/README.md) and [`REDEPLOY_FROM_ONE.md`](https://github.com/darbitex/D/blob/main/REDEPLOY_FROM_ONE.md) for migration rationale.

---

Multi-chain immutable stablecoin.

- `sui/` — Sui mainnet, **v0.1.0 SEALED + DEPRECATED** at `0x9f39a102…` (successor: [`darbitex/D`](https://github.com/darbitex/D))
- `supra/` — Supra L1, **v0.4.0 LIVE + SEALED** at `0x2365c948…eafda5c90f`. (v0.3.0 at `0x4f03319c…` is DEPRECATED, see below.)
- `aptos/` — Aptos mainnet, v0.1.3 LIVE + SEALED at `0x85ee9c43…aab87387`. See `aptos/DEPLOYMENT.md`.

---

## `supra/v0.4.0` — LIVE on Supra mainnet, sealed

Deployed 2026-04-24. Fresh empty state (no bootstrap trove, no SP seed) — any user can open the first trove. Patches all three v0.3.0 bugs at source, ports Aptos R1-R3.1 hardening, bakes the Aptos R4 post-mainnet round's findings into the on-chain WARNING.

| | |
|---|---|
| Package | `0x2365c9489f7d851ccbfe07c881f8c203a11558760202f45b999c98eafda5c90f` |
| ONE FA metadata | `0xef06314bfb6a3478d24623ba0f57eb5a09291aef3ea5c1abbe4f5f7b0cf28c22` |
| Collateral | SUPRA native (pair id 500 on Supra oracle `0xe3948c9e…4150`) |
| Publish tx | `0x052ba1e8c2de1824fc18a6e2028a0fa0bd981608b35c9a642c3a1b02d962c264` |
| Null-auth tx | `0xb3300786dafdecc9dba628b98d700380a0c7f995f52fcb1762940783cd9b4818` |
| Deployer (DEAD, unsignable) | same as package address |
| auth_key | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| Source tag | `v0.4.0-supra` |

**Full deployment record**: [`supra/DEPLOYMENTS.md`](supra/DEPLOYMENTS.md)
**Delta vs v0.3.0 + Aptos comparison matrix**: [`supra/audit/V04_DELTA_REPORT.md`](supra/audit/V04_DELTA_REPORT.md)

### What v0.4.0 changed vs v0.3.0

- **3 bug fixes at source** (C-01 phantom reward, M-01 coll-zero grief, L-01 WARNING mislabel).
- **6 Aptos R1-R3.1 hardening ports**: sp_settle saturation (prevents u64-overflow SP lock), product_factor reset-on-empty, zero-debt close guard, `close_cost(addr)` + `trove_health(addr)` views, `RewardSaturated` event.
- **Aptos R4 post-mainnet learnings**: 4 new WARNING clauses (7 low-price aborts, 8 permanent oracle freeze + oracle-free escape hatches, 9 redemption vs liquidation, 10 oracle-lag redemption per R4-M-01). 6 → 10 clauses total.
- 581 → 707 source lines, 16 → 24 tests green.

---

## `supra/v0.3.0` — DEPRECATED (2026-04-23)

**Deployment**: `0x4f03319c1ef88680b1209a2e58ed7dafa4a3b1dea761ecbb730011d41e6289b7` (Supra mainnet, null-auth'd).

**Status**: on-chain historical record, **DO NOT USE**. Superseded by v0.4.0 above. Three bugs identified in R2 audit of the Aptos fork also apply to the deployed v0.3.0 source. The package cannot be patched because its auth_key was set to `0x0` at deploy time.

### Known vulnerabilities (all fixed in v0.4.0)

1. **C-01 (CRITICAL) — phantom reward extraction via stale snapshots.**
   Location: `sp_settle` line 194 (`if (snap_p == 0 || initial == 0) return;`).
   An attacker can deposit a tiny SP balance, wait for liquidations to truncate their effective to zero, then redeposit later while the reward indices have grown. The fresh `initial_balance` pairs with stale `snapshot_product` and `snapshot_index_*`, inflating the next `pending_one` calculation. Single-tx drains of the ONE fee_pool scaling with the staleness of the snap — simulated at 61× the redeposit amount under modest parameters.

2. **M-01 (MEDIUM) — unliquidatable dust trove grief.**
   Location: `redeem_impl` line 291 (`assert!(t.collateral >= supra_out, ...);`).
   The non-strict `>=` allows an external redeemer to drain a victim trove's collateral to exactly zero while leaving `debt > 0`. The resulting `(coll=0, debt>0)` trove cannot be closed (framework asserts withdraw amount > 0) nor liquidated (same abort). Bad debt accumulates permanently in `total_debt`. Attacker cost = 1% redemption fee on drained amount.

3. **L-01 (LOW) — WARNING text mislabels liquidator share.**
   The on-chain `WARNING` const describes the liquidator as receiving "25 percent" nominal. Actual share is 2.5% of debt value (25% of the 10% liquidation bonus). Factor-of-10 mislabel, immutable.

### Current exposure

The only state in v0.3.0 is the deployer's bootstrap trove (5555 SUPRA / 1 ONE) plus 0.99 ONE in the SP base. No external user funds are at risk. The `fee_pool` is effectively empty, so C-01 has no economic target.

### Recommendation

Interact exclusively with v0.4.0 at `0x2365c948…eafda5c90f`. v0.3.0 stays on-chain as a read-only record.

---

## `aptos/` — LIVE on mainnet, sealed

Aptos fork, fully audited through R1→R3.1 (Gemini + Claude both GREEN), deployed 2026-04-24, immutability sealed via `destroy_cap` at tx `0x529f06db...`.

| | |
|---|---|
| Package | `0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387` |
| ONE FA metadata | `0xee5ebaf6ff851955cccaa946f9339bab7f7407d72c6673b029576747ba3fadc4` |
| Collateral | APT (Aptos native) |
| Oracle | Pyth APT/USD (cryptographically immutable, auth_key = 0x0) |
| Sealed | `is_sealed() = true` |

Full deploy record at `aptos/DEPLOYMENT.md`. Audit trail at `aptos/audit/`.

---

## License

See `LICENSE`.

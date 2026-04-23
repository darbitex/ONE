# ONE — immutable stablecoin

Two chains, one name.

- `supra/` — Supra L1, v0.3.0, **DEPRECATED (vulnerable, do not use)**. See below.
- `aptos/` — Aptos mainnet, v0.1.3, **LIVE + SEALED** (immutable). See `aptos/DEPLOYMENT.md`.

---

## `supra/` — DO NOT USE

**Deployment**: `0x4f03319c1ef88680b1209a2e58ed7dafa4a3b1dea761ecbb730011d41e6289b7` (Supra mainnet, null-auth'd = immutable, no upgrade path).

**Status**: vulnerable. Three bugs identified in R2 audit of the Aptos fork that also apply to the deployed Supra source. The package cannot be patched because its auth_key was set to `0x0` at deploy time.

### Known vulnerabilities

1. **C-01 (CRITICAL) — phantom reward extraction via stale snapshots.**
   Location: `sp_settle` line 194 (`if (snap_p == 0 || initial == 0) return;`).
   An attacker can deposit a tiny SP balance, wait for liquidations to truncate their effective to zero, then redeposit later while the reward indices have grown. The fresh `initial_balance` pairs with stale `snapshot_product` and `snapshot_index_*`, inflating the next `pending_one` calculation. Single-tx drains of the ONE fee_pool scaling with the staleness of the snap — simulated at 61× the redeposit amount under modest parameters.

2. **M-01 (MEDIUM) — unliquidatable dust trove grief.**
   Location: `redeem_impl` line 291 (`assert!(t.collateral >= supra_out, ...);`).
   The non-strict `>=` allows an external redeemer to drain a victim trove's collateral to exactly zero while leaving `debt > 0`. The resulting `(coll=0, debt>0)` trove cannot be closed (framework asserts withdraw amount > 0) nor liquidated (same abort). Bad debt accumulates permanently in `total_debt`. Attacker cost = 1% redemption fee on drained amount.

3. **L-01 (LOW) — WARNING text mislabels liquidator share.**
   The on-chain `WARNING` const describes the liquidator as receiving "25 percent" nominal. Actual share is 2.5% of debt value (25% of the 10% liquidation bonus). Factor-of-10 mislabel, immutable.

### Current exposure

As of 2026-04-23, the only state in the deployment is the deployer's bootstrap trove (5555 SUPRA / 1 ONE) plus 0.99 ONE in the SP base. No external user funds are known to be at risk. The `fee_pool` is effectively empty, so C-01 has no economic target at present. Exposure grows with any future usage.

### Recommendation

Do not open a trove or deposit to SP on this package. A patched `v0.4.0` will be deployed at a new address if traction justifies it. This deployment will remain on-chain as a read-only record.

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

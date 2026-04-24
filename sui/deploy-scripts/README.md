# ONE Sui — Deploy SOP

**Goal:** Publish ONE package to Sui mainnet + seal permanently in two transactions.

**Philosophy:** Between Tx 1 and Tx 2, the package is upgradeable by the deployer. Users should NOT interact until `is_sealed(&reg) == true` is confirmed. Run Tx 2 immediately after Tx 1 commits.

## Prerequisites

- Sui CLI active env = `mainnet` (verify with `sui client envs`)
- Active address = `0x6915bc38bccd03a6295e9737143e4ef3318bcdc75be80a3114f317633bdd3304`
- Gas balance ≥ 0.6 SUI (run `sui client gas`)
- Build passes: `sui move build --path ..`
- Tests pass: `sui move test --path ..`

## Tx 1 — publish

```bash
./publish.sh
```

This wraps `sui client publish --gas-budget 500000000` in the correct dir (parent of `deploy-scripts/`). On success it prints the following to `publish-output.json`:

- `package_id` — the newly-published package address (e.g. `0xABCD...`)
- `registry_id` — the shared `Registry` object
- `origin_cap_id` — `OriginCap` owned by deployer
- `upgrade_cap_id` — `0x2::package::UpgradeCap` owned by deployer
- `currency_id` — `Currency<ONE>` sitting as TTO at `0xc` (CoinRegistry singleton)
- `currency_version` + `currency_digest` — needed to construct `Receiving<Currency<ONE>>` in Tx 2

Script extracts these from the tx effects and writes `publish-output.json`.

## Tx 2 — seal (single PTB)

```bash
npm install
npx ts-node seal.ts
```

Reads `publish-output.json`, builds a single PTB with:

1. `0x2::coin_registry::finalize_registration<PACKAGE_ID::ONE::ONE>(&mut 0xc, Receiving<Currency<ONE>>(currency_id, version, digest), ctx)` — promotes Currency<ONE> to shared
2. `PACKAGE_ID::ONE::destroy_cap(OriginCap, &mut Registry, UpgradeCap, &Clock@0x6, ctx)` — consumes both caps, `make_immutable`, flips `sealed = true`

Signs with the keypair at `~/.sui/sui_config/sui.keystore` (active address).

Executes and waits for finality. On success, prints:

- `SEALED: true` confirmation
- Updated Registry state
- Package immutable verification

Appends to `publish-output.json` under `seal_tx_digest` + `sealed_at_ms`.

## Post-seal verification

```bash
./verify-sealed.sh
```

Reads `publish-output.json`, queries chain for:

- `Registry.sealed == true`
- `OriginCap` no longer owned by deployer (consumed)
- `UpgradeCap` consumed (package `0x2::package::make_immutable` emitted)
- `Currency<ONE>` promoted to shared object (derived address)

## Abort / recovery

- If Tx 1 fails: no state change. Retry.
- If Tx 1 succeeds but Tx 2 fails: **do not announce or invite users**. Re-run Tx 2. The deploy window is the only unsafe period.
- If Tx 2 aborts mid-flight (e.g., `make_immutable` error): Move atomicity reverts all — OriginCap + UpgradeCap still owned by deployer, `Registry.sealed == false`. Retry Tx 2.

## Never do any of the following

- Announce the deployed package address publicly before Tx 2 confirms.
- Transfer OriginCap to any other address.
- Call any Registry entry function between Tx 1 and Tx 2 yourself (except the seal).
- Merge Tx 1 + Tx 2 into a single script that auto-retries without manual verification — if Tx 1 state is ambiguous, STOP and inspect.

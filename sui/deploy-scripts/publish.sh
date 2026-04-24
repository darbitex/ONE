#!/usr/bin/env bash
# ONE Sui — Tx 1 publish
#
# Publishes the ONE package to Sui mainnet. Extracts created object IDs
# (Registry, OriginCap, UpgradeCap, Currency<ONE>) from the tx effects
# and writes them to publish-output.json for the seal script to consume.
#
# DOES NOT SEAL. Run seal.ts immediately after this.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"

ACTIVE_ENV=$(sui client active-env 2>/dev/null)
if [ "$ACTIVE_ENV" != "mainnet" ] && [ "$ACTIVE_ENV" != "0" ]; then
    echo "ERROR: sui client active-env is '$ACTIVE_ENV', expected 'mainnet'"
    echo "Run: sui client switch --env mainnet  (or whichever alias maps to mainnet fullnode)"
    exit 1
fi

ACTIVE_ADDR=$(sui client active-address)
EXPECTED_ADDR="0x6915bc38bccd03a6295e9737143e4ef3318bcdc75be80a3114f317633bdd3304"
if [ "$ACTIVE_ADDR" != "$EXPECTED_ADDR" ]; then
    echo "WARNING: active address is $ACTIVE_ADDR, expected $EXPECTED_ADDR"
    read -p "Proceed anyway? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "=== Pre-flight ==="
echo "  Active env:  $ACTIVE_ENV"
echo "  Active addr: $ACTIVE_ADDR"
sui client gas | head -20

echo
echo "=== sui move build (sanity) ==="
(cd "$PKG_DIR" && sui move build 2>&1 | tail -5)

echo
echo "=== Publishing... ==="
OUTPUT_FILE="$SCRIPT_DIR/publish-raw.json"
(cd "$PKG_DIR" && sui client publish --gas-budget 500000000 --skip-dependency-verification --json) | tee "$OUTPUT_FILE"

if [ ! -s "$OUTPUT_FILE" ]; then
    echo "ERROR: publish output is empty"
    exit 1
fi

echo
echo "=== Extracting object IDs ==="

python3 <<PY
import json
import sys

with open("$OUTPUT_FILE") as f:
    data = json.load(f)

effects = data.get("effects", {})
if effects.get("status", {}).get("status") != "success":
    print(f"ERROR: publish status = {effects.get('status')}")
    sys.exit(1)

tx_digest = data.get("digest")
print(f"  tx_digest: {tx_digest}")

package_id = None
registry_id = None
origin_cap_id = None
upgrade_cap_id = None
currency_id = None
currency_version = None
currency_digest = None

for change in data.get("objectChanges", []):
    ctype = change.get("type")
    if ctype == "published":
        package_id = change.get("packageId")
    elif ctype == "created":
        obj_type = change.get("objectType", "")
        obj_id = change.get("objectId")
        version = change.get("version")
        digest = change.get("digest")
        if obj_type.endswith("::ONE::Registry"):
            registry_id = obj_id
        elif obj_type.endswith("::ONE::OriginCap"):
            origin_cap_id = obj_id
        elif obj_type == "0x2::package::UpgradeCap":
            upgrade_cap_id = obj_id
        elif "Currency<" in obj_type and "::ONE::ONE>" in obj_type:
            currency_id = obj_id
            currency_version = version
            currency_digest = digest

out = {
    "tx_digest": tx_digest,
    "package_id": package_id,
    "registry_id": registry_id,
    "origin_cap_id": origin_cap_id,
    "upgrade_cap_id": upgrade_cap_id,
    "currency_id": currency_id,
    "currency_version": currency_version,
    "currency_digest": currency_digest,
    "active_addr": "$ACTIVE_ADDR",
    "published_at_epoch_ms": effects.get("executedEpoch"),
}

missing = [k for k, v in out.items() if v is None and k != "published_at_epoch_ms"]
if missing:
    print(f"ERROR: missing IDs in output: {missing}")
    print("Full raw output saved to $OUTPUT_FILE for manual inspection.")
    sys.exit(2)

with open("$SCRIPT_DIR/publish-output.json", "w") as f:
    json.dump(out, f, indent=2)

print("  package_id:     ", package_id)
print("  registry_id:    ", registry_id)
print("  origin_cap_id:  ", origin_cap_id)
print("  upgrade_cap_id: ", upgrade_cap_id)
print("  currency_id:    ", currency_id)
print("  currency_ver:   ", currency_version)
print("  currency_digest:", currency_digest)
print()
print("Wrote $SCRIPT_DIR/publish-output.json")
PY

echo
echo "=== DONE — Tx 1 published ==="
echo
echo "NEXT: run seal immediately. The package is NOT sealed yet."
echo "  cd $SCRIPT_DIR"
echo "  npm install    # first time only"
echo "  npx ts-node seal.ts"
echo
echo "DO NOT invite users to interact until seal.ts confirms SEALED: true."

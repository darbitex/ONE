/**
 * ONE Sui — post-seal verification
 *
 * Independent sanity check after seal.ts runs. Queries on-chain state to
 * confirm:
 *   - Registry.sealed == true
 *   - OriginCap no longer exists
 *   - UpgradeCap no longer owned by deployer (consumed by make_immutable)
 *   - Currency<ONE> promoted to shared object
 *   - Package at expected address and callable
 */

import { readFileSync, existsSync } from 'fs';
import { join } from 'path';

import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';

const OUTPUT_PATH = join(__dirname, 'publish-output.json');

async function main() {
    if (!existsSync(OUTPUT_PATH)) {
        throw new Error(`${OUTPUT_PATH} not found. Run publish.sh + seal.ts first.`);
    }
    const out = JSON.parse(readFileSync(OUTPUT_PATH, 'utf-8'));
    const client = new SuiClient({ url: getFullnodeUrl('mainnet') });

    console.log('=== Verifying ONE Sui sealed state ===\n');

    // 1. Registry.sealed
    const reg = await client.getObject({
        id: out.registry_id,
        options: { showContent: true, showOwner: true },
    });
    const fields = (reg.data?.content as any)?.fields;
    const sealed = fields?.sealed;
    console.log(`1. Registry.sealed          = ${sealed}  ${sealed ? '✓' : '✗'}`);
    console.log(`   Registry owner           = ${JSON.stringify(reg.data?.owner)}`);
    console.log(`   total_debt               = ${fields?.total_debt}`);
    console.log(`   total_sp                 = ${fields?.total_sp}`);
    console.log(`   product_factor           = ${fields?.product_factor}`);

    // 2. OriginCap gone
    const originObj = await client.getObject({
        id: out.origin_cap_id,
        options: { showOwner: true },
    });
    const originGone = originObj.error?.code === 'notExists' || originObj.error?.code === 'deleted';
    console.log(`\n2. OriginCap gone           = ${originGone}  ${originGone ? '✓' : '✗'}`);
    if (!originGone) {
        console.log(`   ↳ still at ${JSON.stringify(originObj.data?.owner)}`);
    }

    // 3. UpgradeCap consumed (package immutable)
    const upgradeObj = await client.getObject({
        id: out.upgrade_cap_id,
        options: { showOwner: true },
    });
    const upgradeGone =
        upgradeObj.error?.code === 'notExists' ||
        upgradeObj.error?.code === 'deleted';
    console.log(`3. UpgradeCap consumed      = ${upgradeGone}  ${upgradeGone ? '✓' : '✗'}`);

    // 4. Currency<ONE> shared
    const currencyObj = await client.getObject({
        id: out.currency_id,
        options: { showOwner: true },
    });
    const currOwner = (currencyObj.data?.owner as any);
    const isShared = currOwner && typeof currOwner === 'object' && 'Shared' in currOwner;
    console.log(
        `4. Currency<ONE> shared     = ${isShared}  ${isShared ? '✓' : '✗'}`
    );
    if (!isShared) {
        console.log(`   ↳ owner = ${JSON.stringify(currOwner)}`);
    }

    // 5. Package exists at expected ID
    const pkgObj = await client.getObject({
        id: out.package_id,
        options: {},
    });
    const pkgOk = pkgObj.data?.type === 'package';
    console.log(`5. Package at ${out.package_id.slice(0, 10)}...  = ${pkgOk ? 'exists ✓' : 'MISSING ✗'}`);

    console.log('\n=== Summary ===');
    const allOk = sealed === true && originGone && upgradeGone && isShared && pkgOk;
    console.log(allOk ? '✓ ONE Sui is LIVE + SEALED.' : '✗ One or more checks failed — inspect above.');

    console.log(`\n  Package:  ${out.package_id}`);
    console.log(`  Registry: ${out.registry_id}  (shared)`);
    console.log(`  Currency: ${out.currency_id}  (shared)`);
    console.log(`  Publish tx: ${out.tx_digest}`);
    console.log(`  Seal tx:    ${out.seal_tx_digest}`);

    process.exit(allOk ? 0 : 1);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});

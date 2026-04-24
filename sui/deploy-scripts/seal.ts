/**
 * ONE Sui — Tx 2 seal PTB
 *
 * Single PTB with two move calls:
 *   1. 0x2::coin_registry::finalize_registration<PKG::ONE::ONE>(
 *        &mut CoinRegistry@0xc,
 *        Receiving<Currency<ONE>>(currency_id, version, digest),
 *      )
 *   2. PKG::ONE::destroy_cap(OriginCap, &mut Registry, UpgradeCap, &Clock@0x6)
 *
 * After success: package is permanently sealed via sui::package::make_immutable,
 * Registry.sealed = true, OriginCap deleted, UpgradeCap consumed.
 *
 * Reads publish-output.json from the previous publish.sh run.
 * Appends seal_tx_digest + sealed_at_ms on success.
 */

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { homedir } from 'os';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { decodeSuiPrivateKey } from '@mysten/sui/cryptography';
import { fromBase64 } from '@mysten/sui/utils';

const SCRIPT_DIR = __dirname;
const OUTPUT_PATH = join(SCRIPT_DIR, 'publish-output.json');

const COIN_REGISTRY_OBJECT = '0x000000000000000000000000000000000000000000000000000000000000000c';
const CLOCK_OBJECT = '0x0000000000000000000000000000000000000000000000000000000000000006';

interface PublishOutput {
    tx_digest: string;
    package_id: string;
    registry_id: string;
    origin_cap_id: string;
    upgrade_cap_id: string;
    currency_id: string;
    currency_version: string | number;
    currency_digest: string;
    active_addr: string;
    published_at_epoch_ms?: string;
    seal_tx_digest?: string;
    sealed_at_ms?: number;
}

function loadKeypairFromSuiConfig(expectedAddr: string): Ed25519Keypair {
    const keystorePath = join(homedir(), '.sui', 'sui_config', 'sui.keystore');
    if (!existsSync(keystorePath)) {
        throw new Error(`Sui keystore not found at ${keystorePath}`);
    }
    const keys: string[] = JSON.parse(readFileSync(keystorePath, 'utf-8'));
    for (const encoded of keys) {
        let kp: Ed25519Keypair;
        try {
            if (encoded.startsWith('suiprivkey')) {
                // Bech32 format
                const { schema, secretKey } = decodeSuiPrivateKey(encoded);
                if (schema !== 'ED25519') continue;
                kp = Ed25519Keypair.fromSecretKey(secretKey);
            } else {
                // Legacy base64 format: [1-byte scheme | 32-byte secret]
                const raw = fromBase64(encoded);
                if (raw.length !== 33) continue;
                const scheme = raw[0];
                if (scheme !== 0x00) continue; // 0x00 = ED25519
                kp = Ed25519Keypair.fromSecretKey(raw.slice(1));
            }
        } catch {
            continue;
        }
        if (kp.getPublicKey().toSuiAddress() === expectedAddr) {
            return kp;
        }
    }
    throw new Error(
        `No ED25519 keypair in ${keystorePath} matches active address ${expectedAddr}`
    );
}

async function main() {
    if (!existsSync(OUTPUT_PATH)) {
        throw new Error(
            `publish-output.json not found at ${OUTPUT_PATH}. Run ./publish.sh first.`
        );
    }

    const out: PublishOutput = JSON.parse(readFileSync(OUTPUT_PATH, 'utf-8'));

    console.log('=== Loaded publish-output.json ===');
    console.log(`  package_id:     ${out.package_id}`);
    console.log(`  registry_id:    ${out.registry_id}`);
    console.log(`  origin_cap_id:  ${out.origin_cap_id}`);
    console.log(`  upgrade_cap_id: ${out.upgrade_cap_id}`);
    console.log(`  currency_id:    ${out.currency_id}`);
    console.log(`  currency_ver:   ${out.currency_version}`);
    console.log(`  currency_digest:${out.currency_digest}`);

    if (out.seal_tx_digest) {
        console.log(`\nALREADY SEALED at tx ${out.seal_tx_digest}. Exiting.`);
        return;
    }

    const client = new SuiClient({ url: getFullnodeUrl('mainnet') });
    const keypair = loadKeypairFromSuiConfig(out.active_addr);
    console.log(`\n  signer: ${keypair.getPublicKey().toSuiAddress()}`);

    // ----- Build PTB -----
    const tx = new Transaction();

    // Call 1: finalize_registration<PKG::ONE::ONE>(&mut CoinRegistry, Receiving<Currency<ONE>>)
    // Type argument is the ONE coin type
    const oneType = `${out.package_id}::ONE::ONE`;

    // Receiving<T> arg form: tx.receivingRef({objectId, version, digest})
    const currencyReceiving = tx.receivingRef({
        objectId: out.currency_id,
        version: String(out.currency_version),
        digest: out.currency_digest,
    });

    tx.moveCall({
        target: '0x2::coin_registry::finalize_registration',
        typeArguments: [oneType],
        arguments: [
            tx.object(COIN_REGISTRY_OBJECT),
            currencyReceiving,
        ],
    });

    // Call 2: destroy_cap(OriginCap, &mut Registry, UpgradeCap, &Clock)
    tx.moveCall({
        target: `${out.package_id}::ONE::destroy_cap`,
        arguments: [
            tx.object(out.origin_cap_id),
            tx.object(out.registry_id),
            tx.object(out.upgrade_cap_id),
            tx.object(CLOCK_OBJECT),
        ],
    });

    tx.setGasBudget(100_000_000); // 0.1 SUI cap; actual should be ~0.01-0.05

    console.log('\n=== Dry-run (read-only simulation) ===');
    const dry = await client.devInspectTransactionBlock({
        transactionBlock: tx,
        sender: out.active_addr,
    });
    if (dry.effects.status.status !== 'success') {
        console.error('DRY-RUN FAILED:', JSON.stringify(dry.effects.status, null, 2));
        console.error('Full dry-run result:');
        console.error(JSON.stringify(dry, null, 2));
        process.exit(1);
    }
    console.log(`  dry-run OK. Estimated gas: ~${dry.effects.gasUsed.computationCost}`);

    // ----- Confirm before sending -----
    console.log('\n=== Ready to execute ===');
    console.log(`This will PERMANENTLY SEAL the ONE package at ${out.package_id}.`);
    console.log(`Consumes OriginCap ${out.origin_cap_id}`);
    console.log(`Consumes UpgradeCap ${out.upgrade_cap_id}`);
    console.log(`Promotes Currency<ONE> ${out.currency_id} to shared object.`);

    if (process.env.SEAL_CONFIRM !== 'YES_SEAL_PERMANENTLY') {
        console.log('\nSet env SEAL_CONFIRM=YES_SEAL_PERMANENTLY to proceed.');
        console.log('Example:  SEAL_CONFIRM=YES_SEAL_PERMANENTLY npx ts-node seal.ts');
        process.exit(0);
    }

    console.log('\n=== Executing... ===');
    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: {
            showEffects: true,
            showObjectChanges: true,
        },
    });

    if (result.effects?.status.status !== 'success') {
        console.error('\nSEAL FAILED:', JSON.stringify(result.effects?.status, null, 2));
        process.exit(2);
    }

    console.log('\n=== SEAL SUCCESS ===');
    console.log(`  seal_tx_digest: ${result.digest}`);
    console.log(`  gas used: ${result.effects.gasUsed.computationCost} MIST`);

    out.seal_tx_digest = result.digest;
    out.sealed_at_ms = Date.now();
    writeFileSync(OUTPUT_PATH, JSON.stringify(out, null, 2));
    console.log(`\n  Updated ${OUTPUT_PATH}`);

    // ----- Verify sealed state -----
    console.log('\n=== Verifying sealed state ===');
    await new Promise((r) => setTimeout(r, 2000)); // wait for finality

    const regObj = await client.getObject({
        id: out.registry_id,
        options: { showContent: true },
    });
    const fields = (regObj.data?.content as any)?.fields;
    const sealed = fields?.sealed;
    console.log(`  Registry.sealed = ${sealed}`);
    if (sealed !== true) {
        console.error('WARNING: expected sealed=true. Inspect Registry manually.');
        process.exit(3);
    }

    console.log('\n✓ ONE Sui v0.1.0 is LIVE and SEALED on mainnet.');
    console.log(`  Package:  ${out.package_id}`);
    console.log(`  Registry: ${out.registry_id}`);
    console.log(`  Currency: ${out.currency_id} (now shared)`);
    console.log('\nNext: git add sui/ && git commit && git push');
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});

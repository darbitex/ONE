// ONE publish script — uses supra-l1-sdk v5.0.2 to bypass aptos CLI RPC incompatibility.
// Reads publish payload JSON (generated via `aptos move build-publish-payload`)
// and submits as publish_package_txn via Supra's native /rpc/v3/transactions/submit.

const fs = require('fs');
const { SupraClient, SupraAccount, HexString } = require('supra-l1-sdk');

const RPC = process.env.SUPRA_RPC || 'https://rpc-testnet.supra.com';
const PAYLOAD_PATH = process.env.PAYLOAD_PATH || '/tmp/one-publish-payload.json';
const PRIVATE_KEY_HEX = process.env.DEPLOYER_KEY;
if (!PRIVATE_KEY_HEX) { console.error('DEPLOYER_KEY env var required'); process.exit(1); }

(async () => {
  // Load payload
  const p = JSON.parse(fs.readFileSync(PAYLOAD_PATH, 'utf8'));
  if (p.function_id !== '0x1::code::publish_package_txn') {
    throw new Error(`Unexpected function_id: ${p.function_id}`);
  }
  if (p.args.length !== 2) throw new Error(`Expected 2 args, got ${p.args.length}`);

  // Arg 0: package metadata (hex string -> Uint8Array)
  const metadataHex = p.args[0].value;
  const metadata = Uint8Array.from(Buffer.from(metadataHex.slice(2), 'hex'));
  console.log(`metadata: ${metadata.length} bytes`);

  // Arg 1: modules list (array of hex strings)
  const moduleHexes = p.args[1].value;
  const modules = moduleHexes.map(h => Array.from(Buffer.from(h.slice(2), 'hex')));
  console.log(`modules: ${modules.length} module(s), sizes: ${modules.map(m => m.length).join(', ')}`);

  // Init SDK
  const client = await SupraClient.init(RPC);
  console.log(`chain_id: ${client.chainId.value}, min_gas_price: ${client.minGasUnitPrice}`);

  // Create account from private key
  const account = new SupraAccount(
    Uint8Array.from(Buffer.from(PRIVATE_KEY_HEX.slice(2), 'hex'))
  );
  console.log(`deployer address: ${account.address().toString()}`);

  // Check balance
  const bal = await client.getAccountSupraCoinBalance(account.address());
  console.log(`SUPRA Coin balance: ${bal} raw (${Number(bal) / 1e8} SUPRA)`);

  // Publish
  console.log('\nPublishing ONE package...');
  const result = await client.publishPackage(
    account,
    metadata,
    modules,
    {
      optionalTransactionPayloadArgs: { maxGas: 500000n },
      enableTransactionWaitAndSimulationArgs: {
        enableWaitForTransaction: true,
        enableTransactionSimulation: false,
      },
    }
  );

  console.log(`\ntx hash: ${result.txHash}`);
  console.log(`result:  ${result.result}`);

  // Fetch tx detail
  const detail = await client.getTransactionDetail(account.address(), result.txHash);
  if (detail) {
    console.log('\n--- Transaction detail ---');
    console.log(`status:    ${detail.status}`);
    console.log(`gas used:  ${detail.gasUsed}`);
    console.log(`vm_status: ${detail.vm_status}`);
    console.log(`block:     ${detail.blockNumber}`);
  }
})().catch(e => {
  console.error('\nERROR:', e.message);
  if (e.response?.data) console.error('response:', JSON.stringify(e.response.data).slice(0, 500));
  process.exit(1);
});

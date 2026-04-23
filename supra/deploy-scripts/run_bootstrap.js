// Run bootstrap.mv script — opens ONE genesis trove.
const fs = require('fs');
const { SupraClient, SupraAccount, TxnBuilderTypes, BCS, HexString } = require('supra-l1-sdk');

const RPC = process.env.SUPRA_RPC || 'https://rpc-testnet.supra.com';
const PRIVATE_KEY_HEX = process.env.DEPLOYER_KEY;
if (!PRIVATE_KEY_HEX) { console.error('DEPLOYER_KEY env var required'); process.exit(1); }
const SCRIPT_PATH = '/home/rera/one/supra/build/ONE/bytecode_scripts/bootstrap.mv';

// args: supra_amt (raw, 8 dec), debt (raw, 8 dec)
const SUPRA_AMT = BigInt(process.env.SUPRA_AMT || 1_000_000_000_000n);  // default 10000 SUPRA → CR ~399% at $0.000399
const DEBT      = BigInt(process.env.DEBT      || 100_000_000n);        // default 1 ONE

(async () => {
  const scriptCode = Uint8Array.from(fs.readFileSync(SCRIPT_PATH));
  console.log(`script: ${scriptCode.length} bytes`);

  const client = await SupraClient.init(RPC);
  const account = new SupraAccount(
    Uint8Array.from(Buffer.from(PRIVATE_KEY_HEX.slice(2), 'hex'))
  );
  console.log(`deployer: ${account.address().toString()}`);

  const seq = (await client.getAccountInfo(account.address())).sequence_number;
  console.log(`seq: ${seq}`);

  // Build TransactionArgumentU64 args for the script
  const args = [
    new TxnBuilderTypes.TransactionArgumentU64(SUPRA_AMT),
    new TxnBuilderTypes.TransactionArgumentU64(DEBT),
  ];

  // Empty type args
  const tyArgs = [];

  const serializedTx = client.createSerializedScriptTxPayloadRawTxObject(
    account.address(),
    seq,
    scriptCode,
    tyArgs,
    args,
    { maxGas: 200000n }
  );

  console.log('Submitting bootstrap tx...');
  const result = await client.sendTxUsingSerializedRawTransaction(
    account,
    serializedTx,
    { enableTransactionWaitAndSimulationArgs: { enableWaitForTransaction: true } }
  );

  console.log(`tx hash: ${result.txHash}`);
  console.log(`result:  ${result.result}`);

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

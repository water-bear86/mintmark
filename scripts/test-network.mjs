import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { decodeFunctionData, erc20Abi, getAddress } from 'viem';
import { stripTypeScriptTypes } from 'node:module';
const dir = mkdtempSync(join(process.cwd(), '.network-test-'));
try {
  for (const file of ['client', 'launchpadAbi', 'dexAbi', 'amounts', 'submission']) {
    const source = readFileSync(`src/network/${file}.ts`, 'utf8').replace('"./launchpadAbi"', '"./launchpadAbi.js"').replace('"./dexAbi"', '"./dexAbi.js"');
    writeFileSync(join(dir, `${file}.js`), stripTypeScriptTypes(source));
  }
  const { dexAbi } = await import(pathToFileURL(join(dir, 'dexAbi.js')));
  const { parseHype, minimumAfterSlippage, parseCreatorFeePercent, formatFeePercent } = await import(pathToFileURL(join(dir, 'amounts.js')));
  const { createElysiumLaunchpad, submitWalletTransaction, UncertainSubmissionError, TransactionReplacedError, TransactionRevertedError, isFinalSubmissionFailure } = await import(pathToFileURL(join(dir, 'client.js')));
  const { matchesSubmission, parseStoredSubmission, readRecovery, persistSubmissionIntent, persistPendingHash } = await import(pathToFileURL(join(dir, 'submission.js')));
  const intent = { version: 1, chainId: 99801, from: '0x'+'1'.repeat(40), to: '0x'+'2'.repeat(40), nonce: 7, data: '0x1234', value: '99' };
  const exact = { from: intent.from, to: intent.to, nonce: 7, input: intent.data, value: 99n };
  assert.equal(matchesSubmission(intent,99801,exact),true);
  for (const mismatch of [{nonce:6}, {input:'0x5678'}, {value:100n}, {from:'0x'+'3'.repeat(40)}, {to:'0x'+'3'.repeat(40)}, {to:null}]) assert.equal(matchesSubmission(intent,99801,{...exact,...mismatch}),false);
  assert.equal(matchesSubmission(intent,99901,exact),false);
  assert.deepEqual(parseStoredSubmission(JSON.stringify(intent)),{intent});
  assert.deepEqual(parseStoredSubmission(intent.from),{legacy:true});
  assert.deepEqual(parseStoredSubmission('{broken'),{legacy:true});
  assert.deepEqual(parseStoredSubmission(JSON.stringify({...intent,nonce:-1})),{legacy:true});
  assert.equal(parseStoredSubmission(null),null);
  function memoryStorage() {
    const data = new Map();
    return { getItem: key => data.has(key) ? data.get(key) : null, setItem: (key,value) => data.set(key,value), removeItem: key => data.delete(key) };
  }
  const durable = memoryStorage(), session = memoryStorage(), key = 'mintmark.pending.99801.launchpad';
  persistSubmissionIntent(durable,session,key,intent);
  // Closing the old tab and opening a new one keeps the durable intent, with a fresh session store.
  assert.deepEqual(readRecovery(durable,memoryStorage(),key).uncertain,{intent});
  const before = durable.getItem(key+'.uncertain');
  assert.throws(()=>persistSubmissionIntent(durable,memoryStorage(),key,{...intent,nonce:8}),/previous transaction/);
  assert.equal(durable.getItem(key+'.uncertain'),before);
  const hash = '0x'+'4'.repeat(64);
  persistPendingHash(durable,session,key,hash);
  assert.deepEqual(readRecovery(durable,memoryStorage(),key),{hash,uncertain:null});
  assert.throws(()=>persistSubmissionIntent(durable,memoryStorage(),key,intent),/previous transaction/);
  assert.equal(durable.getItem(key),hash);
  const legacy = memoryStorage(), migrated = memoryStorage();
  legacy.setItem(key+'.uncertain',JSON.stringify(intent));
  assert.deepEqual(readRecovery(migrated,legacy,key).uncertain,{intent});
  assert.equal(legacy.getItem(key+'.uncertain'),null);
  assert.equal(migrated.getItem(key+'.uncertain'),JSON.stringify(intent));
  const oldHash = memoryStorage(), newHash = memoryStorage(); oldHash.setItem(key,hash);
  assert.equal(readRecovery(newHash,oldHash,key).hash,hash);
  const conflicting = memoryStorage(); conflicting.setItem(key,'0x'+'5'.repeat(64));
  assert.deepEqual(readRecovery(newHash,conflicting,key),{hash:null,uncertain:{legacy:true}});
  assert.equal(newHash.getItem(key),hash); assert.ok(conflicting.getItem(key));
  assert.throws(()=>persistSubmissionIntent(newHash,conflicting,key,intent),/previous transaction/);

  assert.equal(parseCreatorFeePercent('0'), 0);
  assert.equal(parseCreatorFeePercent('0.01'), 1);
  assert.equal(parseCreatorFeePercent('1.23'), 123);
  assert.equal(parseCreatorFeePercent('10.00'), 1000);
  assert.equal(formatFeePercent(1050), '10.50');
  for (const bad of ['', '.5', '01', '1e1', '-1', ' 1', '10.01', '0.001', 'NaN', '1.']) assert.throws(() => parseCreatorFeePercent(bad));
  assert.equal(parseHype('0.000000000000000001'), 1n);
  assert.equal(parseHype('123456789012345678.123456789012345678'), 123456789012345678123456789012345678n);
  for (const bad of ['1e18', '-1', ' 1', '1.1234567890123456789', 'NaN', '01']) assert.throws(() => parseHype(bad));
  assert.equal(minimumAfterSlippage(10000n, 50), 9950n);
  assert.throws(() => minimumAfterSlippage(1n, 10001));
  await assert.rejects(submitWalletTransaction(async()=>{throw new Error('Provider timed out');}), UncertainSubmissionError);
  const rejection = Object.assign(new Error('User refused'),{code:4001});
  await assert.rejects(submitWalletTransaction(async()=>{throw rejection;}), error => error === rejection);
  const nestedRejection = new Error('wrapper',{cause:rejection});
  await assert.rejects(submitWalletTransaction(async()=>{throw nestedRejection;}), error => error === nestedRejection);
  assert.equal(await submitWalletTransaction(async()=> '0x'+'1'.repeat(64)), '0x'+'1'.repeat(64));
  const network = { id: 99801, name: 'Elysium Testnet', nativeCurrency: { name:'HYPE',symbol:'HYPE',decimals:18 }, rpcUrl:'https://rpc.invalid', explorerUrl:null, testnet:true };
  assert.throws(() => createElysiumLaunchpad(network, 'bad'));
  assert.throws(() => createElysiumLaunchpad(network, '0x0000000000000000000000000000000000000000'));
  assert.throws(() => createElysiumLaunchpad({...network,id:1339}, '0x0000000000000000000000000000000000000001'));
  const address = '0x0000000000000000000000000000000000000001';
  let chain = '0x185d9', code = '0x6000';
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    const request = JSON.parse(options.body);
    const result = request.method === 'eth_chainId' ? chain : request.method === 'eth_getCode' ? code : '0x';
    return new Response(JSON.stringify({jsonrpc:'2.0',id:request.id,result}),{headers:{'Content-Type':'application/json'}});
  };
  try {
    const client = createElysiumLaunchpad(network,address);
    await client.ready();
    chain = '0x539'; await assert.rejects(client.ready(), /chain mismatch/);
    chain = '0x185d9'; code = '0x'; await assert.rejects(client.ready(), /No launchpad/);
    code = '0x6000'; await assert.rejects(client.buy(address,address,1n,1n,1n), /Wallet required/);
    const provider = {request: async ({method}) => method === 'eth_chainId' ? '0x539' : [address]};
    const wrongWallet = createElysiumLaunchpad(network,address,provider);
    await assert.rejects(wrongWallet.buy(address,address,1n,1n,1n), /Switch wallet/);
    let accountReads = 0, submissions = 0;
    const changing = createElysiumLaunchpad(network,address,{request:async ({method}) => {
      if (method === 'eth_chainId') return '0x185d9';
      if (method === 'eth_accounts') return [++accountReads === 1 ? address : '0x0000000000000000000000000000000000000002'];
      if (method === 'eth_sendTransaction') submissions++;
      return null;
    }});
    changing.publicClient.simulateContract = async () => ({request:{}});
    await assert.rejects(changing.buy(address,address,1n,1n,1n), /account changed/);
    assert.equal(submissions,0);
    client.publicClient.waitForTransactionReceipt = async () => ({status:'reverted'});
    await assert.rejects(client.receipt('0x'+'1'.repeat(64)), error => error instanceof TransactionRevertedError && isFinalSubmissionFailure(error));
    // UI uses this exact classifier before clearing the durable pending hash.
    const receiptStore = memoryStorage(); receiptStore.setItem(key,hash);
    client.publicClient.waitForTransactionReceipt = async () => {throw new Error('RPC unavailable: Transaction reverted could not be checked');};
    await assert.rejects(client.receipt(hash), error => {
      if (isFinalSubmissionFailure(error)) receiptStore.removeItem(key);
      assert.equal(isFinalSubmissionFailure(error),false);
      return true;
    });
    assert.equal(receiptStore.getItem(key),hash,'generic provider text must retain pending recovery');
    assert.equal(isFinalSubmissionFailure({name:'TransactionRevertedError',message:'Transaction reverted'}),false);
    assert.equal(isFinalSubmissionFailure(new TransactionReplacedError('cancelled',hash)),true);
    client.publicClient.waitForTransactionReceipt = async () => ({status:'unexpected'});
    await assert.rejects(client.receipt(hash),error=>!isFinalSubmissionFailure(error));
    client.publicClient.waitForTransactionReceipt = async () => {throw new Error('Receipt timeout');};
    await assert.rejects(client.receipt('0x'+'1'.repeat(64)), /Receipt timeout/);
    for (const reason of ['cancelled','replaced']) {
      client.publicClient.waitForTransactionReceipt = async ({onReplaced}) => {
        onReplaced({reason,transaction:{to:address,input:'0x',value:0n},replacedTransaction:{to:address,input:'0x',value:1n},transactionReceipt:{transactionHash:'0x'+'2'.repeat(64)}});
        return {status:'success',transactionHash:'0x'+'2'.repeat(64)};
      };
      await assert.rejects(client.receipt('0x'+'1'.repeat(64)), TransactionReplacedError);
    }
    client.publicClient.waitForTransactionReceipt = async ({onReplaced}) => {
      onReplaced({reason:'repriced',transaction:{to:address,input:'0x1234',value:1n},replacedTransaction:{to:address,input:'0x1234',value:1n},transactionReceipt:{transactionHash:'0x'+'2'.repeat(64)}});
      return {status:'success',transactionHash:'0x'+'2'.repeat(64)};
    };
    assert.equal((await client.receipt('0x'+'1'.repeat(64))).transactionHash,'0x'+'2'.repeat(64));

    // Persist exact nonce-bound intent before entering the wallet, including reload while its promise is pending.
    let persisted = null, sentRequest = null, releaseSend;
    const preparedEvents = [];
    const preparedProvider = { request: async ({method,params}) => {
      if (method === 'eth_chainId') return '0x185d9';
      if (method === 'eth_accounts') return [address];
      if (method === 'eth_sendTransaction') {
        preparedEvents.push('send'); sentRequest=params[0];
        assert.ok(persisted, 'intent must be persisted before wallet request');
        return await new Promise((_resolve,reject)=>{releaseSend=()=>reject(new Error('Transport timeout'));});
      }
      throw new Error('Unexpected wallet method: '+method);
    }};
    const prepared = createElysiumLaunchpad(network,address,preparedProvider,{
      onPrepared: value => {preparedEvents.push('persist'); persisted=JSON.stringify(value);},
      onRejected: () => {persisted=null;}
    });
    prepared.publicClient.simulateContract = async request => ({request});
    prepared.publicClient.getTransactionCount = async request => {assert.equal(request.blockTag,'pending');return 7;};
    const unknown = prepared.buy(address,address,99n,1n,123n);
    for(let i=0;i<100&&!releaseSend;i++) await new Promise(resolve=>setTimeout(resolve,1));
    assert.ok(releaseSend);
    assert.deepEqual(preparedEvents,['persist','send']);
    assert.equal(sentRequest.nonce,'0x7');
    const afterReload = parseStoredSubmission(persisted);
    assert.ok(afterReload.intent);
    assert.equal(afterReload.intent.nonce,7);
    assert.equal(afterReload.intent.data,sentRequest.data);
    assert.equal(afterReload.intent.value,'99');
    releaseSend();
    await assert.rejects(unknown,error => error instanceof UncertainSubmissionError && error.intent.nonce===7);
    assert.ok(persisted,'uncertain result must retain persisted lock');
    const refusal = Object.assign(new Error('Rejected'),{code:4001});
    await assert.rejects(submitWalletTransaction(async()=>{throw refusal;},afterReload.intent,()=>{persisted=null;}),error=>error===refusal);
    assert.equal(persisted,null,'explicit rejection clears prepared intent');
    let blockedSends=0;
    const storageBlocked = createElysiumLaunchpad(network,address,{request:async({method})=>{
      if(method==='eth_chainId') return '0x185d9'; if(method==='eth_accounts') return [address]; blockedSends++; throw new Error('Must not send');
    }},{onPrepared:()=>{throw new Error('Storage unavailable');},onRejected:()=>{}});
    storageBlocked.publicClient.simulateContract=async request=>({request});
    storageBlocked.publicClient.getTransactionCount=async()=>7;
    await assert.rejects(storageBlocked.buy(address,address,1n,1n,1n),/Storage unavailable/);
    assert.equal(blockedSends,0);
    // Graduated trades derive every address from the configured launchpad, never from user input.
    const addr = n => getAddress('0x' + n.toString(16).padStart(40, '0'));
    const token = addr(10), migrator = addr(11), router = addr(12), factory = addr(13), wrapped = addr(14), pool = addr(15);
    const route = {router, factory, wrapped, pool};
    let overrides = {}, approval = 0n, dexIntent, dexSend, dexSendMode = 'success', simulationFailure = false, simulations = [];
    let dexWalletChain = '0x185d9', dexWalletAccount = address, afterSimulation = () => {};
    const dex = createElysiumLaunchpad(network,address,{request:async({method,params})=>{
      if(method==='eth_chainId') return dexWalletChain;
      if(method==='eth_accounts') return [dexWalletAccount];
      if(method==='eth_sendTransaction') {
        dexSend = params[0];
        assert.equal(dexIntent.to.toLowerCase(), dexSend.to.toLowerCase());
        assert.equal(dexIntent.data, dexSend.data);
        assert.equal(dexIntent.nonce, Number(BigInt(dexSend.nonce)));
        if(dexSendMode === 'unknown') throw new Error('Transport timeout');
        if(dexSendMode === 'rejected') throw Object.assign(new Error('Rejected'), {code:4001});
        return hash;
      }
      throw new Error('Unexpected wallet method '+method);
    }},{onPrepared: value=>{dexIntent=value;},onRejected:()=>{dexIntent=null;}});
    dex.publicClient.getTransactionCount = async()=>19;
    dex.publicClient.simulateContract = async request => {simulations.push(request); if(simulationFailure) throw new Error('Simulation failed'); afterSimulation(); return {request};};
    dex.publicClient.readContract = async ({address:target,functionName,args}) => {
      const key = target.toLowerCase()+':'+functionName;
      if(key in overrides) return overrides[key];
      switch(functionName) {
        case 'curves': return {token,pool,graduated:true,plugin:addr(90),creatorFeeBps:123};
        case 'pendingCreatorFees': return 1234567890123456789n;
        case 'migrator': return migrator;
        case 'router': return router;
        case 'dexFactory': case 'factory': return factory;
        case 'weth': case 'WETH': return wrapped;
        case 'poolFor': case 'getPair': case 'pool': return pool;
        case 'launchpad': return address;
        case 'poolUnlocked': return true;
        case 'token0': return token;
        case 'token1': return wrapped;
        case 'getReserves': return [1000n, 2000n, 0];
        case 'getAmountsOut': return [args[0],500n];
        case 'allowance': return approval;
        default: throw new Error('Unexpected DEX read '+functionName);
      }
    };
    dex.publicClient.getBlockNumber = async()=>123n;
    const fees = await dex.creatorFees(token);
    assert.equal(fees.pending,1234567890123456789n);
    assert.equal(fees.recipient,addr(90));
    assert.equal(fees.creatorFeeBps,123);
    assert.equal(await dex.collectCreatorFees(address,token,addr(90)),hash);
    assert.equal(dexIntent.to,address);
    assert.equal(dexIntent.value,'0');
    const { launchpadAbi } = await import(pathToFileURL(join(dir, 'launchpadAbi.js')));
    assert.deepEqual(decodeFunctionData({abi:launchpadAbi,data:dexSend.data}),{functionName:'collectCreatorFees',args:[token]});
    for (const [fn,value,pattern] of [
      ['curves',{token,pool,plugin:addr(91)},/recipient changed/],
      ['curves',{token:addr(91),pool,plugin:addr(90)},/Unknown token/],
      ['pendingCreatorFees',0n,/No creator fees/],
    ]) {
      overrides={[address.toLowerCase()+':'+fn]:value}; dexSend=null;
      await assert.rejects(dex.collectCreatorFees(address,token,addr(90)),pattern); assert.equal(dexSend,null);
    }
    overrides={}; simulationFailure=true; dexSend=null;
    await assert.rejects(dex.collectCreatorFees(address,token,addr(90)),/Simulation failed/);
    assert.equal(dexSend,null); simulationFailure=false;
    assert.deepEqual(await dex.dexRoute(token), route);
    assert.deepEqual(await dex.quoteDex(token,100n,'buy'),{route,output:500n});
    const invalid = [
      [address,'curves',{token,pool,graduated:false}],
      [router,'factory',addr(90)], [router,'WETH',addr(90)], [factory,'getPair',addr(90)],
      [migrator,'poolFor',addr(90)], [token,'pool',addr(90)], [token,'launchpad',addr(90)],
      [token,'poolUnlocked',false], [pool,'token0',addr(90)], [pool,'token1',addr(90)],
      [pool,'getReserves',[0n,100n,0]], [pool,'factory',addr(90)],
    ];
    for(const [target,fn,value] of invalid) {
      overrides = {[target.toLowerCase()+':'+fn]:value};
      await assert.rejects(dex.quoteDex(token,100n,'buy'));
      dexSend=null;
      await assert.rejects(dex.approveDex(address,token,100n,route));
      assert.equal(dexSend,null);
    }
    overrides={};
    const originalCode = dex.publicClient.getCode;
    dex.publicClient.getCode = async ({address:target}) => target===pool ? '0x' : '0x6000';
    await assert.rejects(dex.dexRoute(token),/migration may still be pending/);
    dex.publicClient.getCode = originalCode;
    await assert.rejects(dex.dexAllowance(token,address,{...route,router:addr(90)}),/route changed/);
    assert.equal(await dex.dexAllowance(token,address,route),0n);
    const deadline = BigInt(Math.floor(Date.now()/1000)+120);
    dexSend=null;
    await assert.rejects(dex.tradeDex(address,token,100n,490n,deadline,'sell',route),/Approve the exact/);
    assert.equal(dexSend,null);
    assert.equal(await dex.approveDex(address,token,100n,route),hash);
    assert.equal(dexIntent.to,token);
    assert.equal(dexIntent.value,'0');
    assert.deepEqual(decodeFunctionData({abi:erc20Abi,data:dexSend.data}).args,[router,100n]);
    approval=100n;
    assert.equal(await dex.tradeDex(address,token,100n,490n,deadline,'sell',route),hash);
    let decoded=decodeFunctionData({abi:dexAbi,data:dexSend.data});
    assert.equal(decoded.functionName,'swapExactTokensForETHSupportingFeeOnTransferTokens');
    assert.deepEqual(decoded.args,[100n,490n,[token,wrapped],address,deadline]);
    assert.equal(dexIntent.to,router); assert.equal(dexIntent.value,'0');
    assert.equal(await dex.tradeDex(address,token,100n,490n,deadline,'buy',route),hash);
    decoded=decodeFunctionData({abi:dexAbi,data:dexSend.data});
    assert.equal(decoded.functionName,'swapExactETHForTokensSupportingFeeOnTransferTokens');
    assert.deepEqual(decoded.args,[490n,[wrapped,token],address,deadline]);
    assert.equal(dexIntent.to,router); assert.equal(dexIntent.value,'100');
    for(const [input,minimum,time] of [[0n,1n,deadline],[1n,0n,deadline],[1n,1n,1n],[1n,1n,deadline+1000n]]) {
      dexSend=null; await assert.rejects(dex.tradeDex(address,token,input,minimum,time,'buy',route),/Positive input/); assert.equal(dexSend,null);
    }
    simulationFailure=true; dexSend=null;
    await assert.rejects(dex.tradeDex(address,token,100n,490n,deadline,'buy',route),/Simulation failed/);
    assert.equal(dexSend,null); simulationFailure=false;
    for (const action of [()=>dex.collectCreatorFees(address,token,addr(90)),()=>dex.approveDex(address,token,100n,route),()=>dex.tradeDex(address,token,100n,490n,deadline,'buy',route),()=>dex.tradeDex(address,token,100n,490n,deadline,'sell',route)]) {
      dexSend=null; afterSimulation=()=>{dexWalletAccount=addr(91);};
      await assert.rejects(action(),/account changed/); assert.equal(dexSend,null);
      dexWalletAccount=address; afterSimulation=()=>{dexWalletChain='0x539';};
      await assert.rejects(action(),/Switch wallet/); assert.equal(dexSend,null);
      dexWalletChain='0x185d9'; afterSimulation=()=>{};
    }
    // Capture the UI account at click time, then change wallets while the FIRST readiness RPC is pending.
    // No simulation, approval, or send may adopt the newly selected wallet.
    const launchInput = {name:'Race',symbol:'RACE',metadataURI:'',creatorFeeBps:0,plugin:addr(90),minTokensOut:0n,maxLaunchFee:1n,value:1n};
    const initialRaceActions = [
      () => dex.collectCreatorFees(address,token,addr(90)),
      () => dex.launch(address,launchInput),
      () => dex.buy(address,token,100n,1n,deadline),
      () => dex.sell(address,token,100n,1n,deadline),
      () => dex.approveDex(address,token,100n,route),
      () => dex.tradeDex(address,token,100n,490n,deadline,'buy',route),
      () => dex.tradeDex(address,token,100n,490n,deadline,'sell',route),
    ];
    const originalChainId = dex.publicClient.getChainId;
    for(const action of initialRaceActions) {
      let resumeReady;
      dex.publicClient.getChainId = () => new Promise(resolve=>{resumeReady=()=>resolve(network.id);});
      dexWalletAccount=address; dexSend=null;
      const beforeSimulations=simulations.length;
      const pendingWrite=action();
      assert.ok(resumeReady,'write must be waiting on initial readiness');
      dexWalletAccount=addr(91); resumeReady();
      await assert.rejects(pendingWrite,/account changed/);
      assert.equal(simulations.length,beforeSimulations,'no simulation from a substituted signer');
      assert.equal(dexSend,null,'no wallet request from a substituted signer');
    }
    dex.publicClient.getChainId=originalChainId; dexWalletAccount=address;
    await assert.rejects(dex.approveDex(undefined,token,100n,route),/Expected wallet account/);
    for (const bps of [-1,1001,0.5,NaN]) await assert.rejects(dex.launch(address,{...launchInput,creatorFeeBps:bps}),/whole basis points/);
    for (const recipient of [addr(0),addr(0xdead),address]) await assert.rejects(dex.launch(address,{...launchInput,plugin:recipient}),/Invalid creator fee recipient/);
    assert.equal(await dex.launch(address,{...launchInput,creatorFeeBps:123}),hash);
    const launched = decodeFunctionData({abi:launchpadAbi,data:dexSend.data});
    assert.equal(launched.args[3],123); assert.equal(launched.args[4],addr(90));
    dexSendMode='unknown';
    await assert.rejects(dex.collectCreatorFees(address,token,addr(90)),e=>e instanceof UncertainSubmissionError && e.intent.to===address && e.intent.nonce===19);
    assert.ok(dexIntent);
    await assert.rejects(dex.approveDex(address,token,100n,route),e=>e instanceof UncertainSubmissionError && e.intent.to===token && e.intent.nonce===19);
    assert.ok(dexIntent);
    await assert.rejects(dex.tradeDex(address,token,100n,490n,deadline,'buy',route),e=>e instanceof UncertainSubmissionError && e.intent.to===router);
    assert.ok(dexIntent);
    dexSendMode='rejected';
    await assert.rejects(dex.approveDex(address,token,100n,route)); assert.equal(dexIntent,null);
    chain='0x539'; dexSend=null;
    await assert.rejects(dex.quoteDex(token,100n,'buy'),/chain mismatch/); assert.equal(dexSend,null); chain='0x185d9';
    const rejecting = createElysiumLaunchpad(network,address,{request:async()=>{throw new Error('User rejected');}});
    await assert.rejects(rejecting.buy(address,address,1n,1n,1n), /User rejected/);
  } finally { globalThis.fetch = originalFetch; }
  // Render the actual Fees branch, not merely its client handler. Vite transforms only this test fixture.
  const { createServer } = await import('vite');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { createElement } = await import('react');
  const originalWindow = globalThis.window;
  globalThis.window = {};
  const renderer = await createServer({ configFile:false, server:{middlewareMode:true,hmr:false}, plugins:[{
    name:'fees-render-fixture', enforce:'pre', transform(source,id) {
      if (id.endsWith('/src/ui/ThemeToggle.tsx')) return 'export function ThemeToggle() { return null; }';
      if (!id.endsWith('/src/app/LiveApp.tsx')) return;
      return source
        .replace('import.meta.env.VITE_ELYSIUM_LAUNCHPAD_ADDRESS', JSON.stringify(address))
        .replace('useState<"discover" | "launch" | "fees">("discover")', 'useState<"discover" | "launch" | "fees">("fees")')
        .replace('useState<(Awaited<ReturnType<Client["creatorFees"]>> & { at: number }) | null>(null)',
          'useState<(Awaited<ReturnType<Client["creatorFees"]>> & { at: number }) | null>({token:"0x000000000000000000000000000000000000000a",recipient:"0x000000000000000000000000000000000000005a",pending:1234567890123456789n,creatorFeeBps:123,graduated:true,blockNumber:123n,at:Date.now()})');
    }
  }] });
  try {
    const { LiveApp } = await renderer.ssrLoadModule('/src/app/LiveApp.tsx');
    const html = renderToStaticMarkup(createElement(LiveApp));
    for (const expected of ['Creator fees','Refresh fees','Collect to recipient','1234567890123456789','1.234567890123456789','0x000000000000000000000000000000000000005a','1.23','1.73','Anyone may collect','normal V2 swaps have no creator tax']) assert.ok(html.includes(expected),'Fees render must contain '+expected);
    assert.ok(!html.includes('Launch a meme'),'Fees navigation must not fall through to launch');
    assert.match(html, /disabled=""[^>]*>Collect to recipient/, 'Disconnected wallet cannot collect');
  } finally { await renderer.close(); globalThis.window = originalWindow; }
  console.log('Network client and exact-amount regression checks passed (mock RPC only; no transactions sent).');
} finally { rmSync(dir,{recursive:true,force:true}); }

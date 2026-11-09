import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const dir = mkdtempSync(join(process.cwd(), '.demo-test-'));
try {
  for (const file of ['timeline', 'launches', 'app/market']) {
    let source = readFileSync(`src/${file}.ts`, 'utf8')
      .replace('"../timeline"', '"./timeline.js"')
      .replace('"../launches"', '"./launches.js"')
      .replace('setInterval(tick, 1300);', ''); // No background simulation during deterministic tests.
    if (file === 'app/market') source += '\nexport const testState = state; export { clearSealed };';
    writeFileSync(join(dir, `${file.split('/').at(-1)}.js`), stripTypeScriptTypes(source));
  }
  const { CURVE_SUPPLY, TOTAL_SUPPLY, V_ETH0, V_TOK0, GRAD_RAISE, curveAt } = await import(pathToFileURL(join(dir, 'timeline.js')));
  const { quoteBuy, quoteSell, priceAt, raisedAt, progressOf, getToken, PLATFORM_FEE_BPS, MAX_CREATOR_FEE_BPS, feeRate, HYPE_USD, connectDemo, disconnect, launch, buy, sell: sellAction, claimCreatorFees, clearSealed, testState } = await import(pathToFileURL(join(dir, 'market.js')));
  const { LAUNCHES } = await import(pathToFileURL(join(dir, 'launches.js')));
  const near = (a, b, tolerance = 1e-10) => assert.ok(Math.abs(a - b) <= tolerance, `${a} != ${b}`);
  assert.equal(V_TOK0, 1_066_666_667);
  assert.equal(V_ETH0, 10.0000000125);
  assert.equal(CURVE_SUPPLY, 800_000_000);
  assert.equal(TOTAL_SUPPLY - CURVE_SUPPLY, 200_000_000);
  assert.equal(PLATFORM_FEE_BPS, 50);
  assert.equal(MAX_CREATOR_FEE_BPS, 1000);
  const FEE = 0.005;
  assert.equal(HYPE_USD, 2500); // Display-only sample rate is deliberately unchanged.
  near(GRAD_RAISE, 30);
  for (const sold of [0, CURVE_SUPPLY / 2, CURVE_SUPPLY - 1, CURVE_SUPPLY]) {
    near(raisedAt(sold), curveAt(sold).raised);
    near(priceAt(sold), curveAt(sold).price);
    near(progressOf({ sold }), raisedAt(sold) / 30);
  }
  const partial = quoteBuy({ sold: 0, creatorFeeBps: 0 }, 5);
  assert.ok(partial.tokens < CURVE_SUPPLY, '5 HYPE must not graduate');
  near(raisedAt(partial.tokens), 4.975);
  const full = quoteBuy({ sold: 0, creatorFeeBps: 0 }, 100);
  assert.equal(full.capped, true);
  assert.equal(full.tokens, CURVE_SUPPLY);
  near(full.ethUsed, 30 / (1 - FEE));
  near(full.ethUsed - full.fee, 30);
  const final = quoteBuy({ sold: partial.tokens, creatorFeeBps: 0 }, 100);
  near(final.ethUsed * (1 - FEE), 30 - 4.975);
  const sell = quoteSell({ sold: partial.tokens, creatorFeeBps: 0 }, partial.tokens);
  near(sell.eth + sell.fee, 4.975);
  assert.ok(LAUNCHES.filter(l => l.graduated).every(l => getToken(l.ticker)?.graduated), 'seeded graduates should reach the recalibrated target');
  // Per-launch fees, including precise basis-point selection, capped refunds and sells.
  for (const bps of [0, 1, 123, 1000]) {
    const fresh = { sold: 0, creatorFeeBps: bps };
    const rate = feeRate(fresh);
    const q = quoteBuy(fresh, 100);
    near(q.ethUsed, 30 / (1 - rate));
    near(q.ethUsed - q.fee, 30);
    near(q.creatorFee, q.ethUsed * bps / 10_000);
    near(q.platformFee, q.ethUsed * 0.005);
    near(q.creatorFee + q.platformFee, q.fee);
    const sellQuote = quoteSell({ ...fresh, sold: q.tokens }, q.tokens);
    near(sellQuote.eth + sellQuote.fee, 30);
    near(sellQuote.creatorFee, 30 * bps / 10_000);
  }
  connectDemo();
  const originalAddress = testState.wallet.address;
  const input = { name: 'Claim test', ticker: 'CLAIM', desc: '', image: null, initialBuy: 0, creatorFeeBps: 123 };
  for (const creatorFeeBps of [-1, 1001, 1.5, NaN, Infinity]) assert.equal(launch({ ...input, creatorFeeBps }).ok, false);
  for (const initialBuy of [-1, NaN, Infinity]) assert.equal(launch({ ...input, initialBuy }).ok, false);
  const result = launch(input);
  assert.equal(result.ok, true);
  const t = getToken(result.id);
  assert.equal(t.creatorFeeBps, 123);
  assert.equal(t.creatorRecipient, originalAddress);
  assert.equal(claimCreatorFees(t).ok, false, 'nothing accrued at launch');
  assert.equal(buy(t, 0.2).ok, true);
  assert.equal(t.creatorAccrued, 0, 'sealed demo orders are not yet trades');
  clearSealed(t);
  near(t.creatorAccrued, 0.2 * 0.0123);
  t.sealedUntil = 0;
  const soldBefore = t.sold;
  const walletBefore = testState.wallet.eth;
  const accruedBefore = t.creatorAccrued;
  assert.equal(t.graduated, false);
  assert.equal(claimCreatorFees(t).ok, true, 'claim before graduation');
  near(testState.wallet.eth, walletBefore + accruedBefore);
  near(t.creatorClaimed, accruedBefore);
  assert.equal(t.creatorAccrued, 0);
  assert.equal(t.sold, soldBefore, 'claim must not take curve reserves');
  assert.equal(claimCreatorFees(t).ok, false, 'repeat claim cannot duplicate payment');
  near(testState.wallet.eth, walletBefore + accruedBefore);
  assert.equal(buy(t, 0.1).ok, true);
  const sellAmount = t.holders[originalAddress] / 2;
  const sellQ = quoteSell(t, sellAmount);
  const beforeSell = t.creatorAccrued;
  assert.equal(sellAction(t, sellAmount).ok, true);
  near(t.creatorAccrued, beforeSell + sellQ.creatorFee);
  const accrued = t.creatorAccrued;
  disconnect();
  assert.equal(claimCreatorFees(t).ok, false, 'disconnected claims denied');
  connectDemo();
  assert.equal(testState.wallet.address, originalAddress, 'reconnect preserves saved demo account');
  const ownWallet = testState.wallet;
  testState.wallet = { address: 'other-demo-account', eth: 1 };
  assert.equal(claimCreatorFees(t).ok, false, 'another account cannot redirect fees');
  assert.equal(t.creatorAccrued, accrued);
  assert.equal(testState.wallet.eth, 1);
  testState.wallet = ownWallet;
  ownWallet.eth += 100;
  assert.equal(buy(t, 100).ok, true);
  assert.equal(t.graduated, true);
  near(raisedAt(t.sold), 30);
  const finalAccrued = t.creatorAccrued;
  const finalBalance = ownWallet.eth;
  assert.equal(claimCreatorFees(t).ok, true, 'accrued fees remain claimable after graduation');
  near(ownWallet.eth, finalBalance + finalAccrued);
  assert.equal(buy(t, 0.01).ok, false, 'closed curve does not accrue new fees');
  assert.equal(t.creatorAccrued, 0);
  assert.equal(claimCreatorFees(t).ok, false);
  for (const value of [NaN, Infinity, -1]) {
    assert.equal(buy(t, value).ok, false);
    assert.equal(sellAction(t, value).ok, false);
  }
  // A capped sealed batch refunds the saved account even while disconnected.
  const cappedLaunch = launch({ ...input, ticker: 'CAPQA', initialBuy: 50, creatorFeeBps: 1000 });
  assert.equal(cappedLaunch.ok, true);
  const cappedToken = getToken(cappedLaunch.id);
  const balanceAfterOrder = ownWallet.eth;
  disconnect();
  clearSealed(cappedToken);
  connectDemo();
  near(testState.wallet.eth, balanceAfterOrder + 50 - 30 / 0.895);
  near(cappedToken.trades[0].eth, 30 / 0.895);
  near(cappedToken.creatorAccrued, 30 / 0.895 * 0.1);
  // No persisted market snapshot can be reinterpreted under the new curve.
  const marketSource = readFileSync('src/app/market.ts', 'utf8');
  assert.deepEqual([...marketSource.matchAll(/localStorage\.(?:getItem|setItem)\("([^"]+)"/g)].map(m => m[1]), ['mintmark.watch', 'mintmark.watch']);
  console.log('Demo economics: 30 HYPE net target, per-token fee bounds/splits, capped refunds, claims/access/repeats, shared math, seeding and storage checks passed.');
} finally {
  rmSync(dir, { recursive: true, force: true });
}

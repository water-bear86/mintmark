// Offline only. Reproduce MintMark's integer baseline, not a live quote.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const source = readFileSync(new URL('../contracts/launchpad/MintMarkLaunchpad.sol', import.meta.url), 'utf8');
function constant(name) {
  const expression = source.match(new RegExp(`constant ${name} = ([^;]+);`))?.[1].replaceAll('_', '');
  assert(expression, `Missing ${name}`);
  const [mantissa, exponent = '0'] = expression.split('e');
  return BigInt(mantissa) * 10n ** BigInt(exponent);
}
const E = constant('VIRTUAL_ETH_0'), T = constant('VIRTUAL_TOKENS_0');
const C = constant('CURVE_SUPPLY'), P = constant('POOL_SUPPLY'), S = constant('TOTAL_SUPPLY');
const W = 10n ** 18n, ceil = (a, b) => (a + b - 1n) / b;
const end = ceil(E * T, T - C), net = end - E;
assert.equal(C + P, S);
assert.equal(net, 30n * W);
assert.equal(E * C, 30n * W * (T - C), "Reserve must be calibrated to the 30 HYPE net target");
const units = n => `${n / W}.${(n % W).toString().padStart(18, '0')}`;
for (const [name, n] of Object.entries({ initialVirtualNative:E, finalVirtualNative:end, netSeed:net,
  openingMarketCap:E*C/T, finalMarketCap:end*C/(T-C), openingFDV:E*S/T,
  finalFDV:end*S/(T-C), poolFDV:net*S/P })) console.log(`${name}: ${n} wei = ${units(n)} HYPE`);
for (const creatorBps of [0n, 50n, 1000n]) {
  const feeBps = constant('FEE_BPS') + creatorBps;
  const spent = net + ceil(net * feeBps, 10000n - feeBps);
  const total = spent - net, platform = ceil(total * constant('FEE_BPS'), feeBps);
  // An over-offer avoids the normal-path independent-ceiling threshold at exact gross.
  const offered = spent + 2n;
  const offeredNet = offered - ceil(offered * constant('FEE_BPS'), 10000n) - ceil(offered * creatorBps, 10000n);
  assert(T - ceil(E*T, E + offeredNet) >= C);
  assert.equal(platform + (total - platform) + net, spent);
  console.log(`creator ${creatorBps} bps: spent=${units(spent)}; platform=${units(platform)}; creator=${units(total-platform)} HYPE`);
}

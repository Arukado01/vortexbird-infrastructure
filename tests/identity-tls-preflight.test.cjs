const test = require('node:test');
const assert = require('node:assert/strict');
const { inspect, inspectPlan, covers, runFile } = require('../scripts/preflight-identity-tls.cjs');
const { mkdtempSync, writeFileSync, readFileSync, unlinkSync, rmdirSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { createHash } = require('node:crypto');
const listener = 'arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000001';
const identity = 'arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000002';
const now = new Date('2026-11-17T00:00:00Z');
const input = { region: 'us-east-2', portalOrigin: 'https://portal.example.test', identityOrigin: 'https://identity.example.test', listenerCertificateArn: listener, identityCertificateArn: identity };
const cert = (arn, sans = ['*.example.test'], overrides = {}) => ({ CertificateArn: arn, Status: 'ISSUED', NotBefore: '2026-01-01T00:00:00Z', NotAfter: '2027-01-01T00:00:00Z', SubjectAlternativeNames: sans, ...overrides });

test('reads exactly the specified certificates and accepts current matching SANs', () => {
  const calls = [];
  const result = inspect(input, (arn, region) => { calls.push({ arn, region }); return cert(arn); }, now);
  assert.deepEqual(calls, [{ arn: listener, region: 'us-east-2' }, { arn: identity, region: 'us-east-2' }]);
  assert.equal(result.status, 'certificate-metadata-passed');
  assert.deepEqual(result.mutationsExecuted, []);
  assert.equal(result.certificates.length, 2);
});

test('a shared certificate is read once but must cover both origins', () => {
  let calls = 0;
  inspect({ ...input, identityCertificateArn: null }, arn => { calls++; return cert(arn); }, now);
  assert.equal(calls, 1);
  assert.throws(() => inspect({ ...input, identityCertificateArn: null }, arn => cert(arn, ['portal.example.test']), now), /SANs do not cover/);
});

test('rejects region or account mismatch before any account read', () => {
  const noRead = () => { throw new Error('Unexpected AWS read'); };
  assert.throws(() => inspect({ ...input, region: 'us-east-1' }, noRead, now), /ALB region/);
  assert.throws(() => inspect({ ...input, identityCertificateArn: identity.replace('123456789012', '999999999999') }, noRead, now), /same account/);
});

test('rejects pending, expired, not-yet-valid or malformed certificate dates', () => {
  for (const overrides of [{ Status: 'PENDING_VALIDATION' }, { NotAfter: '2026-01-01T00:00:00Z' }, { NotBefore: '2027-01-01T00:00:00Z' }, { NotBefore: 'invalid' }]) {
    assert.throws(() => inspect(input, arn => cert(arn, ['*.example.test'], overrides), now), /ISSUED|currently valid/);
  }
});

test('rejects wrong exact response ARN and SAN mismatch', () => {
  assert.throws(() => inspect(input, () => cert(identity), now), /exact requested/);
  assert.throws(() => inspect(input, arn => cert(arn, ['other.example.test']), now), /SANs do not cover/);
});

test('wildcards cover one label only and never the apex or unrelated suffix', () => {
  assert.equal(covers('*.example.test', 'identity.example.test'), true);
  assert.equal(covers('*.example.test', 'x.identity.example.test'), false);
  assert.equal(covers('*.example.test', 'example.test'), false);
  assert.equal(covers('*.example.test', 'badexample.test'), false);
  assert.equal(covers('IDENTITY.EXAMPLE.TEST', 'identity.example.test'), true);
});

test('rejects insecure, wildcard, credentialed, path or identical origins', () => {
  for (const origin of ['http://identity.example.test', 'https://*.example.test', 'https://user:password@identity.example.test', 'https://identity.example.test/path', 'https://identity.example.test/', input.portalOrigin]) {
    assert.throws(() => inspect({ ...input, identityOrigin: origin }, () => { throw Error('Unexpected AWS read'); }, now), /HTTPS origin|different hostnames/);
  }
});

test('a malformed or missing input overwrites an old approval with blocked evidence', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vortexbird-tls-test-'));
  const source = join(dir, 'input.json');
  const report = join(dir, 'result.json');
  try {
    for (const malformed of [true, false]) {
      writeFileSync(report, JSON.stringify({ status: 'certificate-metadata-passed' }));
      if (malformed) writeFileSync(source, '{"secret":"sensitive-fixture", broken}');
      else unlinkSync(source);
      assert.throws(() => runFile(source, report, () => { throw Error('Unexpected AWS read'); }, now));
      const result = JSON.parse(readFileSync(report, 'utf8'));
      assert.equal(result.status, 'blocked');
      assert.doesNotMatch(result.reason, /sensitive-fixture/);
      assert.equal(result.checkedAt, now.toISOString());
      assert.deepEqual(result.mutationsExecuted, []);
    }
  } finally { unlinkSync(report); rmdirSync(dir); }
});

test('successful evidence records the exact reviewed input hash and current timestamp', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vortexbird-tls-test-'));
  const source = join(dir, 'input.json');
  const report = join(dir, 'result.json');
  try {
    const raw = JSON.stringify(input, null, 2);
    writeFileSync(source, raw);
    runFile(source, report, arn => cert(arn), now);
    const result = JSON.parse(readFileSync(report, 'utf8'));
    assert.equal(result.reviewedInputSha256, createHash('sha256').update(raw).digest('hex'));
    assert.equal(result.checkedAt, now.toISOString());
  } finally { unlinkSync(source); unlinkSync(report); rmdirSync(dir); }
});

function plan(app = true, id = true) {
  const values = { region: 'us-east-2', deploy_services: app, identity_deploy_service: id, identity_enabled: id, identity_request_certificate: false, certificate_arn: listener, portal_origin: input.portalOrigin, identity_hostname: 'identity.example.test', keycloak_url: input.identityOrigin, identity_certificate_arn: identity };
  const resources = [
    { address: 'aws_lb_listener.https[0]', values: { certificate_arn: listener } },
    ...(app ? [{ address: 'aws_ecs_service.service["api"]', values: { name: 'api' } }] : []),
    ...(id ? [{ address: 'aws_ecs_service.identity[0]', values: { name: 'identity' } }] : [])
  ];
  return { variables: Object.fromEntries(Object.entries(values).map(([name, value]) => [name, { value }])), planned_values: { root_module: { resources } } };
}
const checkPlan = (saved, describeMetadata = arn => cert(arn), account = '123456789012', region = 'us-east-2') => inspectPlan(saved, account, region, describeMetadata, now);

function sharedPlan() {
  const saved = plan();
  saved.variables.identity_shared_host = { value: true };
  saved.variables.identity_hostname.value = new URL(input.portalOrigin).hostname;
  saved.variables.keycloak_url.value = `${input.portalOrigin}/auth`;
  saved.variables.identity_certificate_arn.value = null;
  return saved;
}

test('portal and identity under /auth use one portal certificate and one ACM read', () => {
  const calls = [];
  const result = checkPlan(sharedPlan(), arn => { calls.push(arn); return cert(arn, ['portal.example.test']); });
  assert.deepEqual(calls, [listener]);
  assert.deepEqual(result.certificates.map(item => item.hostname), ['portal.example.test']);
  assert.deepEqual(result.activatedServices, { application: true, identity: true });
});

test('shared identity rejects a second domain, DNS record, certificate or an unexpected issuer path before ACM', () => {
  for (const invalid of [
    { keycloak_url: input.portalOrigin }, { keycloak_url: `${input.portalOrigin}/auth/` },
    { identity_hostname: 'other.example.test', keycloak_url: 'https://other.example.test/auth' },
    { identity_certificate_arn: identity }, { identity_manage_dns: true }, { identity_request_certificate: true },
    { identity_shared_host: null }
  ]) {
    const saved = sharedPlan();
    for (const [name, value] of Object.entries(invalid)) saved.variables[name] = { value };
    assert.throws(() => checkPlan(saved, () => { throw Error('Unexpected ACM read'); }), /[Ss]hared identity|issuer path|host mode/);
  }
});

test('foundation plan can request an unknown certificate without activating services or querying ACM', () => {
  const saved = plan(false, false);
  saved.variables.identity_enabled.value = true;
  saved.variables.identity_request_certificate.value = true;
  saved.variables.certificate_arn.value = null;
  saved.planned_values.root_module.resources = [];
  const result = checkPlan(saved, () => { throw Error('Unexpected ACM read'); });
  assert.equal(result.status, 'not-required-foundation-only');
  assert.deepEqual(result.certificates, []);
});

test('application-only activation validates the exact portal certificate', () => {
  const calls = [];
  const result = checkPlan(plan(true, false), arn => { calls.push(arn); return cert(arn, ['portal.example.test']); });
  assert.deepEqual(calls, [listener]);
  assert.deepEqual(result.activatedServices, { application: true, identity: false });
});

test('identity activation uses the certificate from the saved plan and rejects unknown requested ARN', () => {
  const saved = plan();
  saved.variables.identity_request_certificate.value = true;
  assert.throws(() => checkPlan(saved), /unknown.*foundation/);
  saved.planned_values.root_module.resources.push({ address: 'aws_acm_certificate_validation.identity[0]', values: { certificate_arn: identity } });
  const result = checkPlan(saved);
  assert.equal(result.certificates[1].arn, identity);
  assert.deepEqual(result.activatedServices, { application: true, identity: true });
});

test('unknown flags or disagreement between variables and planned services fail closed', () => {
  const saved = plan();
  saved.variables.identity_deploy_service.value = null;
  assert.throws(() => checkPlan(saved), /known boolean/);
  saved.variables.identity_deploy_service.value = false;
  assert.throws(() => checkPlan(saved), /do not match/);
});

test('approved account and region must match both saved plan and certificate ARNs', () => {
  assert.throws(() => checkPlan(plan(), undefined, '999999999999'), /approved account/);
  assert.throws(() => checkPlan(plan(), undefined, '123456789012', 'us-east-1'), /approved deployment region/);
  assert.throws(() => checkPlan(plan(), undefined, ''), /required/);
});

test('an unknown or changed listener certificate blocks before any ACM read', () => {
  for (const value of [undefined, identity]) {
    const saved = plan();
    saved.planned_values.root_module.resources[0].values.certificate_arn = value;
    assert.throws(() => checkPlan(saved, () => { throw Error('Unexpected ACM read'); }), /must be known and match/);
  }
});

test('plan identity issuer mismatch or invalid SAN prevents activation', () => {
  const saved = plan();
  saved.variables.keycloak_url.value = 'https://wrong.example.test';
  assert.throws(() => checkPlan(saved), /issuer origin differ/);
  assert.throws(() => checkPlan(plan(), arn => cert(arn, ['portal.example.test'])), /SANs do not cover/);
});

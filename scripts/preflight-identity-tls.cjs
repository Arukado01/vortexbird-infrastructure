#!/usr/bin/env node
'use strict';
const { readFileSync, writeFileSync } = require('node:fs');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');

function hostname(origin) {
  const url = new URL(origin);
  if (url.protocol !== 'https:' || url.origin !== origin || url.username || url.password || url.port || !/^[a-z0-9.-]+$/.test(url.hostname) || !url.hostname.includes('.')) throw new Error('Use an exact HTTPS origin without credentials, port, path or wildcard.');
  return url.hostname;
}

function certificateArn(arn) {
  const match = /^arn:(aws|aws-us-gov|aws-cn):acm:([a-z0-9-]+):(\d{12}):certificate\/([a-f0-9-]+)$/.exec(arn || '');
  if (!match) throw new Error('An exact ACM certificate ARN is required.');
  return { partition: match[1], region: match[2], account: match[3] };
}

function covers(san, host) {
  const name = String(san).toLowerCase();
  if (name === host) return true;
  return name.startsWith('*.') && host.split('.').length === name.split('.').length && host.endsWith(name.slice(1));
}

function validateInput(input) {
  const portalHost = hostname(input.portalOrigin);
  const identityHost = input.identityOrigin == null ? null : hostname(input.identityOrigin);
  const shared = input.identitySharedHost === true;
  if (input.identitySharedHost !== undefined && typeof input.identitySharedHost !== 'boolean') throw new Error('Identity host mode must be boolean.');
  if (shared && identityHost !== portalHost) throw new Error('Shared identity must use the portal hostname.');
  if (!shared && portalHost === identityHost) throw new Error('Dedicated portal and identity must use different hostnames.');
  if (shared && input.identityCertificateArn && input.identityCertificateArn !== input.listenerCertificateArn) throw new Error('Shared identity must use the listener certificate.');
  const listener = certificateArn(input.listenerCertificateArn);
  if (!identityHost && input.identityCertificateArn) throw new Error('An identity certificate requires an identity origin.');
  const identityArn = identityHost ? (input.identityCertificateArn || input.listenerCertificateArn) : null;
  const identity = identityArn ? certificateArn(identityArn) : listener;
  if (listener.region !== input.region || identity.region !== input.region) throw new Error('Every certificate must be in the ALB region.');
  if (listener.account !== identity.account || listener.partition !== identity.partition) throw new Error('Listener and identity certificates must belong to the same account and partition.');
  return { portalHost, identityHost, identityArn, account: listener.account };
}

function validateCertificate(certificate, arn, host, now) {
  if (certificate.CertificateArn !== arn) throw new Error('ACM response did not match the exact requested certificate ARN.');
  if (certificate.Status !== 'ISSUED') throw new Error(`Certificate for ${host} is not ISSUED.`);
  const from = Date.parse(certificate.NotBefore);
  const until = Date.parse(certificate.NotAfter);
  if (!Number.isFinite(from) || !Number.isFinite(until) || from > now.getTime() || until <= now.getTime()) throw new Error(`Certificate for ${host} is not currently valid.`);
  const sans = certificate.SubjectAlternativeNames || [];
  if (!sans.some(san => covers(san, host))) throw new Error(`Certificate SANs do not cover ${host}.`);
  return { arn, hostname: host, status: certificate.Status, notBefore: certificate.NotBefore, notAfter: certificate.NotAfter, matchedSan: sans.find(san => covers(san, host)) };
}

function inspect(input, describe, now = new Date()) {
  const { portalHost, identityHost, identityArn, account } = validateInput(input);
  const requested = [...new Set([input.listenerCertificateArn, identityArn].filter(Boolean))];
  const certificates = new Map(requested.map(arn => [arn, describe(arn, input.region)]));
  const verified = [
    validateCertificate(certificates.get(input.listenerCertificateArn), input.listenerCertificateArn, portalHost, now),
    ...(identityHost && identityHost !== portalHost ? [validateCertificate(certificates.get(identityArn), identityArn, identityHost, now)] : [])
  ];
  return { checkedAt: now.toISOString(), status: 'certificate-metadata-passed', region: input.region, account, certificates: verified, mutationsExecuted: [], limits: ['ACM metadata only; no DNS resolution, TLS handshake, ALB association, application login or deployment verified.', 'Re-run immediately before the reviewed deployment; a saved report does not guarantee future validity.'] };
}

function inspectPlan(plan, expectedAccount, expectedRegion, describeMetadata, now = new Date()) {
  if (!/^\d{12}$/.test(expectedAccount || '') || !expectedRegion) throw new Error('Expected deployment account and region are required.');
  if (!plan.variables || !plan.planned_values?.root_module) throw new Error('Use terraform show -json for the exact saved plan.');
  const value = name => plan.variables[name]?.value;
  const deployApp = value('deploy_services');
  const deployIdentity = value('identity_deploy_service');
  if (typeof deployApp !== 'boolean' || typeof deployIdentity !== 'boolean') throw new Error('Service activation flags must be known boolean values in the saved plan.');
  if (value('region') !== expectedRegion) throw new Error('Saved plan region differs from the approved deployment region.');
  const resources = plan.planned_values.root_module.resources || [];
  const resource = address => resources.find(item => item.address === address)?.values;
  const hasApp = resources.some(item => item.address.startsWith('aws_ecs_service.service['));
  const hasIdentity = Boolean(resource('aws_ecs_service.identity[0]'));
  if (hasApp !== deployApp || hasIdentity !== deployIdentity) throw new Error('Saved plan resources do not match service activation flags.');
  if (!deployApp && !deployIdentity) return { checkedAt: now.toISOString(), status: 'not-required-foundation-only', region: expectedRegion, account: expectedAccount, certificates: [], mutationsExecuted: [], limits: ['No application or identity service is activated by this plan; no ACM query was made.'] };
  if (deployIdentity && value('identity_enabled') !== true) throw new Error('Identity activation requires identity_enabled.');
  const shared = deployIdentity && (plan.variables.identity_shared_host === undefined ? false : value('identity_shared_host'));
  if (typeof shared !== 'boolean') throw new Error('Identity host mode must be known in the saved plan.');
  if (shared && (value('identity_request_certificate') || value('identity_certificate_arn') || value('identity_manage_dns'))) throw new Error('Shared identity must reuse portal DNS and its listener certificate.');
  const listenerCertificateArn = value('certificate_arn');
  if (!listenerCertificateArn || resource('aws_lb_listener.https[0]')?.certificate_arn !== listenerCertificateArn) throw new Error('The exact shared listener certificate ARN must be known and match the saved plan.');
  const identityCertificateArn = deployIdentity ? (value('identity_request_certificate') === true ? resource('aws_acm_certificate_validation.identity[0]')?.certificate_arn : value('identity_certificate_arn') || listenerCertificateArn) : null;
  if (deployIdentity && !identityCertificateArn) throw new Error('Identity certificate ARN is unknown; complete the foundation certificate phase before activation.');
  for (const arn of [listenerCertificateArn, identityCertificateArn].filter(Boolean)) {
    const parsed = certificateArn(arn);
    if (parsed.account !== expectedAccount || parsed.region !== expectedRegion) throw new Error('A saved plan certificate does not match the approved account and region.');
  }
  const identityOrigin = deployIdentity ? `https://${value('identity_hostname') || ''}` : null;
  const identityBase = shared ? `${identityOrigin}/auth` : identityOrigin;
  if (deployIdentity && value('keycloak_url') !== identityBase) throw new Error('Saved plan identity hostname and issuer origin differ, or the issuer path is incorrect.');
  const result = inspect({ region: expectedRegion, portalOrigin: value('portal_origin'), identityOrigin, identitySharedHost: shared, listenerCertificateArn, identityCertificateArn }, describeMetadata, now);
  return { ...result, source: 'saved-terraform-plan', activatedServices: { application: deployApp, identity: deployIdentity } };
}

function describe(arn, region) {
  const result = spawnSync('aws', ['acm', 'describe-certificate', '--certificate-arn', arn, '--region', region, '--output', 'json', '--no-cli-pager'], { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024, env: { ...process.env, AWS_PAGER: '' } });
  if (result.error || result.status !== 0) throw new Error('Read-only ACM DescribeCertificate failed; check authenticated least-privilege AWS access. Provider output was not recorded.');
  const parsed = JSON.parse(result.stdout);
  if (!parsed.Certificate) throw new Error('ACM response lacks Certificate metadata.');
  return parsed.Certificate;
}

function runFile(inputPath, outputPath, describeMetadata = describe, now = new Date(), planContext = null) {
  let reviewedInputSha256 = null;
  const hashField = planContext ? 'reviewedPlanJsonSha256' : 'reviewedInputSha256';
  try {
    const raw = readFileSync(inputPath, 'utf8');
    reviewedInputSha256 = createHash('sha256').update(raw).digest('hex');
    let parsed;
    try { parsed = JSON.parse(raw); } catch { throw new Error('Input JSON is invalid; contents are not included in diagnostics.'); }
    const checked = planContext ? inspectPlan(parsed, planContext.account, planContext.region, describeMetadata, now) : inspect(parsed, describeMetadata, now);
    const result = { ...checked, [hashField]: reviewedInputSha256 };
    writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`);
    return result;
  } catch (error) {
    writeFileSync(outputPath, `${JSON.stringify({ checkedAt: now.toISOString(), status: 'blocked', [hashField]: reviewedInputSha256, reason: error.message, mutationsExecuted: [] }, null, 2)}\n`);
    throw error;
  }
}

function main(args) {
  let result;
  if (args.length === 4 && args[0] === '--input' && args[2] === '--out') result = runFile(args[1], args[3]);
  else if (args.length === 8 && args[0] === '--plan-json' && args[2] === '--expected-account' && args[4] === '--expected-region' && args[6] === '--out') result = runFile(args[1], args[7], describe, new Date(), { account: args[3], region: args[5] });
  else throw new Error('Usage: --input reviewed-tls.json --out result.json OR --plan-json terraform-plan.json --expected-account ACCOUNT --expected-region REGION --out result.json');
  process.stdout.write(`TLS preflight: ${result.status}. DNS/TLS/runtime validation remains pending.\n`);
}

module.exports = { covers, inspect, inspectPlan, validateInput, validateCertificate, runFile };
if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}

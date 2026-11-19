// Deployment code, not evidence of a deployment. AWS is contacted only by main().
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const execute = promisify(execFile);
const services = ['api', 'worker', 'frontend'];
const digestPattern = /^sha256:[a-f0-9]{64}$/;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const clone = value => JSON.parse(JSON.stringify(value));

function validateConfig(config, digests, operation = 'release') {
  assert.ok(['release', 'migrate', 'verify'].includes(operation), 'Unknown operation');
  assert.match(config.accountId, /^\d{12}$/);
  assert.match(config.region, /^[a-z]{2}-[a-z]+-\d$/);
  assert.ok(['development', 'staging', 'production'].includes(config.environment));
  const name = `vortexbird-ecs-${config.environment}`;
  assert.equal(config.clusterArn, `arn:aws:ecs:${config.region}:${config.accountId}:cluster/${name}`, 'Unexpected cluster');
  for (const role of operation !== 'migrate' ? ['frontend', 'backend'] : ['backend']) {
    assert.match(digests[role], digestPattern, 'An immutable sha256 digest is required');
    assert.equal(config.repositories[role], `${config.accountId}.dkr.ecr.${config.region}.amazonaws.com/${name}-${role}`, 'Repository is outside this stack');
  }
  const assertTask = (arn, role) => assert.match(arn, new RegExp(`^arn:aws:ecs:${config.region}:${config.accountId}:task-definition/${name}-${role}:\\d+$`));
  assertTask(config.migration.taskDefinitionArn, 'migration');
  assert.ok(config.migration.subnets.length >= 2);
  config.migration.subnets.forEach(id => assert.match(id, /^subnet-[a-f0-9]+$/));
  assert.equal(config.migration.securityGroups.length, 1);
  config.migration.securityGroups.forEach(id => assert.match(id, /^sg-[a-f0-9]+$/));
  if (operation !== 'migrate') {
    services.forEach(role => assertTask(config.taskDefinitions[role], role));
    const portal = new URL(config.portalOrigin);
    const issuer = new URL(config.oidcIssuer);
    assert.equal(portal.origin, config.portalOrigin);
    assert.equal(portal.protocol, 'https:');
    assert.equal(issuer.protocol, 'https:');
    assert.equal(issuer.username, '');
    assert.equal(issuer.password, '');
    assert.ok(config.oidcIssuer.endsWith('/realms/vortexbird'));
    if (issuer.origin === portal.origin) {
      assert.equal(config.oidcIssuer, `${config.portalOrigin}/auth/realms/vortexbird`, 'Unexpected shared-host issuer path');
    }
    for (const role of ['api', 'frontend']) assert.match(config.targetGroups[role], new RegExp(`^arn:aws:elasticloadbalancing:${config.region}:${config.accountId}:targetgroup/vb-ecs-${config.environment}-${role}/[a-f0-9]+$`));
  }
  return config;
}

function validateBootstrap(bootstrap, config, operation) {
  if (!bootstrap) return;
  assert.equal(operation, 'migrate', 'Initial administrator bootstrap is explicit migrate-only work');
  assert.equal(new URL(bootstrap.issuer).protocol, 'https:');
  assert.equal(bootstrap.issuer, config.oidcIssuer, 'Bootstrap issuer must match the reviewed identity');
  assert.ok(bootstrap.subject && bootstrap.subject !== 'demo-admin');
  assert.ok(bootstrap.email && bootstrap.displayName);
}

function cloneTaskDefinition(template, config, role, digest) {
  const expectedFamily = `vortexbird-ecs-${config.environment}-${role}`;
  assert.equal(template.family, expectedFamily);
  assert.equal(template.networkMode, 'awsvpc');
  assert.ok(template.requiresCompatibilities.includes('FARGATE'));
  for (const [field, suffix] of [['taskRoleArn', 'task'], ['executionRoleArn', 'execution']]) {
    assert.equal(template[field], `arn:aws:iam::${config.accountId}:role/${expectedFamily}-${suffix}`, 'Unexpected task identity');
  }
  assert.equal(template.containerDefinitions.length, 1, 'Unreviewed sidecars are not accepted');
  assert.equal(template.containerDefinitions[0].name, role);
  const fields = ['family', 'taskRoleArn', 'executionRoleArn', 'networkMode', 'containerDefinitions', 'volumes', 'placementConstraints', 'requiresCompatibilities', 'cpu', 'memory', 'pidMode', 'ipcMode', 'proxyConfiguration', 'inferenceAccelerators', 'ephemeralStorage', 'runtimePlatform'];
  const request = Object.fromEntries(fields.filter(key => template[key] !== undefined).map(key => [key, clone(template[key])]));
  const container = request.containerDefinitions[0];
  container.image = `${config.repositories[role === 'frontend' ? 'frontend' : 'backend']}@${digest}`;
  const environment = Object.fromEntries((container.environment || []).map(item => [item.name, item.value]));
  assert.equal(environment[role === 'frontend' ? 'VITE_DEMO_AUTH' : 'Authentication__DemoEnabled'], 'false', 'Demo authentication must be disabled');
  if (role !== 'frontend') {
    assert.equal(environment.Database__Initialize, 'false', 'Services cannot initialize schemas');
    assert.equal(environment.Seed__Enabled, 'false', 'Cloud tasks cannot seed demo data');
    assert.equal(environment.ConnectionStrings__Database, undefined, 'Database credentials must come from a secret reference');
  }
  if (role === 'migration') {
    assert.deepEqual(container.command, ['--migrate']);
    assert.equal(environment.Workers__Enabled, 'false');
  }
  request.tags = [{ key: 'Project', value: 'VortexBird' }, { key: 'Environment', value: config.environment }];
  return request;
}

function assertStableService(service, expectedRevision) {
  assert.equal(service.status, 'ACTIVE');
  assert.equal(service.deploymentController?.type || 'ECS', 'ECS');
  assert.ok(service.desiredCount > 0, 'Zero desired tasks cannot be healthy');
  assert.equal(service.pendingCount, 0);
  assert.equal(service.runningCount, service.desiredCount);
  assert.equal(service.deployments.length, 1, 'A concurrent or incomplete deployment exists');
  assert.equal(service.deployments[0].status, 'PRIMARY');
  assert.equal(service.deployments[0].rolloutState, 'COMPLETED');
  assert.equal(service.taskDefinition, expectedRevision);
  assert.equal(service.deployments[0].taskDefinition, expectedRevision, 'ECS rolled back to another revision');
}

async function defaultSmoke(config, fetcher = fetch) {
  const get = url => fetcher(url, { redirect: 'error', signal: AbortSignal.timeout(10000), headers: { Accept: 'application/json,text/plain' } });
  const portal = await get(`${config.portalOrigin}/health`);
  assert.equal(portal.status, 200);
  assert.equal((await portal.text()).trim(), 'ok', 'Frontend health did not return the nginx health response');
  const auth = await get(`${config.portalOrigin}/api/v1/auth/config`);
  assert.equal(auth.status, 200);
  assert.match(auth.headers.get('content-type') || '', /^application\/json\b/i, 'An HTML fallback is not API health');
  const body = await auth.json();
  assert.equal(body.demoEnabled, false);
  assert.equal(body.authority, config.oidcIssuer);
  const protectedRoute = await get(`${config.portalOrigin}/api/v1/auth/me`);
  assert.equal(protectedRoute.status, 401, 'Anonymous access to auth/me must be rejected');
  const discovery = await get(`${config.oidcIssuer}/.well-known/openid-configuration`);
  assert.equal(discovery.status, 200);
  assert.match(discovery.headers.get('content-type') || '', /^application\/json\b/i);
  const identity = await discovery.json();
  assert.equal(identity.issuer, config.oidcIssuer);
  assert.ok(identity.code_challenge_methods_supported.includes('S256'));
  if (new URL(config.oidcIssuer).origin === config.portalOrigin) {
    const protocol = `${config.oidcIssuer}/protocol/openid-connect`;
    for (const [field, path] of Object.entries({ authorization_endpoint: 'auth', token_endpoint: 'token', end_session_endpoint: 'logout', jwks_uri: 'certs' })) {
      assert.equal(identity[field], `${protocol}/${path}`, `Shared-host discovery returned an unexpected ${field}`);
    }
  }
  return { portal: 'passed', apiConfig: 'passed', anonymousAuthorization: 'passed', oidcDiscovery: 'passed', humanOidcLogin: 'not-tested' };
}

async function runRelease(input, dependencies) {
  const { config, digests, operation = 'release', bootstrapAdmin, releaseId = crypto.randomUUID() } = input;
  validateConfig(config, digests, operation);
  validateBootstrap(bootstrapAdmin, config, operation);
  const { aws, checkpoint = async () => {}, delay = sleep, smoke = defaultSmoke, pollAttempts = 60, pollDelayMs = 10000 } = dependencies;
  const report = { releaseId, operation, accountId: config.accountId, region: config.region, clusterArn: config.clusterArn, digests, status: 'running', stages: [], previous: {}, proposed: {}, attempted: [], rollback: [] };
  let migrationStopped = false;
  const record = async (stage, detail = {}) => { report.stages.push({ stage, ...detail }); await checkpoint(clone(report)); };
  const ecs = (command, request) => aws('ecs', command, request);
  const templates = new Map();
  async function checkedTemplate(role, arn, digest) {
    if (!templates.has(arn)) {
      const described = await ecs('describe-task-definition', { taskDefinition: arn });
      assert.equal(described.taskDefinition.taskDefinitionArn, arn);
      templates.set(arn, described.taskDefinition);
    }
    return cloneTaskDefinition(templates.get(arn), config, role, digest);
  }
  async function describeServices() {
    const response = await ecs('describe-services', { cluster: config.clusterArn, services });
    assert.equal((response.failures || []).length, 0, 'Service lookup failed');
    assert.equal(response.services.length, 3, 'Three existing services are required for release');
    return Object.fromEntries(response.services.map(service => {
      assert.ok(services.includes(service.serviceName));
      assert.equal(service.clusterArn, config.clusterArn);
      return [service.serviceName, service];
    }));
  }
  async function register(role, templateArn, digest) {
    const request = await checkedTemplate(role, templateArn, digest);
    const registered = await ecs('register-task-definition', request);
    const definition = registered.taskDefinition;
    assert.equal(definition.family, request.family);
    assert.equal(definition.containerDefinitions[0].image, request.containerDefinitions[0].image);
    assert.match(definition.taskDefinitionArn, new RegExp(`^arn:aws:ecs:${config.region}:${config.accountId}:task-definition/${request.family}:\\d+$`));
    return definition.taskDefinitionArn;
  }
  async function waitHealthy(expected, prior = {}) {
    const staleReads = Object.fromEntries(services.map(role => [role, 0]));
    for (let attempt = 0; attempt < pollAttempts; attempt++) {
      const live = await describeServices();
      for (const role of services) {
        const primary = live[role].deployments.find(item => item.status === 'PRIMARY');
        if (primary?.rolloutState === 'FAILED') throw new Error(`Deployment failed for ${role}`);
        if (live[role].taskDefinition !== expected[role]) {
          // DescribeServices is eventually consistent after UpdateService. Permit
          // only the captured prior revision, for three bounded stale reads.
          if (live[role].taskDefinition !== prior[role] || ++staleReads[role] > 3) throw new Error(`Concurrent change or automatic rollback for ${role}`);
        } else { staleReads[role] = 0; }
      }
      let stable = true;
      try { services.forEach(role => assertStableService(live[role], expected[role])); } catch { stable = false; }
      if (stable) {
        const list = await ecs('list-tasks', { cluster: config.clusterArn, serviceName: 'worker', desiredStatus: 'RUNNING' });
        if (list.taskArns?.length >= live.worker.desiredCount) {
          const tasks = await ecs('describe-tasks', { cluster: config.clusterArn, tasks: list.taskArns });
          if (!(tasks.failures || []).length && tasks.tasks.length >= live.worker.desiredCount && tasks.tasks.every(task => task.taskDefinitionArn === expected.worker && task.lastStatus === 'RUNNING' && task.healthStatus === 'HEALTHY')) {
            let targetsHealthy = true;
            for (const role of ['api', 'frontend']) {
              const targets = await aws('elbv2', 'describe-target-health', { TargetGroupArn: config.targetGroups[role] });
              const descriptions = targets.TargetHealthDescriptions || [];
              // Draining previous tasks are allowed; each current desired target must be healthy.
              if (descriptions.filter(target => target.TargetHealth.State === 'healthy').length < live[role].desiredCount || descriptions.some(target => !['healthy', 'draining'].includes(target.TargetHealth.State))) targetsHealthy = false;
            }
            if (targetsHealthy) return;
          }
        }
      }
      await delay(pollDelayMs);
    }
    throw new Error('Service health timeout');
  }
  try {
    const identity = await aws('sts', 'get-caller-identity', {});
    assert.equal(identity.Account, config.accountId, 'AWS account does not match reviewed configuration');
    for (const role of operation !== 'migrate' ? ['frontend', 'backend'] : ['backend']) {
      const image = await aws('ecr', 'describe-images', { repositoryName: config.repositories[role].split('/').slice(1).join('/'), imageIds: [{ imageDigest: digests[role] }] });
      assert.equal(image.imageDetails?.[0]?.imageDigest, digests[role], 'Digest is not present in the expected ECR repository');
    }
    if (operation !== 'migrate') {
      const baseline = await describeServices();
      for (const role of services) { assertStableService(baseline[role], baseline[role].taskDefinition); report.previous[role] = baseline[role].taskDefinition; }
    }
    if (operation === 'release') {
      for (const role of services) {
        const imageRole = role === 'frontend' ? 'frontend' : 'backend';
        await checkedTemplate(role, config.taskDefinitions[role], digests[imageRole]);
        await checkedTemplate(role, report.previous[role], digests[imageRole]);
        const oldImage = templates.get(report.previous[role]).containerDefinitions[0].image;
        assert.ok(oldImage.startsWith(`${config.repositories[imageRole]}@`), 'Rollback image is outside the reviewed ECR repository');
        assert.match(oldImage.split('@')[1] || '', digestPattern, 'A mutable rollback image is not accepted');
      }
    }
    if (operation !== 'verify') await checkedTemplate('migration', config.migration.taskDefinitionArn, digests.backend);
    await record('preflight-passed');
    if (operation === 'verify') {
      for (const role of services) {
        const described = await ecs('describe-task-definition', { taskDefinition: report.previous[role] });
        const expected = cloneTaskDefinition(described.taskDefinition, config, role, digests[role === 'frontend' ? 'frontend' : 'backend']);
        assert.equal(described.taskDefinition.containerDefinitions[0].image, expected.containerDefinitions[0].image, 'The running image differs from the reviewed digest');
      }
      await waitHealthy(report.previous);
      report.smoke = await smoke(config);
      report.status = 'verified';
      await record('smoke-passed');
      return report;
    }
    const migrationDefinition = await register('migration', config.migration.taskDefinitionArn, digests.backend);
    const request = { cluster: config.clusterArn, taskDefinition: migrationDefinition, count: 1, launchType: 'FARGATE', platformVersion: '1.4.0', networkConfiguration: { awsvpcConfiguration: { subnets: config.migration.subnets, securityGroups: config.migration.securityGroups, assignPublicIp: 'DISABLED' } } };
    if (bootstrapAdmin) request.overrides = { containerOverrides: [{ name: 'migration', command: ['--migrate', '--bootstrap-admin'], environment: [
      { name: 'Bootstrap__AdminSubject', value: bootstrapAdmin.subject }, { name: 'Bootstrap__AdminEmail', value: bootstrapAdmin.email },
      { name: 'Bootstrap__AdminDisplayName', value: bootstrapAdmin.displayName }, { name: 'Bootstrap__OidcIssuer', value: bootstrapAdmin.issuer }
    ] }] };
    request.clientToken = crypto.createHash('sha256').update(releaseId + JSON.stringify(request)).digest('hex');
    request.startedBy = `vb-${request.clientToken.slice(0, 20)}`;
    const started = await ecs('run-task', request);
    const migrationTask = started.tasks?.[0]?.taskArn;
    if (migrationTask) assert.match(migrationTask, new RegExp(`^arn:aws:ecs:${config.region}:${config.accountId}:task/vortexbird-ecs-${config.environment}/[a-f0-9]+$`), 'Migration task is outside the reviewed cluster');
    report.migrationTaskArn = migrationTask;
    await record('migration-start-requested');
    if ((started.failures || []).length || started.tasks?.length !== 1 || !migrationTask) {
      if (migrationTask) { await ecs('stop-task', { cluster: config.clusterArn, task: migrationTask, reason: 'VortexBird incomplete migration launch' }); migrationStopped = true; }
      throw new Error('ECS rejected migration launch');
    }
    let migrated = false;
    for (let attempt = 0; attempt < pollAttempts; attempt++) {
      const state = await ecs('describe-tasks', { cluster: config.clusterArn, tasks: [migrationTask] });
      // A newly started task can be temporarily absent because ECS is eventually consistent.
      if (state.tasks?.length === 1 && !(state.failures || []).length) {
        const task = state.tasks[0];
        assert.equal(task.taskArn, migrationTask);
        assert.equal(task.taskDefinitionArn, migrationDefinition);
        if (task.lastStatus === 'STOPPED') {
          migrationStopped = true;
          assert.equal(task.containers?.find(container => container.name === 'migration')?.exitCode, 0, 'Migration did not exit successfully');
          migrated = true; break;
        }
      }
      await delay(pollDelayMs);
    }
    if (!migrated) {
      await ecs('stop-task', { cluster: config.clusterArn, task: migrationTask, reason: 'VortexBird migration timeout; rollout blocked' });
      migrationStopped = true;
      throw new Error('Migration timeout; no service was updated');
    }
    await record('migration-passed');
    if (operation === 'migrate') { report.status = 'migration-completed'; await checkpoint(clone(report)); return report; }
    for (const role of services) report.proposed[role] = await register(role, config.taskDefinitions[role], digests[role === 'frontend' ? 'frontend' : 'backend']);
    await record('task-revisions-registered');
    for (const role of services) {
      const live = await describeServices();
      assertStableService(live[role], report.previous[role]);
      report.attempted.push(role);
      await record('service-update-requested', { service: role });
      await ecs('update-service', { cluster: config.clusterArn, service: role, taskDefinition: report.proposed[role] });
    }
    await waitHealthy(report.proposed, report.previous);
    await record('services-healthy');
    report.smoke = await smoke(config);
    report.status = 'released';
    await record('smoke-passed');
    return report;
  } catch (error) {
    report.failure = error.message;
    report.status = 'failed';
    if (report.migrationTaskArn && !migrationStopped) {
      try {
        await ecs('stop-task', { cluster: config.clusterArn, task: report.migrationTaskArn, reason: 'VortexBird release cannot verify migration; rollout blocked' });
        report.migrationStopRequested = true;
      } catch (stopError) { report.migrationStopFailure = stopError.message; }
    }
    if (report.attempted.length) {
      for (const role of [...report.attempted].reverse()) {
        try {
          const live = await describeServices();
          assert.ok([report.proposed[role], report.previous[role]].includes(live[role].taskDefinition), 'Concurrent revision changed; automatic rollback refused');
          await ecs('update-service', { cluster: config.clusterArn, service: role, taskDefinition: report.previous[role] });
          report.rollback.push({ service: role, status: 'requested' });
        } catch (rollbackError) { report.rollback.push({ service: role, status: 'failed', reason: rollbackError.message }); }
      }
      if (report.rollback.every(item => item.status === 'requested')) {
        try { await waitHealthy(report.previous, report.proposed); report.status = 'rolled-back'; } catch (rollbackError) { report.rollbackFailure = rollbackError.message; }
      }
    }
    await checkpoint(clone(report));
    const failure = new Error(`ECS ${operation} ${report.status}: ${error.message}`);
    failure.report = report;
    throw failure;
  }
}

function createAwsCli(region) {
  return async (service, command, request) => {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'vortexbird-ecs-'));
    const input = path.join(temporary, 'input.json');
    try {
      fs.writeFileSync(input, JSON.stringify(request), { mode: 0o600 });
      const { stdout } = await execute('aws', [service, command, '--region', region, '--cli-input-json', `file://${input.replace(/\\/g, '/')}`, '--output', 'json', '--no-cli-pager'], { windowsHide: true, timeout: 120000, maxBuffer: 8 * 1024 * 1024 });
      return stdout.trim() ? JSON.parse(stdout) : {};
    } catch { throw new Error(`AWS CLI ${service} ${command} failed; inspect restricted runner diagnostics without publishing request payloads`); }
    finally { fs.rmSync(input, { force: true }); fs.rmdirSync(temporary); }
  };
}

async function main() {
  const args = process.argv.slice(2);
  const value = key => { const i = args.indexOf(key); return i >= 0 ? args[i + 1] : undefined; };
  const configFile = value('--config');
  assert.ok(configFile, 'Use --config with the real Terraform release_contract JSON');
  const config = JSON.parse(fs.readFileSync(configFile, 'utf8').replace(/^\uFEFF/, ''));
  const input = { config, digests: { backend: value('--backend-digest'), frontend: value('--frontend-digest') }, operation: value('--operation') || 'release', releaseId: value('--release-id') };
  const bootstrap = value('--bootstrap-config');
  if (bootstrap) input.bootstrapAdmin = JSON.parse(fs.readFileSync(bootstrap, 'utf8').replace(/^\uFEFF/, ''));
  validateConfig(config, input.digests, input.operation);
  validateBootstrap(input.bootstrapAdmin, config, input.operation);
  if (args.includes('--validate-only')) { console.log('Release configuration valid. No AWS requests or deployments executed.'); return; }
  assert.ok(args.includes('--execute'), 'Execution requires --execute after the exact release and cost approval');
  const reportFile = value('--report') || 'ecs-release-result.json';
  const checkpoint = async report => fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n');
  const report = await runRelease(input, { aws: createAwsCli(config.region), checkpoint });
  console.log(JSON.stringify({ status: report.status, report: path.resolve(reportFile) }));
}
module.exports = { validateConfig, validateBootstrap, cloneTaskDefinition, assertStableService, defaultSmoke, runRelease, createAwsCli };
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });

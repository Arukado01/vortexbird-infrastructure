const test = require('node:test');
const assert = require('node:assert/strict');
const { validateConfig, validateBootstrap, cloneTaskDefinition, assertStableService, defaultSmoke, runRelease } = require('../scripts/release-ecs.cjs');

// In-memory AWS responses only: these tests do not execute AWS CLI or open sockets.
const copy = value => JSON.parse(JSON.stringify(value));
const roles = ['api', 'worker', 'frontend'];
const accountId = '123456789012';
const region = 'us-east-2';
const environment = 'staging';
const prefix = 'vortexbird-ecs-staging';
const taskArn = (role, revision) => `arn:aws:ecs:${region}:${accountId}:task-definition/${prefix}-${role}:${revision}`;
const digests = { backend: `sha256:${'b'.repeat(64)}`, frontend: `sha256:${'f'.repeat(64)}` };

function configuration() {
  return {
    accountId, region, environment,
    clusterArn: `arn:aws:ecs:${region}:${accountId}:cluster/${prefix}`,
    repositories: Object.fromEntries(['frontend', 'backend'].map(role => [role, `${accountId}.dkr.ecr.${region}.amazonaws.com/${prefix}-${role}`])),
    taskDefinitions: Object.fromEntries(roles.map(role => [role, taskArn(role, 7)])),
    migration: { taskDefinitionArn: taskArn('migration', 3), subnets: ['subnet-aabb', 'subnet-ccdd'], securityGroups: ['sg-aabb'] },
    portalOrigin: 'https://portal.example.test',
    oidcIssuer: 'https://identity.example.test/realms/vortexbird',
    targetGroups: Object.fromEntries(['api', 'frontend'].map(role => [role, `arn:aws:elasticloadbalancing:${region}:${accountId}:targetgroup/vb-ecs-${environment}-${role}/aabbccdd`]))
  };
}

function template(role, config = configuration()) {
  const family = `${prefix}-${role}`;
  const variables = role === 'frontend'
    ? { VITE_DEMO_AUTH: 'false', VITE_API_BASE_URL: '/api/v1' }
    : { Authentication__DemoEnabled: 'false', Database__Initialize: 'false', Seed__Enabled: 'false', Workers__Enabled: role === 'worker' ? 'true' : 'false' };
  return {
    family,
    taskDefinitionArn: role === 'migration' ? config.migration.taskDefinitionArn : config.taskDefinitions[role],
    revision: 7, status: 'ACTIVE', registeredAt: '2026-11-17T00:00:00Z', registeredBy: 'fixture',
    requiresAttributes: [{ name: 'fixture-response-only' }], compatibilities: ['FARGATE', 'EC2'],
    networkMode: 'awsvpc', requiresCompatibilities: ['FARGATE'],
    taskRoleArn: `arn:aws:iam::${accountId}:role/${family}-task`,
    executionRoleArn: `arn:aws:iam::${accountId}:role/${family}-execution`,
    cpu: role === 'frontend' ? '256' : '512', memory: role === 'frontend' ? '512' : '1024',
    runtimePlatform: { operatingSystemFamily: 'LINUX', cpuArchitecture: 'X86_64' },
    containerDefinitions: [{
      name: role, image: 'fixture.invalid/old@sha256:old', essential: true,
      environment: Object.entries(variables).map(([name, value]) => ({ name, value })),
      secrets: role === 'frontend' ? [] : [{ name: 'ConnectionStrings__Database', valueFrom: `arn:aws:secretsmanager:${region}:${accountId}:secret:${prefix}/${role}-fixture:database::` }],
      logConfiguration: { logDriver: 'awslogs', options: { 'awslogs-group': `/ecs/${prefix}/${role}`, 'awslogs-region': region, 'awslogs-stream-prefix': 'ecs' } },
      ...(role === 'migration' ? { command: ['--migrate'] } : {}),
      ...(role === 'worker' ? { healthCheck: { command: ['CMD', 'dotnet', 'VortexBird.API.dll', '--readiness-probe'], interval: 30, timeout: 8, retries: 3 } } : {})
    }]
  };
}

function stable(role, revision, config = configuration()) {
  return {
    serviceName: role, clusterArn: config.clusterArn, status: 'ACTIVE',
    deploymentController: { type: 'ECS' }, desiredCount: 1, runningCount: 1, pendingCount: 0,
    taskDefinition: revision,
    deployments: [{ status: 'PRIMARY', rolloutState: 'COMPLETED', taskDefinition: revision }]
  };
}

function fixture(options = {}) {
  const config = configuration();
  const previous = Object.fromEntries(roles.map(role => [role, taskArn(role, 5)]));
  const proposed = Object.fromEntries([...roles, 'migration'].map(role => [role, taskArn(role, 100)]));
  const state = Object.fromEntries(roles.map(role => [role, stable(role, previous[role], config)]));
  const calls = [], checkpoints = [], delays = [];
  const migrationArn = `arn:aws:ecs:${region}:${accountId}:task/${prefix}/${'a'.repeat(32)}`;
  let migrationReads = 0, serviceReads = 0, smokeCalls = 0;
  const context = { config, previous, proposed, state, calls, checkpoints, delays, migrationArn };
  const aws = async (service, command, request) => {
    calls.push({ service, command, request: copy(request) });
    if (service === 'sts' && command === 'get-caller-identity') return { Account: options.actualAccount || accountId };
    if (service === 'ecr' && command === 'describe-images') return { imageDetails: [{ imageDigest: request.imageIds[0].imageDigest }] };
    if (service === 'ecs' && command === 'describe-services') {
      serviceReads++;
      const override = options.describeServices?.({ ...context, serviceReads });
      return override ?? { failures: [], services: roles.map(role => copy(state[role])) };
    }
    if (service === 'ecs' && command === 'describe-task-definition') {
      const liveRole = roles.find(role => request.taskDefinition === previous[role]);
      if (liveRole) {
        const definition = template(liveRole, config);
        definition.taskDefinitionArn = previous[liveRole];
        const imageRole = liveRole === 'frontend' ? 'frontend' : 'backend';
        definition.containerDefinitions[0].image = `${config.repositories[imageRole]}@${options.runningDigest || digests[imageRole]}`;
        return { taskDefinition: definition };
      }
      const role = [...roles, 'migration'].find(item => request.taskDefinition === (item === 'migration' ? config.migration.taskDefinitionArn : config.taskDefinitions[item]));
      assert.ok(role, `Unexpected task template ${request.taskDefinition}`);
      return { taskDefinition: template(role, config) };
    }
    if (service === 'ecs' && command === 'register-task-definition') {
      const role = request.containerDefinitions[0].name;
      return { taskDefinition: { ...copy(request), taskDefinitionArn: proposed[role] } };
    }
    if (service === 'ecs' && command === 'run-task') return options.launchFailure
      ? { failures: [{ reason: 'RESOURCE:ENI' }], tasks: [] }
      : { failures: [], tasks: [{ taskArn: migrationArn }] };
    if (service === 'ecs' && command === 'describe-tasks' && request.tasks.includes(migrationArn)) {
      migrationReads++;
      if (migrationReads <= (options.migrationMissingReads || 0)) return { tasks: [], failures: [{ arn: migrationArn, reason: 'MISSING' }] };
      if (options.migrationNeverStops) return { failures: [], tasks: [{ taskArn: migrationArn, taskDefinitionArn: proposed.migration, lastStatus: 'RUNNING', containers: [{ name: 'migration', lastStatus: 'RUNNING' }] }] };
      return { failures: [], tasks: [{ taskArn: migrationArn, taskDefinitionArn: proposed.migration, lastStatus: 'STOPPED', containers: [{ name: 'migration', lastStatus: 'STOPPED', ...(options.migrationExitMissing ? {} : { exitCode: options.migrationExitCode ?? 0 }) }] }] };
    }
    if (service === 'ecs' && command === 'update-service') {
      await options.updateService?.({ ...context, request });
      state[request.service] = stable(request.service, request.taskDefinition, config);
      return { service: copy(state[request.service]) };
    }
    if (service === 'ecs' && command === 'list-tasks') return { taskArns: [`arn:aws:ecs:${region}:${accountId}:task/${prefix}/${'b'.repeat(32)}`] };
    if (service === 'ecs' && command === 'describe-tasks') return { failures: [], tasks: request.tasks.map(arn => ({ taskArn: arn, taskDefinitionArn: state.worker.taskDefinition, lastStatus: 'RUNNING', healthStatus: options.workerHealth || 'HEALTHY' })) };
    if (service === 'ecs' && command === 'stop-task') return { task: { taskArn: request.task, lastStatus: 'STOPPING' } };
    if (service === 'elbv2' && command === 'describe-target-health') return { TargetHealthDescriptions: [{ Target: { Id: '10.0.0.5', Port: 8080 }, TargetHealth: { State: options.targetHealth || 'healthy' } }] };
    assert.fail(`Unexpected mock AWS call: ${service} ${command}`);
  };
  const dependencies = {
    aws, pollAttempts: 5, pollDelayMs: 1,
    delay: async ms => { delays.push(ms); },
    checkpoint: async report => { checkpoints.push(copy(report)); },
    smoke: async current => {
      smokeCalls++;
      calls.push({ service: 'test', command: 'smoke', request: {} });
      assert.equal(current, config);
      return options.smoke ? options.smoke(context) : { fixture: 'passed' };
    }
  };
  return { ...context, dependencies, run: overrides => runRelease({ config, digests, releaseId: 'fixture-release-1', ...overrides }, dependencies), get smokeCalls() { return smokeCalls; } };
}

async function rejected(action) {
  try { await action(); } catch (error) { assert.ok(error.report, 'Release errors must retain a structured report'); return error; }
  assert.fail('Expected release to fail');
}

test('release migrates the proposed backend before registering/updating services and smoke', async () => {
  const f = fixture();
  const result = await f.run();
  assert.equal(result.status, 'released');
  assert.deepEqual(result.previous, f.previous);
  assert.deepEqual(result.proposed, Object.fromEntries(roles.map(role => [role, f.proposed[role]])));
  const migration = f.calls.find(call => call.command === 'run-task').request;
  assert.equal(migration.taskDefinition, f.proposed.migration);
  assert.equal(migration.count, 1);
  assert.equal(migration.networkConfiguration.awsvpcConfiguration.assignPublicIp, 'DISABLED');
  assert.match(migration.clientToken, /^[a-f0-9]{64}$/);
  const stopped = f.calls.findIndex(call => call.command === 'describe-tasks' && call.request.tasks.includes(f.migrationArn));
  const firstServiceDefinition = f.calls.findIndex(call => call.command === 'register-task-definition' && call.request.family.endsWith('-api'));
  const firstUpdate = f.calls.findIndex(call => call.command === 'update-service');
  assert.ok(stopped < firstServiceDefinition && firstServiceDefinition < firstUpdate);
  assert.equal(f.calls.at(-1).command, 'smoke');
  assert.deepEqual(result.stages.map(item => item.stage), ['preflight-passed', 'migration-start-requested', 'migration-passed', 'task-revisions-registered', 'service-update-requested', 'service-update-requested', 'service-update-requested', 'services-healthy', 'smoke-passed']);
  assert.equal(f.smokeCalls, 1);
});

test('migration nonzero or missing exit code blocks every service update', async t => {
  for (const options of [{ migrationExitCode: 17 }, { migrationExitMissing: true }]) {
    await t.test(JSON.stringify(options), async () => {
      const f = fixture(options);
      const error = await rejected(() => f.run());
      assert.match(error.report.failure, /Migration did not exit successfully/);
      assert.equal(error.report.status, 'failed');
      assert.equal(f.calls.filter(call => call.command === 'update-service').length, 0);
      assert.equal(f.smokeCalls, 0);
    });
  }
});

test('RunTask failure blocks polling, service updates and smoke', async () => {
  const f = fixture({ launchFailure: true });
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /rejected migration launch/);
  assert.equal(f.calls.filter(call => ['describe-tasks', 'update-service'].includes(call.command)).length, 0);
  assert.equal(f.smokeCalls, 0);
});

test('temporarily absent migration task is polled until a successful stopped task appears', async () => {
  const f = fixture({ migrationMissingReads: 2 });
  const report = await f.run();
  assert.equal(report.status, 'released');
  assert.equal(f.calls.filter(call => call.command === 'describe-tasks' && call.request.tasks.includes(f.migrationArn)).length, 3);
  assert.equal(f.delays.length, 2);
});

test('migration timeout stops only its task and never updates an application service', async () => {
  const f = fixture({ migrationNeverStops: true });
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /Migration timeout/);
  assert.deepEqual(f.calls.filter(call => call.command === 'stop-task').map(call => call.request.task), [f.migrationArn]);
  assert.equal(f.calls.filter(call => call.command === 'update-service').length, 0);
});

test('automatic ECS rollback cannot be mistaken for a successful release', async () => {
  let injected = false;
  const f = fixture({ describeServices: ({ state, proposed, previous }) => {
    if (!injected && roles.every(role => state[role].taskDefinition === proposed[role])) {
      state.worker = stable('worker', previous.worker);
      injected = true;
    }
  } });
  const error = await rejected(() => f.run());
  assert.equal(injected, true);
  assert.match(error.report.failure, /rollback|another revision/i);
  assert.notEqual(error.report.status, 'released');
  assert.equal(f.smokeCalls, 0);
});

test('a briefly stale DescribeServices response after UpdateService does not roll back a healthy release', async () => {
  let staleResponses = 0;
  const f = fixture({ describeServices: ({ state, proposed, previous }) => {
    if (roles.every(role => state[role].taskDefinition === proposed[role]) && staleResponses < 2) {
      staleResponses++;
      return { failures: [], services: roles.map(role => stable(role, previous[role])) };
    }
  } });
  const result = await f.run();
  assert.equal(result.status, 'released');
  assert.equal(staleResponses, 2);
  assert.equal(result.rollback.length, 0);
  assert.equal(f.calls.filter(call => call.command === 'update-service').length, 3);
});

test('failure updating the second service rolls back the first revision', async () => {
  const f = fixture({ updateService: ({ request, proposed }) => {
    if (request.service === 'worker' && request.taskDefinition === proposed.worker) throw new Error('fixture update rejected');
  } });
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /fixture update rejected/);
  assert.equal(error.report.status, 'rolled-back');
  assert.equal(f.state.api.taskDefinition, f.previous.api);
  assert.equal(f.calls.some(call => call.command === 'update-service' && call.request.service === 'frontend'), false);
  assert.equal(f.smokeCalls, 0);
});

test('smoke failure restores all previous task definitions', async () => {
  const f = fixture({ smoke: async () => { throw new Error('fixture smoke failed'); } });
  const error = await rejected(() => f.run());
  assert.equal(error.report.status, 'rolled-back');
  assert.deepEqual(roles.map(role => f.state[role].taskDefinition), roles.map(role => f.previous[role]));
  assert.equal(error.report.rollback.length, 3);
});

test('rollback failure stays failed and identifies the service that could not be restored', async () => {
  const f = fixture({
    smoke: async () => { throw new Error('fixture smoke failed'); },
    updateService: ({ request, previous }) => {
      if (request.service === 'frontend' && request.taskDefinition === previous.frontend) throw new Error('fixture rollback denied');
    }
  });
  const error = await rejected(() => f.run());
  assert.equal(error.report.status, 'failed');
  assert.deepEqual(error.report.rollback.find(item => item.service === 'frontend'), { service: 'frontend', status: 'failed', reason: 'fixture rollback denied' });
  assert.equal(f.state.frontend.taskDefinition, f.proposed.frontend);
  assert.equal(f.state.api.taskDefinition, f.previous.api);
});

test('rollback does not overwrite a revision installed concurrently by another deployer', async () => {
  const concurrent = taskArn('worker', 999);
  const f = fixture({ smoke: async ({ state }) => {
    state.worker = stable('worker', concurrent);
    throw new Error('fixture smoke failed');
  } });
  const error = await rejected(() => f.run());
  assert.equal(f.state.worker.taskDefinition, concurrent);
  assert.match(error.report.rollback.find(item => item.service === 'worker').reason, /Concurrent revision/);
  assert.equal(f.calls.some(call => call.command === 'update-service' && call.request.service === 'worker' && call.request.taskDefinition === f.previous.worker), false);
  assert.equal(error.report.status, 'failed');
});

test('wrong AWS account stops before migration or deployment', async () => {
  const f = fixture({ actualAccount: '999999999999' });
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /AWS account does not match/);
  assert.deepEqual(f.calls.map(call => call.command), ['get-caller-identity']);
});

test('configuration rejects an unrelated account, repository and mutable image reference', () => {
  const foreignAccount = configuration();
  foreignAccount.accountId = '999999999999';
  assert.throws(() => validateConfig(foreignAccount, digests), /Unexpected cluster/);
  const foreignRepository = configuration();
  foreignRepository.repositories.backend = `${accountId}.dkr.ecr.${region}.amazonaws.com/unrelated-project`;
  assert.throws(() => validateConfig(foreignRepository, digests), /outside this stack/);
  assert.throws(() => validateConfig(configuration(), { ...digests, backend: 'latest' }), /immutable sha256 digest/);
});

test('zero desired tasks are rejected before migration', async () => {
  const f = fixture();
  f.state.worker.desiredCount = 0;
  f.state.worker.runningCount = 0;
  assert.throws(() => assertStableService(f.state.worker, f.previous.worker), /Zero desired tasks/);
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /Zero desired tasks/);
  assert.equal(f.calls.some(call => call.command === 'run-task'), false);
});

test('task definition cloning preserves reviewed settings and drops AWS response-only fields', () => {
  const config = configuration();
  const source = template('worker', config);
  const before = copy(source);
  const request = cloneTaskDefinition(source, config, 'worker', digests.backend);
  for (const field of ['revision', 'status', 'taskDefinitionArn', 'registeredAt', 'registeredBy', 'compatibilities', 'requiresAttributes']) assert.equal(field in request, false, field);
  assert.deepEqual(request.containerDefinitions[0].healthCheck, source.containerDefinitions[0].healthCheck);
  assert.deepEqual(request.containerDefinitions[0].secrets, source.containerDefinitions[0].secrets);
  assert.equal(request.taskRoleArn, source.taskRoleArn);
  assert.equal(request.containerDefinitions[0].image, `${config.repositories.backend}@${digests.backend}`);
  assert.deepEqual(source, before, 'Cloning must not mutate the template');
});

test('task definition cloning rejects sidecars and unexpected IAM identities', () => {
  const source = template('api');
  source.taskRoleArn = `arn:aws:iam::${accountId}:role/Administrator`;
  assert.throws(() => cloneTaskDefinition(source, configuration(), 'api', digests.backend), /Unexpected task identity/);
  const sidecar = template('api');
  sidecar.containerDefinitions.push({ name: 'unreviewed', image: 'unreviewed:latest' });
  assert.throws(() => cloneTaskDefinition(sidecar, configuration(), 'api', digests.backend), /Unreviewed sidecars/);
});

test('migrate-only operation never registers or updates long-running application services', async () => {
  const f = fixture();
  const report = await f.run({ operation: 'migrate' });
  assert.equal(report.status, 'migration-completed');
  assert.equal(f.calls.some(call => ['describe-services', 'update-service'].includes(call.command)), false);
  assert.deepEqual(f.calls.filter(call => call.command === 'register-task-definition').map(call => call.request.family), [`${prefix}-migration`]);
  assert.equal(f.smokeCalls, 0);
});

test('verify checks running digests, service health and smoke without any AWS mutation', async () => {
  const f = fixture();
  const result = await f.run({ operation: 'verify' });
  assert.equal(result.status, 'verified');
  assert.deepEqual(f.calls.filter(call => call.command === 'describe-task-definition').map(call => call.request.taskDefinition), roles.map(role => f.previous[role]));
  assert.equal(f.calls.some(call => ['run-task', 'stop-task', 'register-task-definition', 'update-service'].includes(call.command)), false);
  assert.equal(f.smokeCalls, 1);
  assert.equal(result.rollback.length, 0);
});

test('verify rejects running images that differ from the reviewed digest without modifying services', async () => {
  const f = fixture({ runningDigest: `sha256:${'c'.repeat(64)}` });
  const error = await rejected(() => f.run({ operation: 'verify' }));
  assert.match(error.report.failure, /running image differs/);
  assert.equal(f.calls.some(call => ['run-task', 'stop-task', 'register-task-definition', 'update-service'].includes(call.command)), false);
  assert.equal(f.smokeCalls, 0);
});

test('initial administrator bootstrap is restricted to migrate and the reviewed OIDC issuer', () => {
  const config = configuration();
  const bootstrap = { issuer: config.oidcIssuer, subject: 'reviewed-oidc-subject', email: 'operator@example.test', displayName: 'Reviewed Operator' };
  assert.doesNotThrow(() => validateBootstrap(bootstrap, config, 'migrate'));
  assert.throws(() => validateBootstrap(bootstrap, config, 'release'), /migrate-only/);
  assert.throws(() => validateBootstrap({ ...bootstrap, issuer: 'https://unrelated.example.test/realms/vortexbird' }, config, 'migrate'), /reviewed identity/);
  assert.throws(() => validateBootstrap({ ...bootstrap, subject: 'demo-admin' }, config, 'migrate'));
});

function httpResponse(status, body, contentType = 'application/json') {
  return { status, headers: { get: name => name.toLowerCase() === 'content-type' ? contentType : null }, text: async () => typeof body === 'string' ? body : JSON.stringify(body), json: async () => body };
}

test('external smoke rejects HTTP 200 HTML served by the SPA fallback', async () => {
  const config = configuration();
  const requested = [];
  const fetcher = async (url, options) => {
    requested.push(url);
    assert.equal(options.redirect, 'error');
    if (url.endsWith('/health')) return httpResponse(200, 'ok', 'text/plain');
    return httpResponse(200, '<html>VortexBird</html>', 'text/html');
  };
  await assert.rejects(() => defaultSmoke(config, fetcher), /HTML fallback is not API health/);
  assert.deepEqual(requested, [`${config.portalOrigin}/health`, `${config.portalOrigin}/api/v1/auth/config`]);
});

test('external smoke verifies production auth, anonymous protection, issuer and PKCE', async () => {
  const config = configuration();
  const responses = new Map([
    [`${config.portalOrigin}/health`, httpResponse(200, 'ok', 'text/plain')],
    [`${config.portalOrigin}/api/v1/auth/config`, httpResponse(200, { demoEnabled: false, authority: config.oidcIssuer })],
    [`${config.portalOrigin}/api/v1/auth/me`, httpResponse(401, {})],
    [`${config.oidcIssuer}/.well-known/openid-configuration`, httpResponse(200, { issuer: config.oidcIssuer, code_challenge_methods_supported: ['S256'] })]
  ]);
  const result = await defaultSmoke(config, async url => {
    assert.ok(responses.has(url), `Unexpected HTTP request ${url}`);
    return responses.get(url);
  });
  assert.equal(result.oidcDiscovery, 'passed');
  assert.equal(result.humanOidcLogin, 'not-tested');
});

test('shared-host release verifies discovery under /auth and its public login endpoints', async () => {
  const config = configuration();
  config.oidcIssuer = `${config.portalOrigin}/auth/realms/vortexbird`;
  const protocol = `${config.oidcIssuer}/protocol/openid-connect`;
  const discovery = { issuer: config.oidcIssuer, code_challenge_methods_supported: ['S256'],
    authorization_endpoint: `${protocol}/auth`, token_endpoint: `${protocol}/token`,
    end_session_endpoint: `${protocol}/logout`, jwks_uri: `${protocol}/certs` };
  const fetcher = async url => {
    switch (url) {
      case `${config.portalOrigin}/health`: return httpResponse(200, 'ok', 'text/plain');
      case `${config.portalOrigin}/api/v1/auth/config`: return httpResponse(200, { demoEnabled: false, authority: config.oidcIssuer });
      case `${config.portalOrigin}/api/v1/auth/me`: return httpResponse(401, {});
      case `${config.oidcIssuer}/.well-known/openid-configuration`: return httpResponse(200, discovery);
      default: throw new Error('Unexpected HTTP request');
    }
  };
  assert.equal((await defaultSmoke(config, fetcher)).oidcDiscovery, 'passed');
  discovery.token_endpoint = discovery.token_endpoint.replace('/auth/realms/', '/realms/');
  await assert.rejects(defaultSmoke(config, fetcher), /unexpected token_endpoint/);
  assert.throws(() => validateConfig({ ...config, oidcIssuer: config.oidcIssuer.replace('/auth/', '/') }, digests), /shared-host issuer path/);
});

test('unhealthy worker prevents smoke and release success', async () => {
  const f = fixture({ workerHealth: 'UNHEALTHY' });
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /Service health timeout/);
  assert.notEqual(error.report.status, 'released');
  assert.equal(f.smokeCalls, 0);
});

test('an unhealthy ALB target prevents smoke and release success', async () => {
  const f = fixture({ targetHealth: 'unhealthy' });
  const error = await rejected(() => f.run());
  assert.match(error.report.failure, /Service health timeout/);
  assert.notEqual(error.report.status, 'released');
  assert.equal(f.smokeCalls, 0);
  for (const call of f.calls.filter(item => item.command === 'describe-target-health')) {
    assert.ok(Object.values(f.config.targetGroups).includes(call.request.TargetGroupArn));
  }
});

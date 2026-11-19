const test = require('node:test');
const assert = require('node:assert/strict');
const { describePrerequisites } = require('../scripts/describe-ecs-prerequisites.cjs');
const input = () => ({ accountId: '123456789012', region: 'us-east-2', environment: 'staging', repository: 'fixture/vortexbird-infrastructure', stateBucket: 'vortexbird-fixture-state', oidcProviderArn: 'arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com' });
test('proposed OIDC trust grants only one exact repository and reviewed environment', () => {
  const result = describePrerequisites(input());
  assert.equal(result.awsRequestsExecuted, 0);
  for (const [kind, role] of Object.entries(result.roles)) {
    const condition = role.trustPolicy.Statement[0].Condition.StringEquals;
    assert.equal(condition['token.actions.githubusercontent.com:sub'], `repo:fixture/vortexbird-infrastructure:environment:ecs-staging-${kind}`);
    assert.equal(condition['token.actions.githubusercontent.com:aud'], 'sts.amazonaws.com');
  }
});
test('state policy permits deletion only of its lock and separates plan/apply writes', () => {
  const result = describePrerequisites(input());
  for (const role of [result.roles.plan, result.roles.apply]) {
    const deletions = role.statePolicy.Statement.filter(statement => statement.Action.includes('s3:DeleteObject'));
    assert.equal(deletions.length, 1);
    assert.ok(deletions[0].Resource.endsWith('/vortexbird/ecs/staging/terraform.tfstate.tflock'));
    assert.ok(!JSON.stringify(role.statePolicy).includes('AdministratorAccess'));
  }
  assert.deepEqual(result.roles.plan.statePolicy.Statement.find(statement => statement.Sid === 'StateObject').Action, ['s3:GetObject']);
  assert.deepEqual(result.roles.apply.statePolicy.Statement.find(statement => statement.Sid === 'StateObject').Action, ['s3:GetObject', 's3:PutObject']);
});
test('missing or broad repository, unrelated provider and unrelated bucket fail before output', () => {
  for (const change of [{ repository: 'fixture/*' }, { repository: undefined }, { accountId: 'root' }, { stateBucket: 'other-project-state' }, { oidcProviderArn: 'arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com' }]) {
    assert.throws(() => describePrerequisites({ ...input(), ...change }));
  }
});

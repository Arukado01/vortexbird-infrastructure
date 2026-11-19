// Pure preparation: never runs AWS, Terraform, GitHub, or a shell command.
const assert = require('node:assert/strict');
const fs = require('node:fs');

function describePrerequisites(input) {
  const { accountId, region, environment, repository, stateBucket, oidcProviderArn } = input;
  assert.match(accountId, /^\d{12}$/, 'An observed account ID is required');
  assert.match(region, /^[a-z]{2}-[a-z]+-\d$/);
  assert.ok(['development', 'staging', 'production'].includes(environment));
  assert.match(repository, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, 'Supply the exact infrastructure repository, without wildcard');
  assert.match(stateBucket, /^vortexbird-[a-z0-9][a-z0-9-]{0,51}[a-z0-9]$/, 'Choose an explicitly approved dedicated VortexBird bucket name');
  assert.equal(oidcProviderArn, `arn:aws:iam::${accountId}:oidc-provider/token.actions.githubusercontent.com`, 'Supply the observed GitHub OIDC provider ARN in this account');
  const prefix = `vortexbird-ecs-${environment}`;
  const stateKey = `vortexbird/ecs/${environment}/terraform.tfstate`;
  const bucketArn = `arn:aws:s3:::${stateBucket}`;
  const roles = Object.fromEntries(['plan', 'apply', 'release'].map(kind => {
    const environmentName = `ecs-${environment}-${kind}`;
    return [kind, {
      proposedName: `${prefix}-github-${kind}`,
      proposedArn: `arn:aws:iam::${accountId}:role/${prefix}-github-${kind}`,
      githubEnvironment: environmentName,
      trustPolicy: { Version: '2012-10-17', Statement: [{ Effect: 'Allow', Principal: { Federated: oidcProviderArn }, Action: 'sts:AssumeRoleWithWebIdentity', Condition: { StringEquals: {
        'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
        'token.actions.githubusercontent.com:sub': `repo:${repository}:environment:${environmentName}`
      } } }] }
    }];
  }));
  const statePolicy = write => ({ Version: '2012-10-17', Statement: [
    { Sid: 'ListOnlyThisStatePrefix', Effect: 'Allow', Action: ['s3:ListBucket'], Resource: bucketArn, Condition: { StringEquals: { 's3:prefix': [stateKey, `${stateKey}.tflock`] } } },
    { Sid: 'StateObject', Effect: 'Allow', Action: write ? ['s3:GetObject', 's3:PutObject'] : ['s3:GetObject'], Resource: `${bucketArn}/${stateKey}` },
    { Sid: 'StateLockObject', Effect: 'Allow', Action: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'], Resource: `${bucketArn}/${stateKey}.tflock` }
  ] });
  roles.plan.statePolicy = statePolicy(false);
  roles.apply.statePolicy = statePolicy(true);
  return {
    status: 'review-only-not-applied', awsRequestsExecuted: 0,
    accountId, region, environment, repository,
    state: {
      proposedBucket: stateBucket, key: stateKey, lockKey: `${stateKey}.tflock`, useLockfile: true,
      requirements: { dedicatedToProject: true, region, versioning: 'Enabled', objectOwnership: 'BucketOwnerEnforced', blockPublicAcls: true, ignorePublicAcls: true, blockPublicPolicy: true, restrictPublicBuckets: true, defaultEncryption: 'AES256', credentialsInBackendConfiguration: false },
      denyInsecureTransportPolicy: { Version: '2012-10-17', Statement: [{ Effect: 'Deny', Principal: '*', Action: 's3:*', Resource: [bucketArn, `${bucketArn}/*`], Condition: { Bool: { 'aws:SecureTransport': 'false' } } }] }
    },
    roles,
    readOnlyChecks: [
      ['sts', 'get-caller-identity'],
      ['iam', 'get-open-id-connect-provider', '--open-id-connect-provider-arn', oidcProviderArn],
      ...['get-bucket-location', 'get-bucket-versioning', 'get-bucket-encryption', 'get-public-access-block', 'get-bucket-ownership-controls', 'get-bucket-policy'].map(operation => ['s3api', operation, '--bucket', stateBucket]),
      ...Object.values(roles).map(role => ['iam', 'get-role', '--role-name', role.proposedName])
    ],
    unresolved: [
      'Names and trust documents are proposals, not evidence that a bucket or role exists.',
      'Verify existing OIDC audience and provider configuration; do not replace or duplicate an account provider.',
      'Protect each GitHub environment with reviewers and main-only branch rules before assuming its role.',
      'Terraform plan/apply resource policies must be derived from the reviewed resource plan; no AdministratorAccess or generic service wildcard grants are generated.',
      'Release needs scoped ECS/ECR/ALB reads and deployment actions plus PassRole only for application/migration roles; see ecs-release.md.',
      'The read-only plan state policy must not be used for state migrations/imports. Those require a separately approved operator.',
      'Customer-managed KMS, cross-account access, recovery and retention need separate explicit policy review if selected.',
      'Local acceptance, DNS/ACM, immutable images, SQL bootstrap, secret values and budget approval remain independent gates.'
    ],
    references: ['https://developer.hashicorp.com/terraform/language/backend/s3', 'https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html']
  };
}

module.exports = { describePrerequisites };
if (require.main === module) {
  try {
    assert.equal(process.argv.length, 3, 'Pass one reviewed JSON file containing accountId, region, environment, repository, stateBucket and oidcProviderArn');
    const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
    console.log(JSON.stringify(describePrerequisites(input), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function makeContract(input) {
  assert.equal(input.ref, 'refs/heads/main', 'Identity publication is restricted to main');
  assert.ok(['development', 'staging', 'production'].includes(input.environment), 'Unsupported environment');
  assert.match(input.accountId || '', /^\d{12}$/, 'Expected AWS account is required');
  assert.match(input.region || '', /^[a-z]{2}-[a-z]+-\d$/, 'Expected AWS region is required');
  assert.match(input.keycloakImage || '', /^quay\.io\/keycloak\/keycloak:26\.8\.2@sha256:[a-f0-9]{64}$/, 'Use the reviewed official Keycloak 26.8.2 digest');
  assert.match(input.caSha256 || '', /^[a-fA-F0-9]{64}$/, 'The independently reviewed public CA checksum is required');
  assert.match(input.commit || '', /^[a-f0-9]{40}$/, 'Full source commit required');
  assert.match(input.runId || '', /^\d+$/, 'Invalid run ID');
  assert.match(input.runAttempt || '', /^\d+$/, 'Invalid run attempt');
  const name = `vortexbird-ecs-${input.environment}`;
  assert.equal(input.roleArn, `arn:aws:iam::${input.accountId}:role/${name}-identity-publish`, 'Expected dedicated identity publish role required');
  const repositoryName = `${name}-identity`;
  const registry = `${input.accountId}.dkr.ecr.${input.region}.amazonaws.com`;
  const imageTag = `git-${input.commit}-run-${input.runId}-${input.runAttempt}`;
  return {
    accountId: input.accountId, region: input.region, environment: input.environment,
    roleArn: input.roleArn, repositoryName, registry,
    repositoryUri: `${registry}/${repositoryName}`, imageTag,
    localImage: `vortexbird-keycloak:${imageTag}`, keycloakImage: input.keycloakImage,
    caSha256: input.caSha256.toLowerCase(), commit: input.commit,
    runId: input.runId, runAttempt: input.runAttempt,
  };
}

function assertRepository(contract, response) {
  assert.equal(response.repositories?.length, 1, 'Exactly one existing ECR repository must be returned');
  const repo = response.repositories[0];
  assert.equal(repo.registryId, contract.accountId, 'ECR account mismatch');
  assert.equal(repo.repositoryName, contract.repositoryName, 'ECR repository mismatch');
  assert.equal(repo.repositoryUri, contract.repositoryUri, 'ECR region/URI mismatch');
  assert.equal(repo.repositoryArn, `arn:aws:ecr:${contract.region}:${contract.accountId}:repository/${contract.repositoryName}`, 'ECR ARN mismatch');
  assert.equal(repo.imageTagMutability, 'IMMUTABLE', 'ECR tags must be immutable without exclusions');
  return repo;
}

function publicationEvidence(contract, response, localDigests) {
  assert.equal(response.imageDetails?.length, 1, 'Expected one published ECR image');
  const image = response.imageDetails[0];
  assert.equal(image.registryId, contract.accountId);
  assert.equal(image.repositoryName, contract.repositoryName);
  assert.ok(image.imageTags?.includes(contract.imageTag), 'ECR response does not contain this run tag');
  assert.match(image.imageDigest || '', /^sha256:[a-f0-9]{64}$/);
  const imageUri = `${contract.repositoryUri}@${image.imageDigest}`;
  assert.ok(Array.isArray(localDigests) && localDigests.includes(imageUri), 'ECR digest differs from the image pushed by this runner');
  return { schemaVersion: 1, status: 'published', environment: contract.environment,
    accountId: contract.accountId, region: contract.region, repository: contract.repositoryName,
    imageTag: contract.imageTag, imageDigest: image.imageDigest, imageUri,
    keycloakBaseImage: contract.keycloakImage, rdsCaSha256: contract.caSha256,
    sourceCommit: contract.commit, runId: contract.runId, runAttempt: contract.runAttempt,
    checks: ['realm-static-validation', 'public-ca-checksum-and-validity', 'container-vulnerability-and-secret-scan'],
    deployed: false };
}

function fromEnvironment(env = process.env) {
  return makeContract({ ref: env.GITHUB_REF, environment: env.TARGET, accountId: env.AWS_ACCOUNT_ID,
    region: env.AWS_REGION, roleArn: env.IDENTITY_PUBLISH_ROLE_ARN, keycloakImage: env.KEYCLOAK_IMAGE,
    caSha256: env.RDS_CA_SHA256, commit: env.GITHUB_SHA, runId: env.GITHUB_RUN_ID, runAttempt: env.GITHUB_RUN_ATTEMPT });
}

if (require.main === module) {
  try {
    const contract = fromEnvironment();
    const [operation, inputFile, digestFile] = process.argv.slice(2);
    if (operation === '--prepare') {
      assert.ok(process.env.GITHUB_OUTPUT && process.env.RUNNER_TEMP, 'GitHub runner paths are required');
      fs.appendFileSync(process.env.GITHUB_OUTPUT, Object.entries({
        repository: contract.repositoryName, registry: contract.registry, image_tag: contract.imageTag,
        local_image: contract.localImage, remote_image: `${contract.repositoryUri}:${contract.imageTag}`,
      }).map(([key, value]) => `${key}=${value}\n`).join(''));
      fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'identity-publish-contract.json'), JSON.stringify(contract, null, 2));
    } else if (operation === '--verify-repository') {
      assertRepository(contract, JSON.parse(fs.readFileSync(inputFile, 'utf8')));
    } else if (operation === '--record-digest') {
      const evidence = publicationEvidence(contract, JSON.parse(fs.readFileSync(inputFile, 'utf8')), JSON.parse(fs.readFileSync(digestFile, 'utf8')));
      fs.writeFileSync('identity-publication.json', JSON.stringify(evidence, null, 2) + '\n');
      assert.ok(process.env.GITHUB_OUTPUT);
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `digest=${evidence.imageDigest}\nimage_uri=${evidence.imageUri}\n`);
    } else throw new Error('Expected --prepare, --verify-repository FILE or --record-digest ECR_FILE LOCAL_DIGESTS_FILE');
  } catch (error) {
    console.error(`Identity publication contract failed: ${error.message}`);
    process.exitCode = 1;
  }
}
module.exports = { makeContract, assertRepository, publicationEvidence };

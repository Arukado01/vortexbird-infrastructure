'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');
const { makeContract, assertRepository, publicationEvidence } = require('../scripts/identity-publish-contract.cjs');
const root = path.join(__dirname, '..');
const input = { ref:'refs/heads/main', environment:'staging', accountId:'123456789012', region:'us-east-2',
  roleArn:'arn:aws:iam::123456789012:role/vortexbird-ecs-staging-identity-publish',
  keycloakImage:`quay.io/keycloak/keycloak:26.8.2@sha256:${'a'.repeat(64)}`, caSha256:'B'.repeat(64),
  commit:'c'.repeat(40), runId:'123', runAttempt:'1' };
const contract = makeContract(input);
const repository = { repositories:[{registryId:input.accountId,repositoryName:contract.repositoryName,
  repositoryUri:contract.repositoryUri,repositoryArn:`arn:aws:ecr:us-east-2:123456789012:repository/${contract.repositoryName}`,
  imageTagMutability:'IMMUTABLE'}] };
const digest = `sha256:${'d'.repeat(64)}`;
const image = { imageDetails:[{registryId:input.accountId,repositoryName:contract.repositoryName,imageTags:[contract.imageTag],imageDigest:digest}] };
const workflowFile = '.github/workflows/publish-identity.yml';
const workflowText = fs.readFileSync(path.join(root, workflowFile), 'utf8');
const workflow = YAML.parse(workflowText);

test('identity contract produces only the environment-specific repository and unique run tag', () => {
  assert.equal(contract.repositoryName, 'vortexbird-ecs-staging-identity');
  assert.equal(contract.caSha256, 'b'.repeat(64));
  assert.match(contract.imageTag, /^git-[a-f0-9]{40}-run-123-1$/);
});
test('contract rejects non-main refs and unsupported environments', () => {
  for (const override of [{ref:'refs/pull/1/merge'},{environment:'test'}]) assert.throws(() => makeContract({...input,...override}));
});
test('contract rejects mutable, foreign and wrong-version Keycloak sources', () => {
  for (const keycloakImage of ['quay.io/keycloak/keycloak:26.8.2',input.keycloakImage.replace('26.8.2','26.4.0'),input.keycloakImage.replace('quay.io','evil.example')]) {
    assert.throws(() => makeContract({...input,keycloakImage}));
  }
});
test('contract rejects malformed account, public CA checksum and source identifiers', () => {
  for (const override of [{accountId:'*'},{region:'us-east-2; echo fail'},{caSha256:'unknown'},{commit:'main'},{runId:'1\npwn'},{runAttempt:'1;id'}]) {
    assert.throws(() => makeContract({...input,...override}));
  }
});
test('dedicated publish role must exactly match account and environment', () => {
  for (const roleArn of [input.roleArn.replace('staging','production'),input.roleArn.replace('123456789012','999999999999'),'arn:aws:iam::123456789012:role/Admin']) assert.throws(() => makeContract({...input,roleArn}));
});
test('existing ECR repository must match account, region, ARN, name and immutable mode', () => {
  assertRepository(contract, repository);
  for (const override of [{registryId:'999999999999'},{repositoryName:'auxo'},{repositoryUri:'evil.example/repo'},{repositoryArn:'*'},{imageTagMutability:'MUTABLE'},{imageTagMutability:'IMMUTABLE_WITH_EXCLUSION'}]) {
    assert.throws(() => assertRepository(contract,{repositories:[{...repository.repositories[0],...override}]}));
  }
  assert.throws(() => assertRepository(contract,{repositories:[]}));
});
test('published evidence compares ECR digest with the image pushed by this runner', () => {
  const evidence = publicationEvidence(contract,image,[`${contract.repositoryUri}@${digest}`]);
  assert.equal(evidence.deployed,false);
  assert.equal(evidence.imageDigest,digest);
  assert.equal(evidence.keycloakBaseImage,input.keycloakImage);
  assert.throws(() => publicationEvidence(contract,image,[`${contract.repositoryUri}@sha256:${'e'.repeat(64)}`]));
});
test('published evidence rejects foreign images, missing run tags and malformed digests', () => {
  for (const override of [{registryId:'999999999999'},{repositoryName:'pge'},{imageTags:['latest']},{imageDigest:'sha256:no'}]) {
    assert.throws(() => publicationEvidence(contract,{imageDetails:[{...image.imageDetails[0],...override}]},[`${contract.repositoryUri}@${digest}`]));
  }
});
test('publication is manual main-only and requires the dedicated protected environment', () => {
  assert.deepEqual(Object.keys(workflow.on),['workflow_dispatch']);
  assert.equal(workflow.jobs.publish.if,"github.ref == 'refs/heads/main'");
  assert.equal(workflow.jobs.publish.environment,'ecs-${{ inputs.environment }}-identity-publish');
  assert.equal(workflow.concurrency['cancel-in-progress'],false);
  const gate = workflow.jobs.publish.steps.find(s => s.with?.script?.includes('assertDeploymentEnvironment'));
  assert.ok(gate?.with.script.includes('getEnvironment'));
  assert.equal(workflow.permissions['id-token'],undefined);
});
test('JSON validation, Linux syntax, reviewed CA and blocking scan precede AWS credentials and push', () => {
  const steps = workflow.jobs.publish.steps;
  const index = text => steps.findIndex(s => JSON.stringify(s).includes(text));
  const auth = index('configure-aws-credentials');
  for (const marker of ['assertDeploymentEnvironment','--prepare','Validate-Cloud.ps1','bash -n','Build-Image.ps1','trivy-action']) assert.ok(index(marker) >= 0 && index(marker) < auth,marker);
  assert.ok(auth < index('--verify-repository'));
  assert.ok(index('--verify-repository') < index('docker push'));
  assert.ok(index('docker push') < index('--record-digest'));
  const scan = steps.find(s => s.uses?.startsWith('aquasecurity/trivy-action@'));
  assert.match(scan.uses,/@[a-f0-9]{40}$/);
  assert.equal(scan.with['exit-code'],'1');
  assert.equal(scan.with.scanners,'vuln,secret');
  assert.equal(scan.with['ignore-unfixed'],false);
  assert.equal(scan['continue-on-error'],undefined);
  assert.equal(steps[auth].with['allowed-account-ids'],'${{ env.AWS_ACCOUNT_ID }}');
});
test('publication workflow never provisions cloud resources or deploys services', () => {
  assert.doesNotMatch(workflowText,/create-repository|create-role|put-secret-value|terraform (apply|plan)|update-service|register-task-definition/);
  assert.match(workflowText,/describe-repositories/);
  assert.match(workflowText,/describe-images/);
  assert.equal(workflow.jobs.publish.outputs.image_uri,'${{ steps.publication.outputs.image_uri }}');
});
test('security evidence excludes raw secret matches and workflow inputs are not interpolated into shell code', () => {
  const steps = workflow.jobs.publish.steps;
  const summary = steps.find(s => s.name?.startsWith('Summarize security'));
  assert.equal(summary.if,'always()');
  assert.match(summary.run,/vulnerabilities\.map\(v => \(\{id:v\.VulnerabilityID,severity:v\.Severity\}\)\)/);
  assert.doesNotMatch(summary.run,/MatchedLine|Match|StartLine|EndLine/);
  assert.match(summary.run,/fs\.rmSync\(source\)/);
  const artifact = steps.find(s => s.uses?.startsWith('actions/upload-artifact@'));
  assert.doesNotMatch(artifact.with.path,/raw|runner\.temp/);
  for (const step of steps) if(step.run) assert.doesNotMatch(step.run,/\$\{\{\s*inputs\./);
});
test('the reviewed plan receives every optional identity setting from its GitHub environment', () => {
  const planWorkflow = YAML.parse(fs.readFileSync(path.join(root, '.github/workflows/ecs-plan.yml'), 'utf8'));
  const identityVariables = fs.readFileSync(path.join(root, 'terraform-ecs/identity-variables.tf'), 'utf8');
  const step = planWorkflow.jobs.plan.steps.find(item => item.name === 'Generate plan for review');
  for (const [, name] of identityVariables.matchAll(/^variable "(identity_\w+)"/gm)) {
    const source = 'ECS_' + name.toUpperCase() + (name === 'identity_admin_cidrs' ? '_JSON' : '');
    assert.equal(step.env['TF_VAR_' + name], '${{ vars.' + source + ' }}', name);
  }
  const planStart = step.run.indexOf('terraform -chdir=terraform-ecs plan');
  assert.ok(planStart > 0);
  const beforePlan = step.run.slice(0, planStart);
  assert.match(beforePlan, /for name in "\$\{!TF_VAR_identity_@\}"; do/);
  assert.match(beforePlan, /if \[\[ -z "\$\{!name\}" \]\]; then unset "\$name"; fi/);
  assert.doesNotMatch(JSON.stringify(planWorkflow.jobs.apply), /TF_VAR_identity_/);
});

test('saved-plan TLS verification is a blocking step after account/hash checks and before apply', () => {
  const planText = fs.readFileSync(path.join(root,'.github/workflows/ecs-plan.yml'),'utf8');
  const apply = YAML.parse(planText).jobs.apply.steps;
  const index = text => apply.findIndex(s => JSON.stringify(s).includes(text));
  const gate = index('preflight-identity-tls.cjs');
  assert.ok(index('sha256sum --check') < gate);
  assert.ok(index('get-caller-identity') < gate);
  assert.ok(gate < index('apply -input=false approved.tfplan'));
  assert.match(apply[gate].run,/show -json approved\.tfplan/);
  assert.match(apply[gate].run,/--plan-json.*reviewed-ecs-plan\.json/);
  assert.match(apply[gate].run,/--expected-account "\$\(cat ecs-plan\.account\)"/);
  assert.match(apply[gate].run,/--expected-region "\$AWS_REGION"/);
  assert.equal(apply[gate]['continue-on-error'],undefined);
  const artifact = apply.find(s => s.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(artifact.with.path,'identity-tls-preflight.json');
  assert.ok(apply.some(s => s.if === 'always()' && s.run?.includes('rmSync')));
});

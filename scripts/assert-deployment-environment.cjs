'use strict';
function assertDeploymentEnvironment(environment, expectedName) {
  if (!environment || environment.name !== expectedName) throw new Error('The target deployment environment could not be verified.');
  const reviewers = environment.protection_rules?.find(rule => rule.type === 'required_reviewers');
  if (!reviewers?.reviewers?.length) throw new Error('Apply requires an environment with required reviewers. No AWS credentials have been assumed.');
  const branches = environment.deployment_branch_policy;
  if (!branches?.protected_branches && !branches?.custom_branch_policies) throw new Error('Apply requires restricted deployment branches in the environment.');
  return true;
}
module.exports = { assertDeploymentEnvironment };

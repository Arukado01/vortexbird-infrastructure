const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const root = resolve(__dirname, '../terraform-ecs');
const config = readFileSync(resolve(root, 'identity.tf'), 'utf8');
const variables = readFileSync(resolve(root, 'identity-variables.tf'), 'utf8');
const outputs = readFileSync(resolve(root, 'identity-outputs.tf'), 'utf8');

// Extract balanced HCL blocks without requiring provider processes or account calls.
function block(source, header) {
  const start = source.indexOf(header);
  assert(start >= 0, `Missing ${header}`);
  let depth = 0, quoted = false, escaped = false;
  const first = source.indexOf('{', start);
  for (let i = first; i < source.length; i++) {
    const c = source[i];
    if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; continue; }
    if (c === '"') { quoted = true; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return source.slice(first, i + 1);
  }
  throw Error(`Unbalanced ${header}`);
}
const resource = (type, name) => block(config, `resource "${type}" "${name}"`);
const variable = name => block(variables, `variable "${name}"`);

test('identity provisioning and service startup are independently opt-in', () => {
  for (const name of ['identity_enabled', 'identity_deploy_service', 'identity_bootstrap_admin_enabled', 'identity_manage_dns', 'identity_request_certificate']) assert.match(variable(name), /default\s*=\s*false/);
  assert.match(config, /identity_create\s*=\s*var.identity_enabled\s*\?\s*1\s*:\s*0/);
  assert.match(config, /identity_run\s*=\s*var.identity_enabled\s*&&\s*var.identity_deploy_service/);
});

test('the identity database is dedicated, encrypted, private and protected', () => {
  const db = resource('aws_db_instance', 'identity');
  assert.match(db, /publicly_accessible\s*=\s*false/);
  assert.match(db, /storage_encrypted\s*=\s*true/);
  assert.match(db, /manage_master_user_password\s*=\s*true/);
  assert.match(db, /deletion_protection\s*=\s*true/);
  assert.match(db, /skip_final_snapshot\s*=\s*false/);
  assert.match(resource('aws_db_subnet_group', 'identity'), /local.data_subnets/);
});

test('identity tasks never receive a public IP or the RDS master secret', () => {
  assert.match(resource('aws_ecs_service', 'identity'), /assign_public_ip\s*=\s*false/);
  assert.match(resource('aws_ecs_service', 'identity'), /local.app_subnets/);
  const task = resource('aws_ecs_task_definition', 'identity');
  assert.doesNotMatch(task, /master_user_secret/);
  assert.match(task, /sslmode=verify-full/);
  assert.match(task, /rds-ca-bundle\.pem/);
});

test('only the ALB can reach identity HTTP and management ports', () => {
  const ingress = resource('aws_vpc_security_group_ingress_rule', 'identity_alb');
  assert.match(ingress, /\["8080", "9000"\]/);
  assert.match(ingress, /referenced_security_group_id\s*=\s*aws_security_group.tier\["alb"\].id/);
  assert.doesNotMatch(ingress, /cidr_ipv4/);
  assert.match(resource('aws_lb_target_group', 'identity'), /port\s*=\s*8080/);
  assert.match(resource('aws_lb_target_group', 'identity'), /path\s*=\s*"\/health\/ready"/);
  assert.match(resource('aws_lb_target_group', 'identity'), /port\s*=\s*"9000"/);
});

test('public identity routes are allowlisted and all other host routes deny', () => {
  const pub = resource('aws_lb_listener_rule', 'identity');
  assert.match(pub, /host_header/);
  assert.match(pub, /"\/realms\/\*", "\/resources\/\*", "\/\.well-known\/\*"/);
  assert.doesNotMatch(pub, /\/admin/);
  assert.match(resource('aws_lb_listener_rule', 'identity_default_deny'), /status_code\s*=\s*"403"/);
  assert.match(resource('aws_lb_listener_rule', 'identity_admin_deny'), /status_code\s*=\s*"403"/);
});

test('admin access defaults closed and requires narrow explicit source ranges', () => {
  assert.match(variable('identity_admin_cidrs'), /default\s*=\s*\[\]/);
  assert.match(variable('identity_admin_cidrs'), /length\(var.identity_admin_cidrs\)\s*<=\s*2/);
  assert.match(variable('identity_admin_cidrs'), />=\s*24/);
  const admin = resource('aws_lb_listener_rule', 'identity_admin_allow');
  assert.match(admin, /length\(var.identity_admin_cidrs\)\s*>\s*0/);
  assert.match(admin, /source_ip/);
});

test('identity host rules precede the shared API path rule', () => {
  assert.match(resource('aws_lb_listener_rule', 'identity'), /priority\s*=\s*5/);
  assert.match(resource('aws_lb_listener_rule', 'identity_default_deny'), /priority\s*=\s*6/);
  const compute = readFileSync(resolve(root, 'compute.tf'), 'utf8');
  assert.match(block(compute, 'resource "aws_lb_listener_rule" "api"'), /priority\s*=\s*10/);
});

test('DNS and certificate actions use an explicit owned zone without overwrite', () => {
  assert.match(variable('identity_dns_zone_id'), /default\s*=\s*null/);
  assert.match(block(config, 'data "aws_route53_zone" "identity"'), /!self.private_zone/);
  assert.match(block(config, 'data "aws_route53_zone" "identity"'), /endswith\(var.identity_hostname/);
  assert.match(resource('aws_route53_record', 'identity'), /allow_overwrite\s*=\s*false/);
  assert.match(resource('aws_route53_record', 'identity_certificate'), /allow_overwrite\s*=\s*false/);
});

test('Terraform owns secret metadata only and the task role has no policies', () => {
  assert.doesNotMatch(config, /resource\s+"aws_secretsmanager_secret_version"/);
  assert.doesNotMatch(config, /data\s+"aws_secretsmanager_secret_version"/);
  assert.doesNotMatch(config, /secret_string\s*=/);
  assert.doesNotMatch(config, /role\s*=\s*aws_iam_role.identity_task/);
  assert.doesNotMatch(outputs, /secret_string|\.password|\.username/);
});

test('bootstrap admin injection is temporary and separate from runtime database credentials', () => {
  const task = resource('aws_ecs_task_definition', 'identity');
  assert.match(task, /identity_bootstrap_admin_enabled\s*\?/);
  assert.match(task, /KC_BOOTSTRAP_ADMIN_PASSWORD/);
  assert.match(task, /identity\["bootstrap-admin"\]/);
  assert.match(task, /identity\["database"\]/);
  assert.doesNotMatch(task, /name\s*=\s*"KC_BOOTSTRAP_ADMIN_PASSWORD"\s*,\s*value\s*=/);
});

test('the task requires immutable ECR image and consistent HTTPS issuer settings', () => {
  const task = resource('aws_ecs_task_definition', 'identity');
  assert.match(variable('identity_image_digest'), /sha256:/);
  assert.match(task, /repository_url\}@/);
  assert.match(task, /KC_HOSTNAME\s*=\s*local.identity_base_url/);
  assert.match(task, /var.keycloak_url\s*==\s*local.identity_base_url/);
  assert.match(task, /var.identity_shared_host\s*\?\s*var.portal_origin\s*==\s*local.identity_origin/);
  assert.match(task, /var.portal_origin\s*!=\s*local.identity_origin/);
  assert.match(task, /\["start", "--optimized", "--import-realm"\]/);
  assert.match(task, /VORTEXBIRD_PORTAL_ORIGIN\s*=\s*var.portal_origin/);
  assert.match(task, /var.portal_origin\s*!=\s*null/);
  assert.doesNotMatch(task, /start-dev|:latest/);
});

test('readiness, logs and deployment rollback are configured without advertising proof of runtime', () => {
  assert.match(resource('aws_ecs_task_definition', 'identity'), /healthCheck/);
  assert.match(resource('aws_ecs_task_definition', 'identity'), /\/health\/ready/);
  assert.match(resource('aws_ecs_task_definition', 'identity'), /awslogs-group/);
  assert.match(resource('aws_ecs_service', 'identity'), /rollback\s*=\s*true/);
  assert.match(outputs, /Presence is not evidence of a successful login/);
});

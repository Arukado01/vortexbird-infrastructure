// Static configuration validation; does not contact Docker, Kubernetes, AWS or Terraform providers.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const YAML = require('yaml');
const root = path.resolve(__dirname, '..');
const results = [];
const parsed = new Map();
const check = (name, fn) => { try { fn(); results.push({ name, status:'passed' }); } catch(e) { results.push({ name,status:'failed',error:e.message }); } };
const source = file => fs.readFileSync(path.join(root,file),'utf8');
const candidates = [...fs.readdirSync(root).filter(name=>/^compose(?:\.[\w-]+)?\.ya?ml$/.test(name)), ...['kubernetes','observability','.github/workflows'].flatMap(dir=>fs.readdirSync(path.join(root,dir)).filter(name=>/\.ya?ml$/.test(name)).map(name=>`${dir}/${name}`))];
for(const file of candidates) check(`YAML parse: ${file}`,()=>{
  const docs=YAML.parseAllDocuments(source(file),{uniqueKeys:true});
  assert.equal(docs.flatMap(d=>d.errors).length,0,docs.flatMap(d=>d.errors).map(e=>e.message).join('; '));
  parsed.set(file,docs.map(d=>d.toJS()));
});
const kubernetes=[...parsed.entries()].filter(([file])=>file.startsWith('kubernetes/')).flatMap(([,docs])=>docs);
const deployments=kubernetes.filter(d=>d?.kind==='Deployment');
for(const deployment of deployments) check(`Pod boundaries and health checks: ${deployment.metadata.name}`,()=>{
  const spec=deployment.spec.template.spec;
  assert.equal(spec.securityContext.runAsNonRoot,true);
  assert.equal(spec.securityContext.seccompProfile.type,'RuntimeDefault');
  for(const container of spec.containers){
    assert.equal(container.securityContext.allowPrivilegeEscalation,false);
    assert.ok(container.securityContext.capabilities.drop.includes('ALL'));
    assert.ok(container.resources.requests.cpu && container.resources.requests.memory);
    assert.ok(container.resources.limits.cpu && container.resources.limits.memory);
    assert.ok(container.readinessProbe && container.livenessProbe);
  }
});
for(const service of kubernetes.filter(d=>d?.kind==='Service')) check(`Service target port resolves: ${service.metadata.name}`,()=>{
  const targets=deployments.filter(d=>Object.entries(service.spec.selector).every(([key,val])=>d.spec.template.metadata.labels[key]===val));
  assert.ok(targets.length>0,'No deployment matches service selector');
  const ports=targets.flatMap(d=>d.spec.template.spec.containers.flatMap(c=>c.ports||[]));
  for(const port of service.spec.ports)assert.ok(ports.some(p=>p.name===port.targetPort||p.containerPort===port.targetPort),'Unknown targetPort');
});
check('Production backend disables demo and schema bootstrap',()=>{
  const backend=deployments.find(d=>d.metadata.name==='backend').spec.template.spec.containers[0];
  const env=Object.fromEntries(backend.env.map(e=>[e.name,e.value]));
  assert.equal(env.Authentication__DemoEnabled,'false');
  assert.equal(env.Database__Initialize,'false');
  assert.equal(env.Authentication__RequireHttpsMetadata,'true');
  assert.equal(env.Seed__Enabled,'false');
  assert.match(backend.image,/^\$\{BACKEND_IMAGE\}$/);
});
check('Kubernetes render inputs cover all manifest placeholders',()=>{
  const render=source('scripts/Render-Kubernetes.ps1');
  for(const [file] of parsed) if(file.startsWith('kubernetes/')) for(const match of source(file).matchAll(/\$\{([A-Z_]+)\}/g)) assert.ok(render.includes(`'${match[1]}'`),`Missing ${match[1]}`);
});
check('Default-deny network policy includes ingress and egress',()=>{
  const deny=kubernetes.find(d=>d.kind==='NetworkPolicy'&&d.metadata.name==='default-deny');
  assert.deepEqual(deny.spec.podSelector,{});assert.deepEqual([...deny.spec.policyTypes].sort(),['Egress','Ingress']);
});
check('Local published ports are bound to loopback',()=>{
  for(const [file,docs] of parsed) if(file.startsWith('compose'))for(const [name,service] of Object.entries(docs[0].services))for(const port of service.ports||[])assert.match(port,/^127\.0\.0\.1:/,`${file}: ${name}`);
});
check('Local bootstrap and production CORS use backend configuration keys',()=>{
  const env=parsed.get('compose.yaml')[0].services.backend.environment;
  assert.equal(env.ASPNETCORE_ENVIRONMENT,'Development');
  assert.equal(env.Database__Initialize,'true');
  assert.equal(env.Seed__Enabled,'true');
  assert.ok(env.Cors__AllowedOrigins__0);
});
check('SQS emulator is opt-in and matches the backend transport configuration',()=>{
  const base=parsed.get('compose.yaml')[0].services;
  assert.ok(!base.elasticmq);
  assert.ok(!base.backend.environment.Messaging__ServiceUrl);
  const sqs=parsed.get('compose.sqs.yaml')[0].services;
  assert.equal(sqs.elasticmq.image,'softwaremill/elasticmq-native:1.6.12');
  assert.ok(sqs.elasticmq.volumes.includes('./messaging/elasticmq.conf:/opt/elasticmq.conf:ro'));
  const env=sqs.backend.environment;
  assert.equal(env.Messaging__Provider,'sqs');
  assert.equal(env.Messaging__ServiceUrl,'http://elasticmq:9324');
  assert.equal(env.Messaging__QueueUrl,'http://elasticmq:9324/000000000000/vortexbird-events');
  assert.equal(env.Messaging__Region,'us-east-2');
  assert.equal(env.Messaging__VisibilityTimeoutSeconds,'120');
  assert.equal(env.Messaging__MaxAttempts,'5');
  assert.equal(env.AWS_ACCESS_KEY_ID,'local-emulator-only');
  assert.equal(env.AWS_SECRET_ACCESS_KEY,'local-emulator-only');
  assert.equal(env.AWS_EC2_METADATA_DISABLED,'true');
});
check('Emulator config declares matching queue, DLQ and 1.x visibility/redrive options',()=>{
  const config=source('messaging/elasticmq.conf');
  assert.match(config,/vortexbird-events-dlq\s*\{/);
  assert.match(config,/vortexbird-events\s*\{/);
  assert.match(config,/defaultVisibilityTimeout\s*=\s*120 seconds/);
  assert.match(config,/receiveMessageWait\s*=\s*20 seconds/);
  assert.match(config,/deadLettersQueue\s*\{\s*name\s*=\s*"vortexbird-events-dlq"\s*maxReceiveCount\s*=\s*5/);
  assert.match(config,/accountId\s*=\s*"000000000000"/);
  assert.match(config,/region\s*=\s*"us-east-2"/);
});
check('Production SQS uses Pod Identity and has no local endpoint or static credentials',()=>{
  const backend=deployments.find(d=>d.metadata.name==='backend').spec.template.spec;
  const env=Object.fromEntries(backend.containers[0].env.map(e=>[e.name,e.value]));
  assert.equal(backend.serviceAccountName,'backend');
  assert.equal(env.Messaging__Provider,'sqs');
  assert.equal(env.Messaging__QueueUrl,'${QUEUE_URL}');
  assert.equal(env.Messaging__Region,'us-east-2');
  assert.equal(env.Messaging__VisibilityTimeoutSeconds,'120');
  assert.equal(env.Messaging__MaxAttempts,'5');
  for(const key of ['Messaging__ServiceUrl','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_ROLE_ARN','AWS_WEB_IDENTITY_TOKEN_FILE'])assert.ok(!(key in env),key);
  const sa=kubernetes.find(d=>d.kind==='ServiceAccount'&&d.metadata.name==='backend');
  assert.ok(!sa.metadata.annotations?.['eks.amazonaws.com/role-arn']);
  const secrets=kubernetes.find(d=>d.kind==='SecretProviderClass'&&d.metadata.name==='backend-aws-secrets');
  assert.equal(secrets.spec.parameters.usePodIdentity,'true');
});
check('Pod Identity link-local endpoint is allowed only for backend egress',()=>{
  const policy=kubernetes.find(d=>d.kind==='NetworkPolicy'&&d.metadata.name==='backend-pod-identity');
  assert.deepEqual(policy.spec.podSelector,{matchLabels:{app:'backend'}});
  assert.deepEqual(policy.spec.policyTypes,['Egress']);
  assert.deepEqual(policy.spec.egress,[{to:[{ipBlock:{cidr:'169.254.170.23/32'}}],ports:[{protocol:'TCP',port:80}]}]);
});
check('Pod Identity source declares agent, association and scoped role trust',()=>{
  const identity=source('terraform/pod-identity.tf');
  assert.match(identity,/resource "aws_eks_addon" "pod_identity"/);
  assert.match(identity,/addon_name\s*=\s*"eks-pod-identity-agent"/);
  assert.match(identity,/resource "aws_eks_pod_identity_association" "backend"/);
  assert.match(identity,/namespace\s*=\s*"vortexbird"/);
  assert.match(identity,/service_account\s*=\s*"backend"/);
  assert.match(identity,/disable_session_tags\s*=\s*false/);
  assert.match(identity,/service_name\s*=\s*"com\.amazonaws\.\$\{var\.region\}\.eks-auth"/);
  const compute=source('terraform/compute.tf');
  const role=compute.slice(compute.indexOf('resource "aws_iam_role" "backend"'),compute.indexOf('resource "aws_iam_role_policy" "backend"'));
  assert.match(role,/Service = "pods\.eks\.amazonaws\.com"/);
  assert.match(role,/"sts:AssumeRole", "sts:TagSession"/);
  assert.match(role,/"aws:RequestTag\/eks-cluster-arn" = aws_eks_cluster\.main\.arn/);
  assert.match(role,/"aws:RequestTag\/kubernetes-namespace" = "vortexbird"/);
  assert.match(role,/"aws:RequestTag\/kubernetes-service-account" = "backend"/);
  assert.ok(!role.includes('AssumeRoleWithWebIdentity'));
});
check('Payments stay simulated by default and sandbox requires explicit local credentials',()=>{
  const base=parsed.get('compose.yaml')[0].services.backend.environment;
  assert.equal(base.Payments__Provider,'Simulator');
  assert.ok(!base.Payments__Sandbox__Enabled);
  const env=parsed.get('compose.payments-sandbox.yaml')[0].services.backend.environment;
  assert.equal(env.Payments__Provider,'MercadoPagoSandbox');
  assert.equal(env.Payments__Sandbox__Enabled,'${MP_SANDBOX_ENABLED:-false}');
  for(const key of ['AccessToken','ExpectedTestSellerId','WebhookSecret','NotificationUrl','ReturnUrl'])assert.match(env[`Payments__Sandbox__${key}`],/^\$\{MP_[A-Z_]+:\?.+\}$/);
  const example=source('payments/sandbox.env.example');
  for(const line of example.split(/\r?\n/).filter(line=>line && !line.startsWith('#'))){const [key,value]=line.split('=');assert.equal(value,key==='MP_SANDBOX_ENABLED'?'false':'',key);}
  assert.ok(source('.gitignore').split(/\r?\n/).includes('.env.*'));
});
check('OIDC portal uses PKCE, audience and server-controlled identity claims',()=>{
  const realm=JSON.parse(source('keycloak/vortexbird-realm.json'));
  const portal=realm.clients.find(c=>c.clientId==='vortexbird-portal');
  assert.equal(portal.attributes['pkce.code.challenge.method'],'S256');
  assert.equal(portal.directAccessGrantsEnabled,false);assert.equal(portal.implicitFlowEnabled,false);
  assert.equal(realm.revokeRefreshToken,true);assert.equal(realm.refreshTokenMaxReuse,0);
  assert.ok(portal.protocolMappers.some(m=>m.config['included.custom.audience']==='vortexbird-api'));
  assert.ok(portal.protocolMappers.some(m=>m.config['claim.name']==='identity_type'&&m.config['claim.value']==='human'));
  const profile=JSON.parse(realm.components['org.keycloak.userprofile.UserProfileProvider'][0].config['kc.user.profile.config'][0]);
  for(const name of ['partner_id','channel_id'])assert.ok(!profile.attributes.find(a=>a.name===name).permissions.edit.includes('user'));
});
check('Apply is manual, main-only, uses exact plan and protected environment',()=>{
  const workflow=parsed.get('.github/workflows/plan-apply.yml')[0];
  assert.ok(workflow.on.workflow_dispatch);
  assert.equal(workflow.on.workflow_dispatch.inputs.apply.default,false);
  const apply=workflow.jobs.apply;
  assert.match(apply.if,/inputs\.apply/);assert.match(apply.if,/refs\/heads\/main/);
  assert.equal(apply.environment,'${{ inputs.environment }}');
  const gate=apply.steps.findIndex(s=>s.name?.includes('Fail closed'));
  const credentials=apply.steps.findIndex(s=>s.uses?.startsWith('aws-actions/configure-aws-credentials'));
  assert.ok(gate>=0 && gate<credentials);
  assert.ok(apply.steps.some(s=>s.run?.includes('sha256sum --check plan.sha256')));
  assert.ok(apply.steps.some(s=>s.run?.includes('-lockfile=readonly')));
  assert.ok(apply.steps.some(s=>s.run==='terraform -chdir=terraform apply -input=false approved.tfplan'));
  assert.ok(!apply.steps.some(s=>s.run?.includes('-auto-approve')));
  const upload=workflow.jobs.plan.steps.find(s=>s.uses?.startsWith('actions/upload-artifact'));
  assert.equal(upload.with['include-hidden-files'],true);
  assert.ok(upload.with.path.includes('terraform/.terraform.lock.hcl'));
});
const report={generatedAt:new Date().toISOString(),kind:'static-configuration',yamlFiles:parsed.size,yamlDocuments:[...parsed.values()].reduce((n,docs)=>n+docs.length,0),passed:results.filter(r=>r.status==='passed').length,failed:results.filter(r=>r.status==='failed').length,results,limitations:['No Terraform grammar/provider/schema validation: executable unavailable','ElasticMQ HOCON checked for expected fields only; no emulator parser/runtime validation','No Docker image build or containers started','No Kubernetes API or controller validation','No AWS authentication, inventory, plan, apply or deployment performed','No external sandbox payment account or webhook validation performed']};
fs.writeFileSync(path.join(root,'reports/infrastructure-validation.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({passed:report.passed,failed:report.failed,yamlFiles:report.yamlFiles,yamlDocuments:report.yamlDocuments,failures:results.filter(r=>r.status==='failed')},null,2));
if(report.failed)process.exitCode=1;

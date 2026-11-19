# Release ECS: migración, digest, salud y rollback

Esta implementación es ejecutable y tiene pruebas locales con respuestas AWS controladas. **No acredita un despliegue real**. No se ejecutaron estas operaciones contra AWS durante su implementación. Antes de usarlas deben estar superadas las pruebas locales, revisado el plan de recursos y aprobado el presupuesto. La cuenta o región observadas en una sesión de navegador no se convierten automáticamente en autorización para crear recursos.

## Contrato y separación de responsabilidades

Terraform administra red, RDS, IAM, secretos vacíos, ALB, servicios y **plantillas** de tareas. El release administra la revisión de tarea que usa cada servicio. `ignore_changes=[desired_count, task_definition]` evita que un apply posterior revierta silenciosamente un release. Cada release lee las plantillas recién exportadas por Terraform, conservando cambios de entorno, roles, secretos y probes, y modifica únicamente la imagen por digest. No clona permanentemente una revisión antigua ignorando cambios de infraestructura.

El contenedor `migration` usa la imagen backend y el comando `--migrate`, con roles IAM, grupo de seguridad y secreto propios. No recibe tráfico del ALB, no tiene permisos SQS y no inicia API ni workers. Su conexión usa un propietario del esquema dedicado, distinto del maestro RDS y de los usuarios runtime. `migration_runtime_roles` identifica los roles existentes de API y worker para conceder permisos limitados. El backend valida esos límites y aplica las migraciones bajo exclusión mutua.

Los secretos `api`, `worker` y `migration` se rellenan fuera de Terraform. Cada JSON contiene `database`; API/worker pueden incluir `redis` cuando se habilita esa caché. Para RDS, usar `SSL Mode=VerifyFull;Root Certificate=/app/certs/aws-rds-global-bundle.pem` en las conexiones; el build backend debe haber incorporado el bundle oficial. No poner valores de conexión, contraseñas ni certificados privados en variables Terraform, CLI, commits, logs o artefactos.

La base inicial `vortexbird` de RDS pertenece al usuario maestro y no satisface el contrato del migrator. El procedimiento `../vortexbird-backend/scripts/provision-postgres.sql` crea una base nueva independiente, por ejemplo `vortexbird_app`, cuyo dueño es migrator. Los tres secretos deben usar esa misma base nueva. No se transfiere automáticamente la propiedad de la base inicial ni se reutilizan bases de otros proyectos.

## Primera instalación

1. Aplicar únicamente el plan de infraestructura aprobado, inicialmente con `deploy_services=false`. Preparar identidad/TLS y roles SQL mediante un proceso autorizado dentro de la VPC. El job de migración no crea contraseñas ni sustituye ese bootstrap de RDS.
2. Construir y probar frontend/backend, analizar seguridad, publicar en los repositorios ECR propios y conservar ambos digests. El release rechaza tags y repositorios de otra cuenta/stack. No publica imágenes por su cuenta ni considera un digest prueba suficiente de calidad.
3. Aplicar el plan aprobado que establece los digests y crea la tarea migradora, todavía sin servicios. Exportar `release_contract` mediante Terraform. No inventar ARNs, IDs de subredes, grupos ni URLs.
4. Ejecutar `operation=migrate`. Opcionalmente habilitar el bootstrap explícito de un administrador **ya existente en Keycloak**, usando el subject OIDC exacto, email, nombre e issuer HTTPS. Esto no crea un usuario de Keycloak, no usa contraseñas y no importa datos de demo. El comando backend es `--migrate --bootstrap-admin`; el issuer debe coincidir con el contrato de identidad. El backend rechaza reemplazar otro administrador existente.
5. Con esquema, secretos, usuario inicial, Keycloak y TLS verificados, aplicar el plan aprobado `deploy_services=true`. Ejecutar `operation=verify` para confirmar las revisiones/digests y el smoke sin volver a migrar ni desplegar.

El primer servicio no tiene una versión previa sana a la cual regresar. La operación `release` exige tres servicios existentes y estables con réplicas positivas; no presenta el bootstrap inicial como un rollout con rollback garantizado.

## Releases posteriores

`scripts/release-ecs.cjs` ejecuta esta secuencia:

1. Compara la cuenta STS con el contrato, valida región/cluster/recurso, digests ECR y estado inicial de los tres servicios. Rechaza despliegues concurrentes o réplicas cero y guarda las revisiones previas.
2. Registra la tarea migradora con el mismo digest backend que utilizarán API y worker. Ejecuta una sola tarea Fargate privada, con token de idempotencia y sin IP pública.
3. Consulta la tarea con espera acotada y tolerancia a consistencia eventual. Exige `STOPPED` y código **0** del contenedor migrador. Un timeout, tarea ausente o fallo bloquea el rollout; solicita detener únicamente la tarea iniciada por este release si no puede confirmar que terminó.
4. Registra las revisiones de API, worker y frontend preservando la configuración de las plantillas. Antes de actualizar cada servicio comprueba que su revisión no cambió desde el preflight.
5. Espera réplicas completas, cero pendientes, un deployment PRIMARY `COMPLETED` y la **revisión nueva exacta**. Comprueba contenedores del worker `HEALTHY` y targets ALB saludables. Una lectura transitoria de la revisión anterior se tolera hasta tres consultas; una revisión ajena bloquea la operación.
6. Ejecuta smoke HTTPS: `/health` devuelve `ok`; `/api/v1/auth/config` es JSON, demo está deshabilitada e issuer correcto; `/api/v1/auth/me` rechaza anónimos con 401; discovery Keycloak confirma issuer y PKCE S256.
7. Si falla rollout o smoke, restaura únicamente los servicios cuyo update se intentó, en orden inverso, y verifica las revisiones previas y su salud. Si un tercero cambió entretanto una revisión, no la sobrescribe: reporta el conflicto.

**El rollback no revierte esquemas.** Las migraciones deben ser compatibles con la versión anterior mediante cambios expand/contract. Un rollback solicitado pero cuya salud no pudo confirmarse queda como fallo, nunca como recuperación completada.

No consultar `/health/ready` a través del dominio del portal para validar API: el ALB solo envía `/api/*` al backend y una SPA puede devolver HTML con 200. La salud de la API se comprueba mediante su target group y JSON real. Discovery no equivale a login humano, renovación de tokens, RBAC ni recorrido de negocio: esas pruebas requieren la suite funcional contra el ambiente.

## Uso local del operador autorizado

```powershell
# Después de un apply aprobado; salida sin valores de secretos.
terraform -chdir=terraform-ecs output -json release_contract > ../.work/ecs-release-contract.json

# Reemplazar los argumentos digest por los SHA256 realmente publicados/revisados.
node scripts/release-ecs.cjs --config ../.work/ecs-release-contract.json `
  --backend-digest $BackendDigest --frontend-digest $FrontendDigest --validate-only

# Solo tras la aprobación de ese release y sus costos.
node scripts/release-ecs.cjs --config ../.work/ecs-release-contract.json `
  --backend-digest $BackendDigest --frontend-digest $FrontendDigest `
  --operation release --release-id $ReleaseId --report ../.work/ecs-release-result.json --execute

# Primer bootstrap: --operation migrate, backend digest, y opcionalmente
# --bootstrap-config <archivo-privado.json>. No requiere frontend digest.
# Verificación posterior sin mutaciones: --operation verify y ambos digests.
```

El archivo privado de bootstrap tiene las claves `subject`, `email`, `displayName` e `issuer`. No contiene credenciales y no se incluye en la evidencia. La evidencia registra cuenta, región, digests, tareas/revisiones, etapas, resultado de smoke y rollback. No registra tokens, conexiones ni la identidad del administrador. `--validate-only` no consulta AWS y no acredita que los IDs existan.

## Workflow y permisos

`.github/workflows/ecs-release.yml` admite ejecución manual y `workflow_call`. El job de release requiere `main`, environment `ecs-<entorno>-release` con revisores y ramas restringidas comprobados antes de asumir el rol OIDC. Terraform y release comparten la misma exclusión por entorno, sin cancelación automática. La prueba local de orquestación corre antes del job protegido.

Variables del environment: `AWS_ACCOUNT_ID`, `AWS_REGION`, `ECS_RELEASE_ROLE_ARN`, `ECS_RELEASE_CONTRACT_JSON`. Bootstrap opcional usa el secreto de environment `ECS_BOOTSTRAP_ADMIN_JSON`. La configuración del environment debe corresponder al `release_contract` real exportado; no se genera desde nombres aproximados. En una invocación reusable entre repositorios, revisar explícitamente el checkout del repositorio de infraestructura y su commit: el workflow actual espera esos scripts en el repositorio ejecutado. La llamada más directa es despachar este workflow en el propio repositorio de infraestructura después de las comprobaciones de build/publicación.

El rol OIDC de release aún debe configurarse en la cuenta con trust restringida al repositorio y environment. Necesita:

- `sts:GetCallerIdentity` y `ecr:DescribeImages` sobre los dos repositorios esperados.
- Lectura ECS (`DescribeServices`, `DescribeTaskDefinition`, `ListTasks`, `DescribeTasks`) y `elasticloadbalancing:DescribeTargetHealth`.
- `ecs:RegisterTaskDefinition` con tags Project/Environment, `ecs:TagResource`, y actualización exclusivamente de `api`, `worker`, `frontend` del cluster revisado.
- `ecs:RunTask` exclusivamente para la familia migradora y el cluster revisado; `ecs:StopTask` exclusivamente para tareas del cluster; sin crear servicios ni redes.
- `iam:PassRole` exclusivamente para los ocho roles task/execution de API, worker, frontend y migración, condicionado a `iam:PassedToService=ecs-tasks.amazonaws.com`.

El rol de release **no necesita** leer valores Secrets Manager ni administrar infraestructura. Algunos permisos Describe/Register requieren `Resource=*` por el modelo IAM de AWS; restringirlos mediante condiciones compatibles y revisar la política efectiva. Este documento no sustituye una prueba de mínimo privilegio en la cuenta.

## Preparación de estado e identidades sin crear recursos

`scripts/describe-ecs-prerequisites.cjs` lee un JSON revisado con `accountId`, `region`, `environment`, `repository`, `stateBucket` y el `oidcProviderArn` realmente observado. Produce propuestas de trust OIDC por environment, políticas S3 limitadas al objeto de estado/bloqueo y requisitos de versionado, cifrado y bloqueo público. También enumera comandos de inspección de solo lectura, pero **no los ejecuta**. No genera una política Terraform administrativa genérica ni afirma que los recursos existan.

```powershell
node scripts/describe-ecs-prerequisites.cjs ../.work/reviewed-aws-prerequisites.json > ../.work/ecs-prerequisites-review.json
npm run test:prerequisites
```

El nombre de bucket y repositorio deben elegirse/revisarse explícitamente; el generador no los deduce de otros proyectos de la cuenta. Si el proveedor GitHub OIDC ya existe, verificarlo sin reemplazarlo. La creación del bucket/roles y cualquier política de recursos Terraform permanecen sujetas al plan y autorización correspondientes. Referencias oficiales: [estado S3](https://developer.hashicorp.com/terraform/language/backend/s3) y [trust OIDC](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html).

## Límites de esta entrega

Las pruebas de `npm run test:release` inyectan respuestas controladas y verifican orden de operaciones y fallos; no consumen recursos AWS. Terraform fue formateado sin reintentar el proveedor bloqueado. El release real, IAM efectivo, red, CA RDS, migración productiva, bootstrap OIDC, salud, rollback y resultados de negocio siguen pendientes de ejecución autorizada y verificable. La opción de identidad/TLS administrada por Terraform es independiente y debe revisarse por sus recursos/costos adicionales antes de habilitarla.

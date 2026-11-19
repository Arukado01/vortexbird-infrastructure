# Piloto ECS Fargate

Este directorio define el despliegue inicial. La raíz hermana `terraform/` conserva EKS como alternativa con estado independiente. Los perfiles `development`, `staging` y `production` usan redes distintas. Los tres ejecutan la aplicación en modo Production de ASP.NET y deshabilitan la autenticación de demo.

El ALB enruta `/api/*` a la API y las rutas restantes al frontend. Las tareas se ejecutan sin IP pública en dos subredes de aplicación. RDS PostgreSQL 17 y el Redis TLS opcional usan subredes de datos sin salida predeterminada. El worker usa la imagen del backend con `Workers__Enabled=true` y queda fuera del ALB. La API escribe el outbox con `Workers__Enabled=false`. Cada servicio escala por CPU de forma independiente. El circuit breaker de ECS revierte un despliegue fallido.

El [procedimiento de release ECS](../ecs-release.md) incorpora una tarea migradora separada (`--migrate`), bootstrap administrativo explícito, despliegue por digest, comprobación de la revisión y salud, smoke HTTPS y rollback de las revisiones anteriores. Hay modos independientes `migrate`, `release` y `verify`. Las pruebas locales no equivalen a un despliegue. La migración usa su propio secreto/rol y el mismo digest backend que API/worker; el release no revierte el esquema.

| Identidad | Alcance |
| --- | --- |
| Task Role del worker | Envío, recepción, cambio de visibilidad y confirmación sobre la cola de eventos. |
| Task Roles de API y frontend | Sin permisos de aplicación en AWS. El navegador descarga CSV directamente. |
| Task/Execution Roles de migración | Task sin permisos de aplicación AWS; Execution lee únicamente el secreto de migración, imagen backend y su grupo de logs. |
| Execution Roles | Autenticación ECR, lectura de la imagen propia y escritura en su grupo de logs. API y worker pueden inyectar solo su propio secreto. |
| Rol del operador | Redrive y observación operativa mediante un rol separado que se configura fuera del stack. |
| Rol GitHub de plan | OIDC y lecturas de cuenta y estado. El flujo publica el plan para revisión. |

Los secretos de Secrets Manager se crean vacíos. Carga el JSON de cada servicio fuera de Terraform con las claves `database` y, cuando esté habilitado el grupo ACL de Redis, `redis`. Para PostgreSQL usa roles limitados de ejecución distintos del usuario maestro y del rol de migración. El cliente debe confiar en la CA de RDS y verificar el hostname. Para Redis usa una URL `rediss` con un usuario ACL limitado. Si hay KMS propio, autoriza al Execution Role en la política de esa clave. La rotación de secretos inyectados requiere una nueva revisión de tareas.

## Validar sin cuenta AWS

```powershell
terraform -chdir=terraform-ecs fmt -check -recursive
terraform -chdir=terraform-ecs init -backend=false -input=false
terraform -chdir=terraform-ecs validate
terraform -chdir=terraform-ecs test
```

Las pruebas construyen planes con proveedor simulado para el arranque y la configuración de servicios. Verifican la red privada, la topología del ALB, la separación de roles y el redrive configurado. La evaluación de IAM, cuotas, DNS, certificados e imágenes en AWS requiere un plan real y pruebas después de un despliegue autorizado.

## Preparar el primer despliegue

1. Configura una cuenta, región, bucket S3 de estado existente con cifrado y versionado y rutas de estado `vortexbird/ecs/<entorno>/terraform.tfstate`. Revisa costos de ALB, NAT, RDS, ECR, logs, tres servicios Fargate y, si aplica, Redis. El perfil productivo usa NAT por AZ, RDS Multi-AZ y un mínimo de dos tareas por servicio.
2. Genera el plan inicial con `deploy_services=false` y solicita aprobación para el plan y costo concretos. Ese plan incluye VPC, NAT, ALB, RDS, Secrets Manager y ECR aunque los servicios estén deshabilitados.
3. Prepara Keycloak, dominio y ACM en la región del ALB. Registra redirects y web origins exactos y configura SMTP. Publica las dos imágenes en ECR y conserva sus digests. Inicializa roles RDS limitados, secretos y los esquemas desde una ubicación autorizada en la VPC antes de habilitar servicios.
4. Con los requisitos listos, presenta un nuevo plan con `deploy_services=true`, `certificate_arn`, `portal_origin`, `keycloak_url`, `image_digests` y, si aplica, `redis_user_group_id`. Adjunta el alias DNS tras autorización. El listener HTTP solo redirige cuando hay certificado ACM.
5. Verifica salud del portal, API y worker, permisos IAM y renovación de credenciales. Ensaya recuperación, entrega de colas, rollback a digest anterior y rotación de secretos antes del piloto.

El flujo `ecs-plan.yml` admite los tres perfiles y conserva un plan binario revisable mediante OIDC, su representación, hash, commit, lockfile, cuenta y destino del estado. `apply=false` es el valor inicial. El apply solo puede ejecutarse desde `main`, contra `ecs-<entorno>-apply` con revisores y ramas restringidas comprobados antes de asumir credenciales. Usa exactamente el plan guardado, exige la misma cuenta/región/bucket/entorno y nunca genera un plan nuevo durante apply. El ambiente de plan requiere `ECS_PLAN_ROLE_ARN` y `TF_STATE_BUCKET`; el de apply usa `ECS_APPLY_ROLE_ARN`. Los inputs de despliegue se toman de las variables `ECS_*` del ambiente de plan. Los artefactos sensibles se retienen un día.

La compuerta del environment no aprueba automáticamente costos ni acredita dependencias. El revisor debe comprobar presupuesto, Keycloak/ACM/DNS, secretos, roles de datos, migraciones y administrador inicial antes de un plan con servicios. El flujo de infraestructura no construye imágenes; `ecs-release.yml` incorpora migración y smoke de aplicación como ejecución independiente protegida. Su ejecución remota real sigue pendiente. Los roles OIDC deben existir con permisos mínimos; no están provisionados por este stack. No se ejecutaron estos workflows en AWS.

Fuentes: [Roles IAM de ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-iam-role-overview.html), [Execution Role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html), [Circuit breaker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service).

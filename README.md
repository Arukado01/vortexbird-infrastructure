# VortexBird Infrastructure

El objetivo inicial en AWS es **ECS Fargate**. Empieza por [terraform-ecs/README.md](terraform-ecs/README.md) para los tres perfiles, IAM, datos, pruebas y preparación del piloto. Los archivos `terraform/`, `kubernetes/` y `plan-apply.yml` siguientes corresponden a la alternativa EKS. Compose sigue siendo la opción local.

## Revisión de ejecución del 17 de noviembre de 2026

La última validación de configuración pasó 36 comprobaciones y las 6 pruebas de compuerta CI. `Test-Configuration.ps1` confirmó configuración Keycloak y Compose. Terraform `fmt -check` pasó; `validate` y `test` no pudieron cargar el esquema del proveedor AWS (plugin sin respuesta), por lo que los resultados históricos posteriores no acreditan una ejecución actual exitosa. El flujo ECS conserva y aplica el plan exacto solo tras revisión del environment, comparación de cuenta/estado/commit y entrada manual; aún no fue ejecutado en GitHub/AWS.

La continuación incorpora [release ECS de aplicación](ecs-release.md): tarea migradora aislada, modo bootstrap explícito, revisiones por digest, salud de servicios/targets y smoke con rollback de task definitions anteriores. `npm run test:release` pasa **26/26** casos con respuestas AWS controladas; no ejecuta AWS ni conexiones de red. El modo `verify` comprueba digests y salud sin mutaciones. El release real y el login humano OIDC siguen pendientes de ejecución; los workflows no conceden autorización presupuestaria por sí solos.

El arranque Docker quedó bloqueado por acceso al motor. La alternativa [nativa Windows](native-runtime.md) incorpora PostgreSQL, API/worker, portal, Keycloak y ElasticMQ con parada por identidad de procesos; Redis queda deshabilitado como caché opcional. `Start-Native.ps1 -ValidateOnly` pasó. El arranque integral sigue sin comprobarse por restricciones de sockets y bootstrap PostgreSQL incompleto. El launcher Docker ahora exige discovery Keycloak y PING Redis además de API/portal, y no imprime contraseñas.

[Costos ECS actuales](costs-and-approval.md): 183,59–233,59 USD/mes orientativos con provisión de identidad; reserva sugerida 220–290 USD/mes, sin aprobación ni cotización Ohio completa. No se consultó ni se modificó AWS; la compuerta local continúa pendiente. Consultar `../qa/infra-validation-2026-11-17.json` para comandos y límites de esta revisión.

Infraestructura reproducible para la demostración AndesRetail y una evolución a AWS. **No se ha desplegado nada en AWS.** Los adaptadores empresariales y los pagos de la demostración son simulados. El perfil `demo` de AWS tampoco equivale a producción.

## Evidencia histórica de revisiones anteriores

| Verificación | Resultado registrado anteriormente; no sustituye la revisión actual |
|---|---|
| Realm Keycloak: PKCE S256, sin password grant ni implicit, rotación refresh | PASS |
| `docker compose config --quiet` | PASS |
| YAML y conexiones de configuración | 34 comprobaciones estáticas pasan: 13 archivos YAML, 35 documentos; reporte reproducible incluido |
| Compuerta de aprobación CI | 6 pruebas pasan: bloquea entornos ausentes, sin revisores o sin restricción de ramas |
| Ejecución de contenedores | Bloqueada: acceso al daemon Docker denegado |
| Cuenta AWS y recursos existentes | No verificados: endpoint de autenticación inaccesible |
| Terraform ECS | Terraform 1.13.3 y proveedor AWS 6.73.0. Configuración válida y dos escenarios con proveedor simulado. |
| `terraform plan` / `apply` | No ejecutados |
| ElasticMQ 1.6.12 | Ejecución autónoma por Java. Envío, visibilidad, reentrega, acuse, DLQ y replay verificados. El overlay Compose pasó validación de configuración. |
| Overlay de pagos sandbox | Deshabilitado por defecto; rechaza variables obligatorias ausentes; cuenta/webhook externo pendientes |
| Despliegue Kubernetes, TLS, DNS, disponibilidad y p95 | No verificados |
| Cinco migraciones EF en PostgreSQL 18.6 embebido | 45 pruebas SQL pasan en cuatro suites; 31 tablas, 72 índices y 6 vistas; no equivale a servidor PG17 |

El motor Docker rechazó el acceso por su pipe de Windows en este entorno. Terraform, los proveedores y los binarios de prueba se descargaron. PostgreSQL 17.12 y ElasticMQ se ejecutaron como procesos locales. La validación en AWS requiere una cuenta autorizada.

## Validación estática de infraestructura

```powershell
npm ci --ignore-scripts
npm run test:config
npm run test:gates
```

`reports/infrastructure-validation.json` documenta el parseo YAML, selección de puertos de Services, probes y restricciones de pods, inputs obligatorios, loopback local, OIDC, CORS, configuración SQS/sandbox y la compuerta de apply. Para ElasticMQ verifica campos esperados; no ejecuta un parser HOCON ni su runtime. Esta validación no sustituye `terraform validate`, validación contra API Kubernetes, controladores ni una ejecución real de contenedores. `tests/deployment-gate.test.cjs` verifica que el control falle ante un environment ausente, creado sin protección, sin revisores, para otra aplicación o con ramas sin restringir.

## Validación SQL adicional

`scripts/Check-Postgres-Schema.cjs` aplica `../vortexbird-backend/scripts/schema.sql`, generado desde cinco migraciones EF mediante `dotnet ef migrations script --idempotent`, a PostgreSQL real compilado a WASM (`@electric-sql/pglite` 0.5.15, motor PostgreSQL 18.6). El script idempotente se aplicó dos veces y se verificaron seis vistas sobre 31 tablas y 72 índices. El resultado conjunto es **45/45**: 17 controles de esquema, 9 de proyecciones, 7 de cuotas y 12 de pagos. Incluye restricciones de inventario, claves foráneas partner/canal, unicidad de idempotencia y precios por defecto, deduplicación de consumidor/webhook, persistencia de cuotas/pagos y rollback transaccional.

```powershell
npm ci
npm run test:sql -- ../vortexbird-backend/scripts/schema.sql reports/postgresql-schema-validation.json
```

El reporte `reports/postgresql-schema-validation.json` conserva los 17 controles del esquema y su hash SHA256 completo; los informes de las suites adicionales están en `../qa/`. El esquema final tiene prefijo SHA256 `f91b0ed9`. Después de modificar el modelo EF, crear la migración correspondiente y regenerar `scripts/schema.sql` desde el repositorio backend con `dotnet ef migrations script --idempotent` y los parámetros de proyecto documentados allí. Esto **no** ejecuta Npgsql contra un servidor PostgreSQL 17, múltiples conexiones, concurrencia/locks, API E2E, failover ni pruebas de carga. No demuestra objetivos de latencia o disponibilidad.

## Ejecución local

Requiere los repositorios `vortexbird-backend`, `vortexbird-frontend` y este repositorio como carpetas hermanas, Docker Desktop operativo y PowerShell 7.

```powershell
if (-not (Test-Path .env)) { ./scripts/Initialize-Local.ps1 }
./scripts/Test-Configuration.ps1
docker compose up --build -d
docker compose ps
```

`Initialize-Local.ps1` genera contraseñas aleatorias únicamente en `.env`, ignorado por Git, y no reemplaza configuración existente. La pantalla de demostración usa el correo y contraseña definidos en `DEMO_EMAIL` / `DEMO_PASSWORD`. No se incluyen contraseñas fijas compartidas en el repositorio. Portal: `http://localhost:5173`; API: `http://localhost:5080`; Keycloak: `http://localhost:8080`. Puertos locales ligados a loopback.

Si otro proyecto ocupa un puerto, ajusta `API_PORT`, `FRONTEND_PORT`, `POSTGRES_PORT`, `REDIS_PORT`, `KEYCLOAK_PORT` u `OTEL_METRICS_PORT` en `.env` y ejecuta el lanzador de nuevo. El emisor OIDC y la dirección de identidad del portal se derivan de `KEYCLOAK_PORT`. Si cambias `FRONTEND_PORT` y usas OIDC, registra la nueva dirección del portal en URIs de redirección y orígenes web del cliente Keycloak.

Para la ruta OIDC, deshabilitar `DEMO_ENABLED` y `VITE_DEMO_AUTH`, configurar SMTP en Keycloak (necesario para verificar correo y recuperar contraseña), crear el usuario y vincular su subject y sus permisos mediante la administración de la plataforma. El realm no otorga privilegios administrativos a usuarios autorregistrados. El JWT tiene issuer externo `localhost:8080`; el backend usa metadata por el hostname interno `keycloak` y valida el issuer externo explícito.

`docker compose down` conserva volúmenes. No ejecutar `down -v` salvo decisión explícita de eliminar datos locales. Los servicios se inician en modo desarrollo; nunca copiar `start-dev`, demo auth o contraseñas locales a producción.

Opciones explícitas: [SQS local con ElasticMQ](messaging/README.md) y [pagos con una cuenta de sandbox](payments/README.md). El Compose principal conserva transporte local y pagos simulados. Ninguna opción fue ejecutada contra un servicio externo en esta sesión.

## Decisiones de la alternativa EKS

- PostgreSQL y Keycloak tienen bases separadas. El compose usa instancias separadas para evitar permisos cruzados.
- Redis es caché; no decide disponibilidad de reserva ni reemplaza la transacción persistente.
- OIDC Authorization Code + PKCE para humanos. Partners machine-to-machine requieren clientes confidenciales dedicados; los secretos nunca se distribuyen al navegador.
- Kong OSS aplica rutas, tamaño de payload, correlación y límite por IP. La validación OIDC y las cuotas autenticadas por partner/canal son responsabilidad del backend. No se presupone un plugin OIDC comercial en Kong OSS.
- SQS Standard + outbox + deduplicación de consumidores; no se promete entrega exactamente una vez.
- RDS administrado, ElastiCache TLS/AUTH y EKS sobre subredes privadas. Datos sin ruta por defecto a internet. Todo es recurso nuevo con prefijo `vortexbird-*`; no se importa ni modifica infraestructura ajena.
- ALB y Route53 se configuran después de conocer dominios y un certificado ACM real. No se inventaron nombres DNS ni ARNs.

## Variables y secretos de EKS

El `.env.example` documenta solo desarrollo. `terraform/variables.tf` contiene entradas de AWS. Se requieren `kubernetes_version` actualmente soportada, `admin_role_arn` existente, CIDRs administrativos explícitos y `TF_VAR_redis_auth_token`. El estado contiene información sensible: usar S3 existente con cifrado, versionado, bloqueo y acceso limitado. El token Redis permanece marcado sensitive, pero eso no elimina su presencia en el estado.

Terraform crea metadatos Secrets Manager sin valores. La configuración productiva usa estos documentos:

| Secreto | Claves |
|---|---|
| `vortexbird-<env>/application` | `ConnectionStrings__Database` (usuario limitado, SSL verificado); `ConnectionStrings__Redis` (TLS, AUTH) |
| `vortexbird-<env>/keycloak` | `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD` (base/usuario propios) |

Nunca dar al backend el usuario maestro RDS. La contraseña maestra la administra RDS. Crear usuarios de aplicación/migración por separado y conceder INSERT/SELECT solamente sobre auditoría al usuario de ejecución. Migraciones ejecutadas por job antes del rollout, con credenciales distintas. El almacenamiento y CSI de secretos no sustituyen la rotación de credenciales ni la migración del esquema.

## Identidad AWS del backend en EKS

El backend usa **EKS Pod Identity** con el proveedor de credenciales de contenedor del SDK oficial de AWS. `terraform/pod-identity.tf` declara el agente, su versión compatible con la versión EKS elegida y la asociación al ServiceAccount `vortexbird/backend`. El rol confía en `pods.eks.amazonaws.com` para `AssumeRole` y `TagSession`, condicionado al ARN del clúster, namespace y ServiceAccount. Los permisos de aplicación permanecen limitados a las colas y al secreto correspondiente. Keycloak y VPC CNI conservan sus roles IRSA propios.

La asociación EKS inyecta la ruta del token y la URI del agente; no se escriben claves AWS permanentes ni variables IRSA en el backend. Su NetworkPolicy permite únicamente el endpoint del agente `169.254.170.23:80`. El rol de nodos ya incluye `AmazonEKSWorkerNodePolicy`, que autoriza `eks-auth:AssumeRoleForPodIdentity`. Se añade un endpoint privado EKS Auth en ambas subredes de aplicación con entrada TLS limitada a nodos; su costo figura en la estimación. `backend_role_arn` sigue disponible como output de auditoría, pero ya no es un valor de renderizado Kubernetes.

El SecretProviderClass del backend activa `usePodIdentity: "true"`; requiere una versión del AWS Secrets and Configuration Provider compatible con esa opción. Antes del rollout, comprobar agente saludable, asociación efectiva, obtención y renovación de credenciales, montaje de secretos y acceso SQS. El agente/endpoint no se desplegaron; los controles actuales son estructurales y no validan el proveedor Terraform. Si se cambia la imagen de nodos y se desactiva IPv6 local, revisar la configuración de escucha del agente según AWS.

Referencias oficiales: [SDKs compatibles](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html), [proveedor de credenciales de contenedor](https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html), [agente y permisos del nodo](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html), [trust policy y condiciones](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html), [EKS Auth PrivateLink](https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html), [CSI con Pod Identity](https://docs.aws.amazon.com/secretsmanager/latest/userguide/ascp-examples.html).

## Plan y aprobación para EKS

1. Ejecutar `scripts/Inventory-Aws.ps1` con perfil y región correctos; comprobar identidad, regiones habilitadas y cuotas. Los reportes de cuenta se ignoran en Git.
2. Revisar `costs-and-approval.md`. Seleccionar `demo` o `production`; validar disponibilidad de tipos/versiones en `us-east-2`.
3. Configurar un bucket de estado **existente** y credenciales temporales/OIDC. El rol de plan necesita permisos de lectura y estado; el de apply permisos específicos para los recursos nuevos.
4. `terraform init` con backend S3; `terraform fmt -recursive`; `terraform validate`; `terraform plan -var-file=environments/demo.tfvars -out=approved.tfplan`. No provisiona recursos. Guardar el plan de forma privada; contiene valores sensibles.
5. Presentar el plan concreto (identidad, región, recursos, cambios y costo) y obtener aprobación explícita del usuario. **No ejecutar apply antes.**
6. Aplicar exactamente ese plan; confirmar outputs. No usar `-auto-approve` sobre un plan nuevo.
7. Verificar el agente Pod Identity y su asociación declarados por Terraform. Instalar add-ons versionados y revisados: AWS Load Balancer Controller con IRSA dedicado, Secrets Store CSI + AWS provider compatible con Pod Identity, `syncSecret` y rotación, metrics-server, observabilidad ADOT/CloudWatch. Requieren sus propios permisos y validación del equipo de plataforma. Los manifests dependen de estos CRDs/controllers y no se presentan como desplegados.
8. Crear bases/usuarios limitados, cargar los secretos, importar el realm productivo (redirects/origins exactos HTTPS), configurar SMTP y bootstrap administrativo temporal. Quitar el acceso bootstrap después de crear el administrador permanente.
9. Construir imágenes, revisar análisis de seguridad, publicarlas en ECR y usar digest SHA256. Renderizar manifests con `scripts/Render-Kubernetes.ps1 -ValuesFile <archivo-privado.json>`. El script rechaza placeholders, hostnames de ejemplo e imágenes mutables; no aplica cambios.
10. Con el contexto del clúster confirmado: aplicar namespace/RBAC; CSI; config; migraciones; deployments; ingress. Configurar DNS con alias ALB y cert ACM validado. Los manifests no exponen `/admin` de Keycloak; administración por acceso privado.
11. Comprobar probes, rollouts, JWT inválido, aislamiento partner, idempotencia concurrente, compensación, colas/DLQ y restore. Medir carga y SLO; verificar que NetworkPolicy está efectivamente aplicada por el CNI.

Los archivos `kubernetes/*.yaml` son plantillas con entradas obligatorias, no comandos aplicados. `Render-Kubernetes.ps1` exige un JSON con las claves presentes en los templates y escribe solo en `rendered/`.

## CI/CD y rollback de la alternativa EKS

`validate.yml` ejecuta los validadores YAML y de aprobación, formatea HCL, valida el esquema Terraform y ejecuta Checkov (fallos bloqueantes). `plan-apply.yml` es manual y aplica únicamente desde `main`, con `apply=true` **y** aprobación del environment protegido. Antes de asumir credenciales AWS, consulta la configuración del environment mediante la API GitHub y exige revisores y ramas restringidas; si esa consulta o la protección faltan, bloquea el apply. Crear ambientes `terraform-plan`, `demo`, `production` con esas reglas antes de habilitarlo. GitHub no las configura al crear el workflow y algunos planes no ofrecen revisores para repositorios privados: en ese caso el apply automatizado permanece bloqueado y se utiliza el proceso manual con aprobación del plan concreto.

El mismo plan, el lockfile de proveedores y el commit se conservan entre jobs y se verifican antes de aplicar. El artefacto incluye explícitamente el lockfile oculto y `init -lockfile=readonly` impide cambiarlo durante apply. Los artefactos del plan son privados, contienen material sensible y se retienen un día. No se guardan claves AWS permanentes. Referencias: https://docs.github.com/en/rest/deployments/environments y https://github.com/actions/upload-artifact.

El rol GitHub creado opcionalmente por Terraform sirve para publicar ECR/desplegar workloads, no para administrar infraestructura. El rol de Terraform se prepara fuera de este stack y se revisa por separado para evitar un bucle de autoescalamiento de permisos. La trust policy restringe repositorio y environment. La asociación EKS usa el grupo `vortexbird-deployers` y RoleBinding limitado al namespace.

Rollback de aplicación: volver a digest anterior aprobado, verificar health/smoke y mantener compatibilidad de esquemas expand/contract. No revertir migraciones destructivas automáticamente. El `revisionHistoryLimit` conserva versiones de Deployment. RDS mantiene backup y protección de borrado. Terraform no se usa para borrar/recrear recursos como rollback.

## Operación

- Promos: precalentar caché/proyecciones, escalar antes del pico, observar backlog y 429, proteger ERP/WMS, no incrementar reintentos ante saturación.
- Stock/precios: revisar tasa 5xx, latencia/caché, circuitos, profundidad de cola y salud del adaptador. Si cae el legado, mostrar staleness acotado en consultas; rechazar nuevas reservas si no puede verificarse stock. Reintentar con presupuesto y jitter; no reconstruir toda la caché de golpe.
- DLQ: conservar payload sin PII innecesaria, corregir causa, probar un mensaje, redrive gradual con deduplicación. No purgar a ciegas.
- Alertas: Terraform define siete alarmas. Cinco métricas `VortexBird/*` necesitan el puente ADOT/EMF correspondiente; no están conectadas a métricas de aplicación automáticamente. `missing` se mantiene visible hasta completar instrumentación. SQS/RDS usan métricas AWS nativas.
- CNI: activar enforcement de NetworkPolicy, verificar DNS, egress AWS TLS, acceso a datos y comunicación Keycloak. La política por sí sola no garantiza enforcement.

## Versionado

Repositorio independiente. Ramas `main`, `develop`, `feature/*`, `fix/*`, `hotfix/*`; commits convencionales (`feat:`, `fix:`, `docs:`, `ci:`). Revisar planes y AD﻿Rs antes de cambios de red/identidad. Imágenes versionadas como punto inicial reproducible; antes de desplegar, resolver digest y analizar CVEs. No se afirmaron validaciones de imágenes que no se pudieron descargar.

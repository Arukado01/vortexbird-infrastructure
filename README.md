# VortexBird Infrastructure

Infraestructura reproducible para la demostración AndesRetail y una evolución a AWS. **No se ha desplegado nada en AWS.** Los adaptadores empresariales y los pagos de la demostración son simulados. El perfil `demo` de AWS tampoco equivale a producción.

## Estado verificable

| Verificación | Resultado en esta sesión |
|---|---|
| Realm Keycloak: PKCE S256, sin password grant ni implicit, rotación refresh | PASS |
| `docker compose config --quiet` | PASS |
| Ejecución de contenedores | Bloqueada: acceso al daemon Docker denegado |
| Cuenta AWS y recursos existentes | No verificados: endpoint de autenticación inaccesible |
| Terraform provider/schema validate | Pendiente: Terraform no instalado; descarga bloqueada por DNS |
| `terraform plan` / `apply` | No ejecutados |
| Despliegue Kubernetes, TLS, DNS, disponibilidad y p95 | No verificados |
| Tres migraciones EF en PostgreSQL 18.6 embebido | 17 pruebas SQL pasan; 26 tablas, 58 índices y 6 vistas; no equivale a servidor PG17 |

## Validación SQL adicional

`scripts/Check-Postgres-Schema.cjs` aplica `../vortexbird-backend/scripts/schema.sql`, generado desde las tres migraciones EF mediante `dotnet ef migrations script --idempotent`, a PostgreSQL real compilado a WASM (`@electric-sql/pglite` 0.5.15, motor PostgreSQL 18.6). El script idempotente se aplicó dos veces y se verificaron seis vistas: 17 pruebas pasan sobre 26 tablas y 58 índices. Los controles incluyen restricciones de inventario, claves foráneas partner/canal, unicidad de idempotencia y precios por defecto, deduplicación de consumidor/webhook y rollback transaccional.

```powershell
npm ci
npm run test:sql -- ../vortexbird-backend/scripts/schema.sql reports/postgresql-schema-validation.json
```

El reporte `reports/postgresql-schema-validation.json` conserva el hash SHA256 completo del esquema probado. Después de modificar el modelo EF, crear la migración correspondiente y regenerar `scripts/schema.sql` desde el repositorio backend con `dotnet ef migrations script --idempotent` y los parámetros de proyecto documentados allí. Esto **no** ejecuta Npgsql contra un servidor PostgreSQL 17, múltiples conexiones, concurrencia/locks, API E2E, failover ni pruebas de carga. No demuestra objetivos de latencia o disponibilidad.

## Ejecución local

Requiere los repositorios `vortexbird-backend`, `vortexbird-frontend` y este repositorio como carpetas hermanas, Docker Desktop operativo y PowerShell 7.

```powershell
./scripts/Initialize-Local.ps1
./scripts/Test-Configuration.ps1
docker compose up --build -d
docker compose ps
```

`Initialize-Local.ps1` genera contraseñas aleatorias únicamente en `.env`, ignorado por Git, y no reemplaza configuración existente. La pantalla de demostración usa el correo y contraseña definidos en `DEMO_EMAIL` / `DEMO_PASSWORD`. No se incluyen contraseñas fijas compartidas en el repositorio. Portal: `http://localhost:5173`; API: `http://localhost:5080`; Keycloak: `http://localhost:8080`. Puertos locales ligados a loopback.

Para la ruta OIDC, deshabilitar `DEMO_ENABLED` y `VITE_DEMO_AUTH`, configurar SMTP en Keycloak (necesario para verificar correo y recuperar contraseña), crear el usuario y vincular su subject y sus permisos mediante la administración de la plataforma. El realm no otorga privilegios administrativos a usuarios autorregistrados. El JWT tiene issuer externo `localhost:8080`; el backend usa metadata por el hostname interno `keycloak` y valida el issuer externo explícito.

`docker compose down` conserva volúmenes. No ejecutar `down -v` salvo decisión explícita de eliminar datos locales. Los servicios se inician en modo desarrollo; nunca copiar `start-dev`, demo auth o contraseñas locales a producción.

## Decisiones

- PostgreSQL y Keycloak tienen bases separadas. El compose usa instancias separadas para evitar permisos cruzados.
- Redis es caché; no decide disponibilidad de reserva ni reemplaza la transacción persistente.
- OIDC Authorization Code + PKCE para humanos. Partners machine-to-machine requieren clientes confidenciales dedicados; los secretos nunca se distribuyen al navegador.
- Kong OSS aplica rutas, tamaño de payload, correlación y límite por IP. La validación OIDC y las cuotas autenticadas por partner/canal son responsabilidad del backend. No se presupone un plugin OIDC comercial en Kong OSS.
- SQS Standard + outbox + deduplicación de consumidores; no se promete entrega exactamente una vez.
- RDS administrado, ElastiCache TLS/AUTH y EKS sobre subredes privadas. Datos sin ruta por defecto a internet. Todo es recurso nuevo con prefijo `vortexbird-*`; no se importa ni modifica infraestructura ajena.
- ALB y Route53 se configuran después de conocer dominios y un certificado ACM real. No se inventaron nombres DNS ni ARNs.

## Variables y secretos

El `.env.example` documenta solo desarrollo. `terraform/variables.tf` contiene entradas de AWS. Se requieren `kubernetes_version` actualmente soportada, `admin_role_arn` existente, CIDRs administrativos explícitos y `TF_VAR_redis_auth_token`. El estado contiene información sensible: usar S3 existente con cifrado, versionado, bloqueo y acceso limitado. El token Redis permanece marcado sensitive, pero eso no elimina su presencia en el estado.

Terraform crea metadatos Secrets Manager sin valores. La configuración productiva usa estos documentos:

| Secreto | Claves |
|---|---|
| `vortexbird-<env>/application` | `ConnectionStrings__Database` (usuario limitado, SSL verificado); `ConnectionStrings__Redis` (TLS, AUTH) |
| `vortexbird-<env>/keycloak` | `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD` (base/usuario propios) |

Nunca dar al backend el usuario maestro RDS. La contraseña maestra la administra RDS. Crear usuarios de aplicación/migración por separado y conceder INSERT/SELECT solamente sobre auditoría al usuario de ejecución. Migraciones ejecutadas por job antes del rollout, con credenciales distintas. El almacenamiento y CSI de secretos no sustituyen la rotación de credenciales ni la migración del esquema.

## Plan y aprobación AWS

1. Ejecutar `scripts/Inventory-Aws.ps1` con perfil y región correctos; comprobar identidad, regiones habilitadas y cuotas. Los reportes de cuenta se ignoran en Git.
2. Revisar `costs-and-approval.md`. Seleccionar `demo` o `production`; validar disponibilidad de tipos/versiones en `us-east-2`.
3. Configurar un bucket de estado **existente** y credenciales temporales/OIDC. El rol de plan necesita permisos de lectura y estado; el de apply permisos específicos para los recursos nuevos.
4. `terraform init` con backend S3; `terraform fmt -recursive`; `terraform validate`; `terraform plan -var-file=environments/demo.tfvars -out=approved.tfplan`. No provisiona recursos. Guardar el plan de forma privada; contiene valores sensibles.
5. Presentar el plan concreto (identidad, región, recursos, cambios y costo) y obtener aprobación explícita del usuario. **No ejecutar apply antes.**
6. Aplicar exactamente ese plan; confirmar outputs. No usar `-auto-approve` sobre un plan nuevo.
7. Instalar add-ons versionados y revisados: AWS Load Balancer Controller con IRSA dedicado, Secrets Store CSI + AWS provider con `syncSecret` y rotación, metrics-server, observabilidad ADOT/CloudWatch. Requieren sus propios permisos y validación del equipo de plataforma. Los manifests dependen de estos CRDs/controllers y no se presentan como desplegados.
8. Crear bases/usuarios limitados, cargar los secretos, importar el realm productivo (redirects/origins exactos HTTPS), configurar SMTP y bootstrap administrativo temporal. Quitar el acceso bootstrap después de crear el administrador permanente.
9. Construir imágenes, revisar análisis de seguridad, publicarlas en ECR y usar digest SHA256. Renderizar manifests con `scripts/Render-Kubernetes.ps1 -ValuesFile <archivo-privado.json>`. El script rechaza placeholders, hostnames de ejemplo e imágenes mutables; no aplica cambios.
10. Con el contexto del clúster confirmado: aplicar namespace/RBAC; CSI; config; migraciones; deployments; ingress. Configurar DNS con alias ALB y cert ACM validado. Los manifests no exponen `/admin` de Keycloak; administración por acceso privado.
11. Comprobar probes, rollouts, JWT inválido, aislamiento partner, idempotencia concurrente, compensación, colas/DLQ y restore. Medir carga y SLO; verificar que NetworkPolicy está efectivamente aplicada por el CNI.

Los archivos `kubernetes/*.yaml` son plantillas con entradas obligatorias, no comandos aplicados. `Render-Kubernetes.ps1` exige un JSON con las claves presentes en los templates y escribe solo en `rendered/`.

## CI/CD y rollback

`validate.yml` formatea, valida esquema y ejecuta Checkov (fallos bloqueantes). `plan-apply.yml` es manual, conserva el mismo plan y su SHA256 entre jobs, aplica únicamente si `apply=true` **y** se aprueba el environment protegido. Crear ambientes `terraform-plan`, `demo`, `production` con required reviewers y protección de ramas antes de habilitarlo. No asumir que GitHub agrega esas protecciones al crear el workflow. No guarda claves AWS permanentes. Los artefactos del plan son privados y se retienen un día.

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

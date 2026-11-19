# Identidad Keycloak opcional en ECS

17-Nov-2026. Configuración implementada para revisión; **sin plan de cuenta, recursos creados ni login AWS verificado**. `identity_enabled=false` y `identity_deploy_service=false` conservan el comportamiento del stack existente. La aceptación local y la aprobación de costos siguen siendo requisitos antes de aplicar.

## Recursos y separación

El primer plan puede incluir la base de datos, repositorio ECR y roles de Keycloak con `identity_enabled=true`. Se puede omitir `identity_hostname` mientras el servicio, DNS y certificados de identidad estén desactivados. En esa fase, los campos `origin` e `issuer` valen `null`. Para activar Keycloak, administrar su DNS, solicitar un certificado o seleccionar un ARN de certificado de identidad, configura primero el nombre de dominio autorizado.

Keycloak usa el clúster, las subredes privadas y el ALB del proyecto. Con un hostname propio, `keycloak_url` coincide con `https://<identity_hostname>`. Con `identity_shared_host=true`, el portal y Keycloak comparten el certificado y el nombre público. El ALB reenvía a Keycloak las rutas públicas de identidad bajo `/auth` y conserva las rutas del portal y de la API. El acceso administrativo de Keycloak requiere una lista explícita de CIDR autorizados.

### Dominio del piloto en Ohio

El portal usa `https://vortexbird.pgecolombia.com`. El emisor OIDC es `https://vortexbird.pgecolombia.com/auth/realms/vortexbird`. Para el plan de activación HTTPS, carga primero `environments/development.tfvars` y después `environments/vortexbird-ohio.tfvars`. Este segundo archivo selecciona el certificado dedicado de ACM y el dominio compartido. Las imágenes y la activación de los servicios se incorporan en las fases de migración y despliegue.

El CNAME de validación de ACM acredita el control del dominio. Para enviar tráfico al piloto, crea el registro A de tipo alias del portal hacia el DNS y la zona canónica del ALB que devuelva el despliegue. Comprueba el estado de los destinos del ALB y verifica el emisor en `/auth/realms/vortexbird/.well-known/openid-configuration` antes de dar el portal por disponible.

El puerto de tráfico es 8080 y el ALB comprueba `/health/ready` en 9000. Ambos puertos admiten solo el SG del ALB; 9000 nunca se publica mediante un listener. Los puertos de cluster 7800 y 57800 aceptan únicamente el SG de identidad. Las tareas no tienen IP pública. Egress está limitado a HTTPS, PostgreSQL dedicado y tráfico interno del cluster.

La base RDS PostgreSQL de identidad es físicamente distinta de la base de negocio: 20 GB gp3 cifrados, clase `identity_db_instance_class` configurable, backups y protección de borrado. El piloto usa `db.t4g.micro` Single-AZ; production solicita Multi-AZ. Keycloak usa 0,5 vCPU/2 GB, una tarea en piloto y dos en production con `jdbc-ping`. Eso configura capacidad; no demuestra HA ni recuperación.

El Task Role de identidad no tiene políticas AWS. El Execution Role obtiene únicamente su imagen ECR, logs y los secretos inyectados. No puede leer la contraseña maestra RDS. Terraform crea metadatos de secretos; nunca valores, versiones ni contraseñas en estado.

## TLS y DNS: autorización explícita

La integración requiere el listener HTTPS existente y su `certificate_arn`. Se puede usar un certificado existente que cubra el hostname de identidad mediante `identity_certificate_arn`; si coincide con el certificado del listener, no se añade duplicado. Si no se proporciona uno adicional, el operador debe comprobar que el certificado principal cubre ambos nombres.

`identity_request_certificate=true` permite solicitar un certificado ACM nuevo y escribir su validación DNS. `identity_manage_dns=true` permite crear el alias A hacia el ALB. Ambas acciones requieren `identity_dns_zone_id` explícito, una zona pública autorizada y un subdominio perteneciente a ella. Los registros no se sobrescriben. No se seleccionan dominios por búsqueda ni se reutilizan nombres de otros proyectos. Las opciones permanecen desactivadas por defecto.

**Bloqueo de activación:** mantener `identity_deploy_service=false` mientras no se verifiquen los certificados reales. `scripts/preflight-identity-tls.cjs` consulta solo `acm:DescribeCertificate` por cada ARN exacto; comprueba región, cuenta coherente, estado ISSUED, vigencia y cobertura SAN del portal y la identidad. Un wildcard cubre únicamente un nivel. No selecciona certificados por búsqueda ni modifica recursos.

Preparar fuera de Git un JSON sin credenciales con `region`, `portalOrigin`, `identityOrigin`, `listenerCertificateArn` y `identityCertificateArn` (este último puede ser null si el principal cubre ambos hosts). Ejecutar, desde infraestructura, inmediatamente antes del despliegue autorizado:

```powershell
node scripts/preflight-identity-tls.cjs --input reviewed-tls.json --out tls-preflight-result.json
```

El workflow apply utiliza el modo `--plan-json`, derivado del plan binario guardado y verificado, con `--expected-account`, `--expected-region` y `--out`. El gate compara flags y recursos, exige los ARN exactos conocidos, valida portal e identidad según los servicios activados y falla si el certificado solicitado sigue desconocido. Un plan de fundación con ambos servicios desactivados puede crear el certificado sin consultar ACM en este paso; la activación debe ser una fase posterior revisada.

El comando debe pasar en la ejecución actual: un informe guardado no autoriza por sí solo el despliegue. Los resultados contienen fecha y hash del JSON revisado; archivo ausente o inválido reemplaza evidencia anterior por `blocked`, sin imprimir contenido del plan. La revisión ejecutó 16 pruebas unitarias con certificados/planes sintéticos, sin consultas ACM. El éxito real acreditará metadatos; quedan resolución DNS, asociación SNI y handshake TLS. Terraform por sí solo no valida cobertura SAN; no se ha activado el servicio en esta revisión.

## Preparación segura antes de iniciar

1. Revisar el inventario y el plan con `identity_enabled=true`, `identity_deploy_service=false`. Incluir ECR, RDS, logs, tres secretos de identidad y DNS/ACM solo si se autorizaron. Este plan es facturable aunque no ejecute el servicio.
2. Tras la aprobación, crear los recursos revisados. Desde una tarea operativa autorizada en la VPC, usando el SG privado de identidad y una identidad temporal distinta, inicializar la base. Obtener el secreto maestro RDS solo en ese procedimiento; no asignarlo a Keycloak.
3. Crear un usuario de base y un esquema exclusivo. En una sesión psql cifrada, sin registrar credenciales:

```sql
CREATE ROLE keycloak_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
\password keycloak_runtime
GRANT CONNECT ON DATABASE keycloak TO keycloak_runtime;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA keycloak AUTHORIZATION keycloak_runtime;
```

Keycloak necesita DDL dentro de su propio esquema para sus migraciones internas. Este usuario no es el runtime ni el migrator de VortexBird y no tiene acceso a la base de negocio. Guardar `{username,password}` en el secreto `identity/database` mediante un canal autorizado, sin pasarlos como argumentos, commit o salida de logs.

4. Usar la fuente ejecutable [keycloak/cloud/README.md](../keycloak/cloud/README.md): Dockerfile optimizado, realm parametrizado, entrypoint validado y `Build-Image.ps1`. Exige base oficial revisada por digest y bundle CA RDS con SHA-256 revisado en `/opt/keycloak/conf/rds-ca-bundle.pem`; JDBC usa `sslmode=verify-full`. Los 21 controles estáticos cloud pasan; sus 12 controles de realm se solapan y no se suman. Bash `-n` quedó bloqueado por MSYS `0xC0000022`. No hubo descarga, build, scan, publicación ECR ni importación ejecutados; obtener el digest de la imagen resultante antes de activar `identity_deploy_service`.

## Bootstrap de administración y realm

Guardar una credencial temporal distinta `{username,password}` en `identity/bootstrap-admin`, generada aleatoriamente sin valor predeterminado. Para evitar expansión de propiedades en versiones que no soporten valores literales, generar la contraseña temporal con un alfabeto seguro sin `$`. Activar `identity_bootstrap_admin_enabled=true` únicamente durante la creación inicial del master realm. Las credenciales entran por Secrets Manager al iniciar la tarea, nunca por argumentos o Terraform.

Iniciar el servicio solo con secreto DB, imagen, certificado, hostname y conectividad preparados. El contrato de la imagen cloud usa `start --optimized --import-realm` y `VORTEXBIRD_PORTAL_ORIGIN` con el origen exacto del portal. El realm cloud debe partir de la configuración versionada sin usuarios de demostración ni secretos exportados. La importación de arranque no actualiza un realm ya existente; posteriores cambios requieren un procedimiento administrativo revisado. Desde una IP administrativa autorizada, crear un administrador permanente protegido con MFA. Revisar:

- `vortexbird-portal`: cliente público, Authorization Code, PKCE S256, sin implicit ni password grant.
- Redirect URI y post-logout URI: el origen HTTPS exacto del portal; el frontend actual usa `location.origin`. Web origin: ese mismo origen, sin comodines.
- `sslRequired=all`, registro según política aprobada; verificación de correo y recuperación solo después de configurar SMTP.
- Conservar audiencia `vortexbird-api`, claims `identity_type`, `partner_id` y `channel_id`, y rotación de refresh tokens. No otorgar administración por autorregistro.
- Crear un usuario de prueba y pasar su issuer/subject comprobados al bootstrap administrativo de la aplicación. Email por sí solo no identifica al administrador.

Eliminar el administrador temporal, desactivar `identity_bootstrap_admin_enabled`, aplicar la nueva definición y comprobar que la tarea y el Execution Role ya no reciben/leen ese secreto. La rotación de un secreto inyectado requiere tareas nuevas. No registrar tokens, passwords o configuraciones SMTP en las evidencias.

## Validación y límites

Controles locales sin proveedor: `terraform fmt -check identity.tf identity-variables.tf identity-outputs.tf` y `node --test tests/identity-config.test.cjs` desde sus directorios correspondientes. Estos checks no sustituyen `terraform validate`, un plan de cuenta o pruebas conectadas.

Después de un despliegue autorizado: verificar certificado/hostname, descubrimiento y JWKS, login y credencial incorrecta, audience/issuer, refresh y rechazo de reutilización, recarga, logout, permisos, restricciones del administrador, reinicio de tarea, persistencia y backups. El smoke OIDC existente es exclusivo de loopback; un smoke HTTPS de staging debe cubrir el portal y los redirects reales. Un target saludable no demuestra que el realm o el administrador de negocio estén configurados.

Costos nuevos: tarea Keycloak, RDS identidad/almacenamiento, ECR/logs y tres secretos (DB de Keycloak, bootstrap temporal, maestro RDS). Reutilizar ALB/NAT no elimina procesamiento y transferencia. Actualizar el presupuesto Ohio y el tamaño productivo antes de aprobar.

Fuentes oficiales: [contenedores](https://www.keycloak.org/server/containers), [health](https://www.keycloak.org/observability/health), [reverse proxy](https://www.keycloak.org/server/reverseproxy), [base de datos](https://www.keycloak.org/server/db), [caché y jdbc-ping](https://www.keycloak.org/server/caching), [inyección de secretos ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html), [target groups ALB](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html). Consultadas el 17-Nov-2026; comprobar compatibilidad con la imagen fijada antes del despliegue.

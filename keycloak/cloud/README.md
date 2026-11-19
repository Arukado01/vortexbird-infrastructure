# Imagen de identidad para ECS

Este directorio implementa una imagen optimizada de Keycloak para el contrato de `terraform-ecs/identity.tf`. Incluye el build multietapa, realm de producción, validación de configuración al iniciar, health check y script de construcción. No modifica el realm local ni crea usuarios.

**Estado verificado:** 21 comprobaciones estáticas aprobadas en `static-validation.json`. No se descargó ni construyó la imagen, no se importó el realm y no se publicaron recursos. La comprobación Bash `-n` quedó bloqueada por la restricción Windows `NtCreateDirectoryObject`, código `0xC0000022`; la sintaxis PowerShell sí fue validada. No existe todavía un digest de imagen VortexBird construido que pueda desplegarse.

## Contenido ejecutable

| Archivo | Responsabilidad |
|---|---|
| `Dockerfile` | Ejecuta `kc.sh build` con PostgreSQL, health y métricas; conserva UID 1000 |
| `realm-template.json` | Realm `vortexbird`, cliente público PKCE S256 y audiencia `vortexbird-api` |
| `entrypoint.sh` | Solo permite `start --optimized --import-realm`; valida antes de arrancar |
| `validate-runtime.sh` | Exige orígenes HTTPS exactos, TLS de RDS y proxies explícitos; no imprime valores |
| `healthcheck.sh` | Comprueba `/health/ready` por el puerto interno 9000, sin curl |
| `Build-Image.ps1` | Valida digest base y CA revisados, crea contexto mínimo y construye localmente |
| `Validate-Cloud.ps1` | Verifica contratos JSON, seguridad, contenido del build y sintaxis PowerShell |

La base oficial seleccionada es Keycloak **26.8.2**, consultada en la página oficial de descargas el 17 de noviembre de 2026. `KEYCLOAK_IMAGE` no tiene valor predeterminado: el script exige `quay.io/keycloak/keycloak:26.8.2@sha256:...` con un digest real revisado. No se utiliza `latest` ni se inventa un digest.

## Construcción desde una máquina con Docker autorizado

Obtén el digest del manifest oficial para `linux/amd64` y un bundle CA público vigente desde el truststore de Amazon RDS. Revisa el contenido y su SHA-256 antes de suministrarlos. Estos valores son entradas del build; no hay descargas automáticas ni secretos durante la construcción.

```powershell
./Validate-Cloud.ps1
$reviewedImage = Read-Host 'Imagen oficial 26.8.2 fijada por digest'
$reviewedCaPath = Read-Host 'Ruta del bundle CA público de RDS revisado'
$reviewedCaHash = Read-Host 'SHA-256 revisado del bundle'
./Build-Image.ps1 -KeycloakImage $reviewedImage -RdsCaBundlePath $reviewedCaPath -RdsCaBundleSha256 $reviewedCaHash
```

El script comprueba que el hash coincida, rechaza claves privadas, exige certificados CA no vencidos y copia el bundle a `/opt/keycloak/conf/rds-ca-bundle.pem`. Usa un contexto temporal con archivos explícitos y lo elimina dentro de una ruta verificada. No publica en ECR ni aplica Terraform. Las credenciales de base de datos y administración jamás son `ARG` ni `ENV` con valores de build.

Después de revisar el resultado y superar las aprobaciones cloud, publica la imagen y entrega **su digest ECR real** a `identity_image_digest`. El digest de la base oficial no es el digest de la imagen VortexBird resultante.

## Contrato de ejecución

| Variable | Origen o valor exigido |
|---|---|
| `VORTEXBIRD_PORTAL_ORIGIN` | `portal_origin`, origen HTTPS del frontend sin `/` final, rutas, consultas ni wildcard |
| `KC_HOSTNAME` | Origen HTTPS del host de identidad dedicado o URL exacta `${VORTEXBIRD_PORTAL_ORIGIN}/auth` para un dominio compartido |
| `KC_HTTP_RELATIVE_PATH`, `KC_HTTP_MANAGEMENT_RELATIVE_PATH` | Ruta interna `/` en ambos modos. Puede usarse el valor predeterminado de la imagen. |
| `KC_DB_URL` | `jdbc:postgresql://HOST:5432/keycloak?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca-bundle.pem` |
| `KC_DB_USERNAME`, `KC_DB_PASSWORD` | Secreto externo `database`, claves `username` y `password` |
| `KC_DB_SCHEMA` | `keycloak` |
| `KC_PROXY_TRUSTED_ADDRESSES` | CIDR IPv4 explícitos de las dos subredes del ALB; se rechaza `/0` |
| `KC_BOOTSTRAP_ADMIN_USERNAME`, `KC_BOOTSTRAP_ADMIN_PASSWORD` | Pareja opcional de secreto externo temporal; contraseña de 16 caracteres o más |
| `KC_DB`, `KC_HEALTH_ENABLED`, `KC_METRICS_ENABLED` | `postgres`, `true`, `true`, fijados durante build y conservados en ejecución |
| `KC_HOSTNAME_STRICT`, `KC_HTTP_ENABLED`, `KC_PROXY_HEADERS` | `true`, `true`, `xforwarded` |
| `KC_HTTP_MANAGEMENT_PORT`, `KC_HTTP_MANAGEMENT_SCHEME` | `9000`, `http` |
| `KC_CACHE`, `KC_CACHE_STACK` | `ispn`, `jdbc-ping` |

El HTTP 8080 es exclusivo del ALB y de la red privada; HTTPS termina en el ALB. El puerto 9000 sirve health/métricas internos, y 7800/57800 quedan restringidos entre las tareas de identidad para clustering. PostgreSQL y su schema deben existir y ser accesibles por el usuario de identidad. No expongas estos puertos internos en un listener público.

El entrypoint rechaza cambios que contradigan el contrato revisado, incluyendo comandos de desarrollo, orígenes comodín, parámetros JDBC adicionales y proxies sin restricción. No se admiten argumentos extra; Terraform debe enviar exactamente `start`, `--optimized`, `--import-realm`.

## Importación y cuentas

En el dominio compartido, el ALB retira el prefijo público `/auth` antes de reenviar las solicitudes permitidas. Keycloak usa `KC_HOSTNAME` para publicar el emisor `${VORTEXBIRD_PORTAL_ORIGIN}/auth/realms/vortexbird` y las direcciones de inicio de sesión, token y cierre de sesión. La comprobación privada sigue en el puerto `9000` y la ruta `/health/ready`. [Configuración del proxy inverso de Keycloak](https://www.keycloak.org/server/reverseproxy)

Keycloak resuelve `${VORTEXBIRD_PORTAL_ORIGIN}` durante la importación. Es el único placeholder del realm. Los redirects permitidos son el origen y su ruta `/`; `webOrigins` y post-logout usan el origen exacto. El portal utiliza `location.origin` como callback. No se admite `/qa-oidc` ni `/*`.

El realm no incluye usuarios, passwords, secretos de cliente ni SMTP. El registro público está deshabilitado; verificación de correo, protección contra fuerza bruta y rotación de refresh están habilitadas. Los atributos de partner y canal solo pueden modificarse por administración. Los roles de realm no conceden permisos de negocio por sí mismos: VortexBird los obtiene de PostgreSQL.

El bootstrap administra **Keycloak**. El primer administrador de la **aplicación VortexBird** se vincula posteriormente mediante el CLI backend, utilizando el `sub` real del usuario creado en Keycloak. Son operaciones distintas; no se siembra un usuario ficticio para superar validaciones. Deshabilita la inyección de bootstrap después del alta administrativa y conserva el secreto según el procedimiento autorizado.

Al iniciar, Keycloak omite un realm que ya existe. Cambiar el template o `VORTEXBIRD_PORTAL_ORIGIN` no actualiza automáticamente un realm existente: se debe revisar y aplicar un cambio administrativo explícito. No se usa `import --override` ni se sobrescriben usuarios. Recuperación y verificación por correo requieren configurar SMTP por un canal autorizado antes de ofrecerlas como funcionales.

## Comprobaciones pendientes sobre la imagen real

Tras construirla en un entorno autorizado: probar un PostgreSQL aislado con TLS, importación inicial y reinicio sin sobrescritura; comprobar metadata issuer, audiencia y PKCE; ejecutar `test:e2e:live` contra el portal; verificar health 9000 y discovery JDBC entre dos tareas antes de declarar alta disponibilidad. El acceso AWS y el presupuesto aprobado siguen siendo requisitos para publicar y desplegar.

## Fuentes primarias consultadas

- [Keycloak: descargas y versión oficial](https://www.keycloak.org/downloads)
- [Keycloak: contenedor y build optimizado](https://www.keycloak.org/server/containers)
- [Keycloak: importación y placeholders de entorno](https://www.keycloak.org/server/importExport)
- [Keycloak: health y puerto de gestión](https://www.keycloak.org/observability/health)
- [Keycloak: caché distribuida y JDBC discovery](https://www.keycloak.org/server/caching)
- [AWS: certificados CA para RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
- [Bundle CA público de RDS](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem)

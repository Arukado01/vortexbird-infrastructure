# Ejecución local nativa en Windows

Este procedimiento permite ejecutar la misma aplicación sin Docker en una sesión Windows con sockets locales habilitados. No acredita que la plataforma esté funcionando en la sesión restringida del agente: el intento del 17 de noviembre de 2026 no superó el arranque. Docker no pudo acceder a su motor, WSL devolvió `Wsl/E_ACCESSDENIED`, ElasticMQ falló con `java.net.SocketException: Permission denied: connect` y las conexiones PostgreSQL/HTTP devolvieron error de socket `10013`.

## Un inicio y una detención

Desde la carpeta contenedora:

```powershell
pwsh -NoProfile -File ./vortexbird-infrastructure/scripts/Start-Native.ps1 -ValidateOnly
./Iniciar-VortexBird.cmd native
./Detener-VortexBird.cmd native
```

Sin el argumento `native`, ambos lanzadores conservan Docker Compose. La alternativa requiere PowerShell 7.4 o posterior; no altera políticas de ejecución ni permisos del sistema.

`-ValidateOnly` comprueba rutas, variables obligatorias y configuración. No inicia procesos, no crea bases ni prueba conexiones; su resultado PASS no significa que los servicios estén listos. El arranque real exige SQL autenticado, migraciones de API, discovery OIDC con emisor correcto, las dos colas de ElasticMQ, portal HTTP y, si está habilitado, login de demostración a través del frontend. La salud del worker no sustituye una prueba de procesamiento y compensación de pedidos.

## Dependencias y ubicación

Los binarios de terceros y los secretos no se incluyen en el paquete de fuentes. Antes de usar una copia nueva, instalar .NET SDK 10 y Node, ejecutar `dotnet restore` en backend y `npm ci` en frontend y preparar estas dependencias. El launcher permite rutas explícitas para evitar depender del directorio temporal de una sesión anterior.

| Dependencia | Ruta predeterminada relativa a la carpeta contenedora | Parámetro alternativo |
| --- | --- | --- |
| PostgreSQL 17.12 servidor (`initdb`, `postgres`, `pg_ctl`) | `.work/closure-pg-native/bin` | `-PostgresBinDirectory` |
| PostgreSQL cliente (`psql`, `createdb`) | `.work/closure-pg-edb/pgsql/bin` | `-PostgresClientBinDirectory` |
| ElasticMQ 1.6.12, Java 17+ en PATH | `.work/elasticmq-1.6.12.jar` | `-ElasticMqJar` |
| Keycloak 26.4.0 descomprimido dentro del workspace | `.work/validation-20261117/keycloak-26.4.0` | `-KeycloakDirectory` |
| JDK de Keycloak instalado en esta máquina | `C:/Program Files/Eclipse Adoptium/jdk-25.0.1.8-hotspot` | `-JavaHome` |
| Variables locales | `vortexbird-infrastructure/.env` | Ejecutar `scripts/Initialize-Local.ps1` únicamente si falta |

El launcher no descarga ni instala programas. En la máquina actual estos prerrequisitos pasaron validación de rutas; su acceso a red sigue limitado por la sesión. El JDK, Keycloak y PostgreSQL usados deben mantenerse compatibles con sus versiones; las rutas son entradas operativas, no una certificación de compatibilidad productiva.

```powershell
./scripts/Start-Native.ps1 -ValidateOnly `
  -PostgresBinDirectory D:/tools/postgresql/bin `
  -PostgresClientBinDirectory D:/tools/postgresql/bin `
  -ElasticMqJar D:/tools/elasticmq-1.6.12.jar `
  -KeycloakDirectory D:/ProProjects/react/vortexBird/.work/keycloak-26.4.0 `
  -JavaHome 'C:/Program Files/Eclipse Adoptium/jdk-25.0.1.8-hotspot'
```

## Datos, puertos y servicios

- PostgreSQL crea un cluster independiente en `.work/native-runtime/postgres`, usuario/base `vortexbird`, autenticación SCRAM y puerto **55433**. No reutiliza ni borra clusters anteriores. `-PostgresPort` permite cambiar el puerto. La contraseña procede de `.env`; el archivo de paso de contraseña a `initdb` se elimina al terminar.
- La API se publica en `.work/native-runtime/api`, ejecuta migraciones y seed exclusivamente en Development. Los workers corren en el proceso de la API. Las credenciales se transmiten en el entorno del proceso y no se imprimen.
- Frontend usa Vite ligado a loopback y proxy a la API. API, portal y Keycloak leen los puertos configurados en `.env`. En la configuración observada: **API 15080, portal 5173, Keycloak 18080**. Estas direcciones no quedaron verificadas como disponibles. Los valores predeterminados de Compose son diferentes.
- El realm nativo usa una identidad sintética `demo-admin` vinculada al seed y las credenciales de demo locales. Los redirects del realm usan `http://localhost:5173`; cambiar ese puerto exige actualizar el realm. Cambios en el archivo de importación no modifican automáticamente un realm ya importado: no se eliminan sus datos para forzar reimportación.
- ElasticMQ escucha exclusivamente en **127.0.0.1:9324**, con cola `vortexbird-events` y DLQ. No utiliza claves AWS reales. Sus mensajes son efímeros; no es SQS productivo.
- Redis se desactiva en la alternativa nativa. La caché es opcional; PostgreSQL conserva la fuente de verdad. No se afirma haber probado Redis nativo. Compose conserva su Redis real.
- Pagos y adaptadores empresariales permanecen simulados. No se ejecutan cobros ni solicitudes a proveedores productivos.

## Verificación, logs y parada

```powershell
# Ajustar al API_PORT actual de .env; ejecutar después del arranque exitoso.
Invoke-RestMethod http://127.0.0.1:15080/health/ready
Get-Content .work/native-runtime/api.stderr.log -Tail 50
Get-Content .work/native-runtime/frontend.stderr.log -Tail 50
Get-Content .work/native-messaging/stdout.log -Tail 50
pwsh -NoProfile -File ./vortexbird-infrastructure/scripts/Stop-Native.ps1
```

La parada comprueba PID, hora de inicio y ejecutable antes de detener un proceso; no adopta procesos ajenos ni libera puertos matando aplicaciones. PostgreSQL usa una parada limpia; los datos de PostgreSQL y Keycloak permanecen. Si el arranque falla, no anuncia READY. Conserva los logs y permite detener las partes iniciadas con el mismo comando. Un proceso vivo por sí solo nunca representa una validación funcional completa.

El primer clúster incompleto se conservó en `.work/native-runtime/postgres-incomplete-20261117`. El clúster activo se inicializó después en `.work/native-runtime/postgres` y respondió a una consulta SQL autenticada desde Windows. El lanzador reutiliza sus datos. La siguiente comprobación de OIDC y de negocio está descrita en [la continuación nativa](native-continuation.md).

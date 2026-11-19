# Continuación local desde Windows

Ejecutar **una sola vez**, desde una consola normal de Windows situada en la carpeta que contiene los cuatro repositorios:

```powershell
.\Continuar-VortexBird.cmd -RunLiveTests -RunBusinessTests
```

Para revisar también la infraestructura de Ohio en la misma ejecución, añade `-ReviewAwsPlan`. Con ese parámetro se comprueban primero la cuenta AWS del perfil `default`, el inventario y los cambios que propondría Terraform para la base de ECS. El resumen queda bajo `.work/ecs-first-review/`. Un fallo de AWS permite continuar con los servicios locales. Un fallo posterior de Keycloak conserva el resultado de AWS. El plan de revisión usa estado local desechable, deshabilita los servicios de aplicación y no aprovisiona recursos. La ejecución de un despliegue requiere el plan definitivo con estado remoto.

No requiere abrir una consola como administrador. El lanzador no eleva permisos, no cambia políticas de ejecución, firewall o ACL, no instala software y no inicia Docker. La consola permanece abierta para conservar cualquier error.

## Qué hace este comando

1. Localiza un JDK 25 instalado mediante `VORTEXBIRD_JAVA_HOME`, `JAVA_HOME`, PATH y las carpetas habituales de proveedores dentro de `ProgramFiles`. No incorpora una ruta absoluta específica de esta máquina. Se puede proporcionar una instalación existente con `Continuar-VortexBird.cmd -JavaHome "RUTA_DEL_JDK_25"`.
2. Ejecuta `scripts/Diagnose-Local.ps1` en modo de lectura: configuración, archivos, procesos visibles, listeners y rangos TCP excluidos. No abre conexiones ni inicia servicios en este paso. Un resultado desconocido no se interpreta como puerto libre.
3. Comprueba los prerrequisitos y ejecuta `Start-Native.ps1 -OidcOnly`. Este parámetro desactiva la autenticación de demo solamente en el entorno de los procesos; `.env` no cambia. El portal muestra el acceso real de Keycloak.
4. Inicializa el cluster PostgreSQL nativo si no existe, levanta Keycloak, ElasticMQ, API con workers y frontend, y verifica SQL autenticado, esquema, colas, HTTP y discovery OIDC. Nunca anuncia salud satisfactoria sólo porque haya procesos vivos.
5. Cuando la salud pasa y se indica `-RunLiveTests`, ejecuta la suite de autenticación y autorización de lectura contra esos servicios. La espera respeta el TTL real del token: reservar aproximadamente **6–8 minutos para la suite**, además del tiempo del primer arranque. Conserva los servicios en ejecución al terminar, incluso si las pruebas fallan.
6. Con `-RunBusinessTests`, crea una **base nueva y exclusiva de pruebas** llamada `vortexbird_acceptance_<fechaUTC>_<identificador>`, ejecuta la integración del backend con datos sintéticos y conserva esa base para revisión. No selecciona ni modifica los datos de la base `vortexbird` de la plataforma para esas pruebas.
7. Guarda el resultado y los logs. No ejecuta carga intensa, pagos reales ni solicitudes contra producción. Si una suite falla, intenta las demás comprobaciones independientes solicitadas y conserva los fallos explícitos.

El JDK seleccionado se pasa tanto a Keycloak como a ElasticMQ. Los binarios y dependencias ya existentes se reutilizan. Se requiere PowerShell 7.4 o posterior, .NET SDK 10, Node, dependencias frontend restauradas, PostgreSQL nativo y su cliente, ElasticMQ y Keycloak. En la inspección del 17 de noviembre estos archivos y las variables obligatorias estaban presentes; la versión de PowerShell de la sesión normal del usuario todavía debe satisfacer ese mínimo.

## Estado que conserva y límites

- El directorio de datos activo es `.work/native-runtime/postgres`. El 17 de noviembre PostgreSQL respondió a una consulta autenticada desde Windows. El siguiente inicio reutiliza ese clúster. El intento incompleto anterior se conserva en `.work/native-runtime/postgres-incomplete-20261117`.
- Keycloak 26.4.0 se compila desde el ZIP local verificado y conserva la compilación en `.work/native-runtime/`. Con Keycloak detenido, el primer inicio instala cuatro archivos compilados en `lib/quarkus` de la distribución original. Así, `start --optimized --import-realm` lee la compilación y el realm del mismo directorio. La configuración y la base H2 conservan sus rutas. Los reinicios comparan los cuatro archivos y reutilizan los que coinciden. `-ValidateOnly` comprueba la caché sin activar la compilación.
- El ejecutable Redis nativo no se encontró en PATH. Esta alternativa desactiva expresamente la caché Redis, que es opcional; PostgreSQL sigue siendo la fuente de verdad. No se acredita una prueba Redis ni una instalación nativa completa equivalente a Compose.
- El realm versionado permite recuperación de contraseña, pero no contiene una configuración SMTP. El envío y la recepción de correos permanecen pendientes.
- Pagos y adaptadores ERP/WMS/OMS/CRM continúan en modo simulado. ElasticMQ es un emulador local, no AWS SQS.
- La salud HTTP/SQL no acredita por sí sola login, refresh, logout ni roles: los resultados de la suite conectada se registran aparte y solamente al ejecutarse con éxito. `completeAcceptanceGate` permanece en `false` incluso cuando salud y suites pasan; los flujos de negocio se comprueban sólo en la base sintética, y carga, recuperación y dependencias externas siguen pendientes. AWS no se despliega mediante este comando.
- La misma dirección `127.0.0.1:55433` respondió a SQL en Windows y devolvió 10013 desde la sesión del agente. El diagnóstico de Windows mostró el listener y los rangos excluidos. Sigue sin identificarse la política concreta responsable de la denegación en la sesión del agente.

## Puertos y evidencia

El launcher deriva API, portal y Keycloak de `.env`. La configuración inspeccionada usa API **15080**, portal **5173** y Keycloak **18080**; PostgreSQL nativo usa **55433** y ElasticMQ **9324**. Estas son direcciones configuradas, no endpoints confirmados en esta sesión:

| Servicio | Dirección después de un arranque satisfactorio |
| --- | --- |
| Portal | `http://localhost:5173` |
| API | `http://127.0.0.1:15080` |
| Salud API | `http://127.0.0.1:15080/health/ready` |
| Emisor Keycloak | `http://localhost:18080/realms/vortexbird` |

Archivos que produce la ejecución real, sin contraseñas ni tokens en el resumen:

- `.work/native-runtime/continuation-result.json`: estado, comprobaciones, error y límites.
- `.work/native-runtime/continuation-diagnosis.json`: diagnóstico inicial.
- `.work/native-runtime/continuation.log`: salida resumida del arranque.
- `.work/native-runtime/live-tests.log`: únicamente mensajes seguros del reporter de la suite conectada, sin diagnósticos crudos del proceso.
- `vortexbird-frontend/test-results/live/live-results.json`: cantidades y estados de las pruebas realmente ejecutadas; omisiones con motivo explícito.
- `.work/native-runtime/business-tests.json`: nombre de la base sintética, estado, comprobaciones y conservación de datos de prueba.
- `.work/native-runtime/*.stdout.log`, `*.stderr.log` y `keycloak-*.log`: detalle por componente.
- `.work/native-messaging/stdout.log` y `stderr.log`: mensajería local.

Si falla antes del diagnóstico o de la creación de los informes, el motivo permanece en la consola. Ningún error debe interpretarse como un arranque concluido. La detención opcional sigue siendo `Detener-VortexBird.cmd native`, que verifica la identidad de sus procesos y conserva los datos.

## Pruebas de navegador posteriores

Con `-RunLiveTests`, después de un inicio satisfactorio, el launcher establece temporalmente `LIVE_LOCAL_ENV_FILE` con la ruta absoluta de `vortexbird-infrastructure/.env`, `LIVE_FRONTEND_URL` con el portal iniciado, `LIVE_API_BASE_URL` con su proxy `/api/v1` y `LIVE_OIDC_ISSUER` con el emisor verificado. Estos valores impiden que variables heredadas o `VITE_API_BASE_URL` de `.env` desvíen las pruebas hacia otro endpoint. Cambia al frontend y ejecuta `npm.cmd run test:e2e:live`; restaura las cuatro variables y el directorio de trabajo en `finally`, tanto si hay éxito como si hay error. No modifica credenciales explícitas de las identidades principal o secundaria. No se deben copiar contraseñas en comandos o respuestas.

El usuario principal corresponde al `subject` local `demo-admin` y utiliza `DEMO_EMAIL`/`DEMO_PASSWORD` contra Keycloak. La suite exige el portal en OIDC, que este launcher activa sin modificar `.env`. Las comprobaciones de un segundo rol deben quedar omitidas explícitamente si no existe esa cuenta; no se inventa cobertura de permisos. La rotación de token espera la duración real configurada. El informe se guarda en `vortexbird-frontend/test-results/live/live-results.json`.

Los siete escenarios de identidad cubren peticiones anónimas, credenciales incorrectas, login, recarga SSO, permisos de una segunda cuenta si está configurada, refresh y logout. En loopback se incluyen cuatro recorridos de lectura de administración, operación y los once manuales con y sin sesión. El informe detalla los casos ejecutados y las omisiones.

El launcher exige un código de salida cero y un reporte nuevo y válido. Un reporte previo o una ejecución con fallos no se presentan como aprobados. Las omisiones dejan cobertura parcial y la puerta completa permanece incumplida. Sin parámetros de pruebas sólo se ejecuta el arranque y la salud. `-ValidateOnly`, incluso combinado con los parámetros de pruebas, no inicia servicios ni pruebas.

Esta suite no se ha ejecutado contra un servidor disponible durante la sesión restringida. El comando está preparado para la única intervención del usuario en Windows normal; no se ha lanzado una consola externa para sortear las restricciones del agente.

## Pruebas de negocio aisladas

`-RunBusinessTests` habilita el helper `vortexbird-backend/scripts/Invoke-LocalBusinessChecks.ps1`. Requiere el PostgreSQL nativo iniciado, un cliente `psql`, permiso `CREATE DATABASE`, el backend compilado en Release y el puerto local **5089** disponible para la API temporal. El launcher publica Release antes de invocarlo.

El helper usa `127.0.0.1`, una base nueva, el proveedor de pagos `Simulator` y dos colas ElasticMQ exclusivas por ejecución. La API de pruebas utiliza Redis desactivado. El portal principal sigue en OIDC.

Los casos revisan idempotencia, conflicto de payload, compensación, liquidación concurrente y el dashboard. Comprueban visibilidad, reentrega, acuse, DLQ y replay en ElasticMQ. Una consulta en PostgreSQL coteja cinco eventos, dos reservas y una confirmación. La prueba reinicia su propia API y comprueba que ambas órdenes conservan su historial. Los logs de la API temporal quedan bajo `.work/native-runtime/business-runs/`.

El resultado sólo se considera aprobado con un informe nuevo, estado satisfactorio y comprobaciones registradas. La creación de la base o cualquier prueba puede fallar; el informe conserva ese fallo y nunca elimina una base existente. Sin `-RunBusinessTests` no se ejecuta esta suite. `-ValidateOnly` evita ambas suites aunque se incluyan sus parámetros.

# Cola SQS emulada para la demo local

El Compose principal usa el transporte local persistido en PostgreSQL. Para ejercitar el adaptador SQS, el overlay opcional `compose.sqs.yaml` incorpora `softwaremill/elasticmq-native:1.6.12` y las colas declaradas en `messaging/elasticmq.conf`. No crea recursos AWS.

Con el `.env` local ya generado:

```powershell
docker compose -f compose.yaml -f compose.sqs.yaml config --quiet
docker compose -f compose.yaml -f compose.sqs.yaml up --build -d
docker compose -f compose.yaml -f compose.sqs.yaml ps
```

El backend alcanza el emulador por `http://elasticmq:9324`; desde el equipo se expone solo `http://localhost:9324`. El overlay define credenciales ficticias exclusivas del emulador y desactiva EC2 metadata. No usa claves del perfil AWS del usuario. La configuración `Messaging:ServiceUrl` solo se admite en Development; Kubernetes usa SQS con EKS Pod Identity y el proveedor de credenciales de contenedor, sin endpoint personalizado ni claves estáticas. Desactivar EC2 metadata no desactiva ese proveedor de credenciales.

| Parámetro | Configuración local |
|---|---|
| Cola estándar | `vortexbird-events` |
| DLQ | `vortexbird-events-dlq` |
| Visibilidad | 120 segundos |
| Long polling | 20 segundos |
| Recepciones antes de DLQ | 5 |
| Región / cuenta emulada | `us-east-2` / `000000000000` |

El archivo emplea las claves camelCase de ElasticMQ 1.x. No se habilita persistencia del emulador: reiniciarlo puede perder mensajes ya entregados a esa cola; el outbox duradero no recupera automáticamente eventos que ya marcó como publicados. Usar únicamente para ensayos locales y reiniciar también los datos de la prueba de forma deliberada cuando sea necesario. En AWS, SQS administra retención y durabilidad; la configuración Terraform incluye redrive, cifrado y políticas TLS.

Validación realizada: parseo del overlay YAML, combinación con Compose y comprobaciones estáticas de endpoints, credenciales dummy, visibilidad y DLQ. No se descargó la imagen ni se inició el emulador porque el entorno del agente no puede acceder al daemon Docker. Queda pendiente comprobar envío, recepción, duplicados, visibilidad y redrive con el proceso ejecutándose. La compatibilidad parcial de ElasticMQ no sustituye una prueba contra SQS real ni garantiza un objetivo de rendimiento.

Fuentes oficiales consultadas: [configuración y limitaciones de ElasticMQ](https://github.com/softwaremill/elasticmq), [imágenes publicadas por SoftwareMill](https://hub.docker.com/r/softwaremill/elasticmq-native/tags). El README actual explica que las claves de configuración 1.x utilizan camelCase; se conserva esa forma para la versión fijada.

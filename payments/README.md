# Mercado Pago Sandbox: configuración explícita

El Compose principal conserva `Payments__Provider=Simulator`. Este directorio documenta la conexión a una cuenta **de pruebas**; no contiene credenciales ni realiza pagos reales. `compose.payments-sandbox.yaml` es un overlay opcional y la bandera `MP_SANDBOX_ENABLED` permanece deshabilitada por defecto.

## Datos requeridos

| Variable local | Configuración .NET | Origen |
|---|---|---|
| `MP_SANDBOX_ENABLED` | `Payments:Sandbox:Enabled` | Cambiar a `true` solo para una prueba autorizada con cuenta de test |
| `MP_TEST_ACCESS_TOKEN` | `Payments:Sandbox:AccessToken` | Token de prueba de la aplicación del proveedor |
| `MP_TEST_SELLER_ID` | `Payments:Sandbox:ExpectedTestSellerId` | Identificador verificado del vendedor de pruebas |
| `MP_WEBHOOK_SECRET` | `Payments:Sandbox:WebhookSecret` | Secreto de firma del webhook de la aplicación, de al menos 32 caracteres |
| `MP_NOTIFICATION_URL` | `Payments:Sandbox:NotificationUrl` | URL HTTPS real y alcanzable para el endpoint implementado de notificaciones |
| `MP_RETURN_URL` | `Payments:Sandbox:ReturnUrl` | URL HTTPS real del portal a la que vuelve el comprador de pruebas |

Los nombres anteriores se trasladan sin cambios al backend. No hay dominios, identificadores de cuenta o certificados de ejemplo que puedan confundirse con recursos provisionados. Revisar el README del backend para la ruta exacta del webhook y requisitos del vendedor de pruebas. El portal local sin una URL HTTPS alcanzable no permite validar entrega externa de webhooks por sí solo.

## Uso local tras configurar las credenciales

Crear manualmente `.env.payments-sandbox` a partir de `payments/sandbox.env.example`, conservar el archivo fuera de Git y completar únicamente valores de sandbox. La configuración local general `.env` ya existente no se reemplaza.

```powershell
docker compose --env-file .env --env-file .env.payments-sandbox -f compose.yaml -f compose.payments-sandbox.yaml config --quiet
docker compose --env-file .env --env-file .env.payments-sandbox -f compose.yaml -f compose.payments-sandbox.yaml up --build -d
```

No ejecutar `docker compose config` sin `--quiet` con secretos poblados: puede mostrarlos en la terminal. Con `Payments:Provider=MercadoPagoSandbox` y `Enabled=false`, el backend rechaza el arranque. Solo cambiar a `true` después de completar y verificar las credenciales de prueba. El vendedor debe tener un ID positivo y coincidir con la cuenta de test; ambas URLs deben ser HTTPS con DNS público permitido. La configuración incompleta se rechaza y no cambia silenciosamente al simulador.

La integración permanece **configurada y no verificada contra Mercado Pago** hasta comprobar cuenta de test, crear una intención real de sandbox, recibir y validar su webhook, reconciliar estado y probar idempotencia. La simulación disponible por defecto no acredita esos resultados.

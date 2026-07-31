# ClaudeUsageBar

App de macOS que vive en la menu bar y muestra, de un vistazo, cuánto llevás consumido de tus
límites de Claude Code: el porcentaje de la ventana de 5 horas siempre visible, y al abrir el
popover el detalle de la ventana semanal, los límites por modelo, y cuánto falta para cada reset.

> No estoy afiliado a Anthropic. Es una herramienta no oficial, hecha para uso personal y
> publicada por si a alguien más le sirve.

## Requisitos

- macOS 14 (Sonoma) o superior
- [Claude Code](https://claude.com/claude-code) instalado y con sesión iniciada

El segundo requisito no es opcional: la app no tiene login propio y no sirve de nada sin Claude
Code configurado en la misma máquina.

## Instalación

Bajá el `.dmg` de la [última release](../../releases/latest), abrilo y arrastrá la app a
Aplicaciones. Está firmada con Developer ID y notarizada por Apple, así que abre sin vueltas ni
advertencias de Gatekeeper.

La primera vez vas a ver dos cosas:

1. Una pantalla de onboarding que explica qué se lee y para qué. Hasta que aceptes, la app no
   toca ni el llavero ni la red.
2. Un diálogo del sistema pidiendo permiso para acceder al item `Claude Code-credentials` del
   llavero. Es macOS preguntando, no la app. Conviene darle **Permitir siempre** para que no
   vuelva a preguntar en cada arranque.

## Qué hace con tus credenciales

Es lo más importante del README, así que va explícito:

- **Lee** el token OAuth que el CLI `claude` ya guardó en tu llavero. Solo lo lee: nunca escribe
  en el llavero ni crea items propios.
- **Lo usa** como `Bearer` en una única petición, `GET https://api.anthropic.com/api/oauth/usage`,
  contra los servidores de Anthropic y nadie más. No hay analytics, ni telemetría, ni ningún otro
  destino de red en el binario.
- **Nunca lo loguea, lo cachea ni lo muestra.** Se relee del llavero en cada petición justamente
  para no tenerlo dando vueltas en memoria ni en disco.
- **Nunca lo refresca.** El token caduca cada ~8h y Claude Code lo renueva solo. Si esta app
  intentara refrescarlo rotaría el refresh token y te rompería la sesión del CLI.

Lo único que se guarda en disco es el último snapshot de porcentajes en `UserDefaults`, para
poder mostrar algo cuando no hay red. Ese snapshot no contiene el token.

El código está acá entero: si algo de esto no te cierra, `Features/Usage/Services/` son cien
líneas y se leen en cinco minutos.

## Limitaciones conocidas

Vale la pena decirlas antes de que las descubras:

- **El endpoint no está documentado.** `GET /api/oauth/usage` es el que usa Claude Code
  internamente. Anthropic puede cambiarlo o retirarlo sin aviso, y el día que pase la app va a
  dejar de mostrar datos hasta que salga una versión nueva.
- **El `User-Agent` va pinneado a mano** a una versión de Claude Code. Sin ese header el endpoint
  responde 429 de forma persistente durante horas. Es el punto más frágil del diseño: si en algún
  momento deja de aceptarse, hace falta build nueva.
- **El polling es deliberadamente conservador**: 180s de intervalo mínimo y backoff 3→6→12→15min
  ante un 429. No esperes que el número reaccione al instante.
- Los porcentajes salen del servidor ya calculados y son una métrica ponderada: no son
  `tokens / límite`, y la ventana cuenta el uso de todos tus dispositivos, no solo de esta máquina.

## Compilar desde fuente

```bash
xcodebuild -project ClaudeUsageBar/ClaudeUsageBar.xcodeproj \
  -scheme ClaudeUsageBar -destination 'platform=macOS' build

xcodebuild -project ClaudeUsageBar/ClaudeUsageBar.xcodeproj \
  -scheme ClaudeUsageBar -destination 'platform=macOS' test
```

Para generar un DMG firmado y notarizado hace falta un certificado Developer ID propio y un
perfil de `notarytool` configurado; con eso, `./scripts/release.sh` hace el resto.

## Licencia

MIT — ver [LICENSE](LICENSE).

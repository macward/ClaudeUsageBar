# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-07-31

### Added

- Primera versión distribuible: DMG firmado con Developer ID y notarizado por Apple, con
  `scripts/release.sh` para reproducir el empaquetado completo (tests, archive, export, firma,
  notarización, staple y verificación con Gatekeeper).
- Icono de la app en todos los tamaños de macOS.
- Los límites semanales por modelo se muestran con el nombre del modelo en el título
  («Semanal · Fable»), leídos de `limits[].scope.model.display_name`.
- Monitor de consumo en la menu bar: muestra el porcentaje de la ventana de 5 horas (la sesión)
  sin abrir el popover, y el detalle de ambas ventanas, sus límites por modelo activos, el tiempo
  hasta el reset —en horas y minutos, o días y horas según la escala— y la antigüedad del dato al
  abrirlo. Los límites que solo repiten una ventana ya mostrada se descartan, y las claves del
  endpoint nunca llegan crudas a la pantalla.
- Lectura del consumo desde `GET /api/oauth/usage` reutilizando el token OAuth que el CLI `claude`
  ya guardó en el Keychain. La app nunca escribe en el Keychain ni refresca el token.
- Política de red conservadora: intervalo mínimo de 180s, backoff 3→6→12→15min ante 429, y último
  snapshot cacheado como fallback cuando la red falla.
- Onboarding de primer arranque que explica qué se lee y para qué **antes** de que macOS pida
  autorización. Hasta pulsar «Autorizar» la app no toca ni el Keychain ni la red.
- Estado de acceso denegado con reintento manual. Una denegación detiene el ciclo de polling y da
  de baja el observador de wake, de modo que la app nunca vuelve a pedir autorización por su cuenta.
- Spike de viabilidad (`ClaudeUsageBar/Spike/`) que valida, desde el target real sandboxed, las tres
  premisas del proyecto: lectura del item de keychain `Claude Code-credentials`, acceso al endpoint
  `GET /api/oauth/usage`, y lectura de los transcripts en `~/.claude/projects`.
- Entitlement `com.apple.security.network.client` — la app necesita red, contra el supuesto
  inicial de que sería local-only.
- `LSUIElement = YES` para que la app viva solo en la menu bar, sin icono en el Dock.

### Changed

- La scene principal pasa de `WindowGroup` a `MenuBarExtra`.
- El deployment target baja de macOS 26.5 a macOS 14.0 (Sonoma), que es el piso real que imponen
  `@Observable` y `.environment(_:)`. Con 26.5 la app solo corría en la última versión del sistema.

### Fixed

- El límite semanal por modelo no aparecía en el popover. El endpoint marca `is_active: true`
  únicamente en el límite más cercano a su tope, no en todos los que aplican, así que filtrar por
  ese flag descartaba en silencio límites reales. Ahora se listan todos los que traen un porcentaje
  usable y la deduplicación contra las ventanas nombradas se hace por scope y hora de reset.

### Removed

- El spike de viabilidad completo (`ClaudeUsageBar/Spike/`), sustituido por la implementación real.
- Entitlements que el diseño final no usa: `ENABLE_USER_SELECTED_FILES` (el parseo de transcripts
  quedó descartado, bloqueado por el sandbox) y `REGISTER_APP_GROUPS`. Los entitlements efectivos
  se reducen a `app-sandbox` y `network.client`.
- `Item.swift`, `ContentView.swift` y el `ModelContainer` de SwiftData (residuos del template de
  Xcode, incluido el `fatalError` de creación del contenedor).
- El target `ClaudeUsageBarUITests`, que no aportaba cobertura real y provocaba cuelgues al
  ejecutarse.

[1.0.0]: https://github.com/macward/ClaudeUsageBar/releases/tag/v1.0.0

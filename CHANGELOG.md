# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Monitor de consumo en la menu bar: muestra el porcentaje de la ventana más cargada (5h o semanal)
  sin abrir el popover, y el detalle de ambas ventanas, sus límites por modelo activos, el tiempo
  hasta el reset y la antigüedad del dato al abrirlo.
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

### Removed

- El spike de viabilidad completo (`ClaudeUsageBar/Spike/`), sustituido por la implementación real.
- Entitlements que el diseño final no usa: `ENABLE_USER_SELECTED_FILES` (el parseo de transcripts
  quedó descartado, bloqueado por el sandbox) y `REGISTER_APP_GROUPS`. Los entitlements efectivos
  se reducen a `app-sandbox` y `network.client`.
- `Item.swift`, `ContentView.swift` y el `ModelContainer` de SwiftData (residuos del template de
  Xcode, incluido el `fatalError` de creación del contenedor).

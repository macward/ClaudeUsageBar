# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Spike de viabilidad (`ClaudeUsageBar/Spike/`) que valida, desde el target real sandboxed, las tres
  premisas del proyecto: lectura del item de keychain `Claude Code-credentials`, acceso al endpoint
  `GET /api/oauth/usage`, y lectura de los transcripts en `~/.claude/projects`.
- Entitlement `com.apple.security.network.client` — la app necesita red, contra el supuesto
  inicial de que sería local-only.
- `LSUIElement = YES` para que la app viva solo en la menu bar, sin icono en el Dock.

### Changed

- La scene principal pasa de `WindowGroup` a `MenuBarExtra`.

### Removed

- `Item.swift`, `ContentView.swift` y el `ModelContainer` de SwiftData (residuos del template de
  Xcode, incluido el `fatalError` de creación del contenedor).

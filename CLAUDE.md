# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

meridian-project: claude-usage-bar

## Project Overview

**ClaudeUsageBar** es una app de macOS que vive en la menu bar (status bar) y muestra, de un vistazo, el estado de consumo de Claude Code:

- **Tokens consumidos** en la sesión / ventana de uso actual (input, output, cache read/creation).
- **Cuánto queda** de la ventana de uso vigente: porcentaje/tokens restantes y tiempo restante.
- **Cuándo se reinicia** la ventana: fecha y hora del próximo reset, además del tiempo relativo ("en 2h 15m").

La app es de solo lectura: no escribe nada y no autentica por sí misma, pero **sí hace red** y **sí usa credenciales** — reutiliza el token OAuth que Claude Code ya guardó en el Keychain.

### Fuentes de datos

Validado empíricamente por el spike en `ClaudeUsageBar/Spike/` (ver "Known Issues"):

| Dato | Fuente | Estado |
|---|---|---|
| % usado, reset, severity, weekly, spend | `GET https://api.anthropic.com/api/oauth/usage` | **fuente de verdad** |
| Fallback sin red / con 429 | último snapshot cacheado | — |
| Tokens, coste, burn rate, breakdown por modelo | `.jsonl` en `~/.claude/projects/` | bloqueado por sandbox |

**El endpoint es la única fuente posible para el porcentaje y el reset.** `utilization` es una métrica ponderada y opaca del servidor: no es `tokens / límite`, ninguna suma de tokens locales la reproduce, y la ventana es cross-device (cuenta el uso de otras máquinas). Es un endpoint **no documentado** — el decoder debe tolerar campos ausentes y claves internas que van y vienen (`tangelo`, `seven_day_omelette`, `iguana_necktie`).

Contrato observado:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/<version>     ← sin esto, 429 persistentes por horas
Content-Type: application/json
```

```json
{ "five_hour": { "utilization": 55.0, "resets_at": "2026-07-30T06:29:59.393695+00:00" },
  "seven_day": { "utilization": 18.0, "resets_at": "..." },
  "limits": [ { "kind": "session", "percent": 55, "severity": "normal", "resets_at": "...", "is_active": true } ] }
```

Tercera fuente disponible pero no usada: Claude Code ya empuja `rate_limits.five_hour.used_percentage` / `resets_at` por stdin a los statusline scripts. No requiere Keychain ni polling, pero solo se actualiza cuando hay una sesión activa.

Implicaciones de diseño:

- **Polling caro y frágil**: TTL de 180s, backoff exponencial 3→6→12→15min cap en 429. Nunca poll agresivo.
- **Nunca refrescar el token**: el `accessToken` caduca cada ~8h y Claude Code lo renueva solo. Re-leer el Keychain en cada llamada, nunca cachear el token. Si la app refrescara, rotaría el refresh token y rompería el login del usuario.
- **Nunca loguear ni renderizar el token.** El único campo sensible que la app toca.
- El parseo de `.jsonl`, si se implementa, debe ser **incremental y tolerante a fallos**: crecen mientras se leen, tienen líneas parciales al final y tipos de evento desconocidos. Nunca fallar todo el parseo por una línea inválida.

## Estado actual del código

El repo tiene **solo el spike de viabilidad**, no la app. El template de Xcode ya fue removido (`Item.swift`, `ContentView.swift`, SwiftData y su `fatalError`), la scene es `MenuBarExtra`, y `ClaudeUsageBar/Spike/` contiene tres probes que corren al arranque vía `SpikeAppDelegate`.

`Spike/` es código desechable: se borra cuando empiece la implementación real. Lo que hay que conservar de ahí es el `KeychainCredentialsProbe` (lógica de lectura), el decoder de `UsageSnapshot` y el parseo de timestamps — todo eso se promueve a `Features/Usage/` y `Shared/Services/`.

Pendiente: los tests (`ClaudeUsageBarTests`, `ClaudeUsageBarUITests`) siguen siendo stubs del template.

## Tech Stack

### Core

- Swift 6, SwiftUI
- macOS only (`SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 26.5`)
- `MenuBarExtra` como scene principal

### State Management

- `@Observable` para view state
- Inyección de dependencias manual (initializers y `@Environment`, sin librerías)

### Networking

- `URLSession` directo. **No** NetKit: es una sola petición GET a un endpoint no documentado; una capa de abstracción encima no aporta nada.
- Requiere `com.apple.security.network.client` (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`).

### Credentials

- Lectura del Keychain vía `SecItemCopyMatching`, `kSecClassGenericPassword`, `kSecAttrService = "Claude Code-credentials"`. El payload es JSON; el token vive en `claudeAiOauth.accessToken` y `expiresAt` viene en **milisegundos** epoch.
- La app nunca escribe en el Keychain ni crea items propios.

### Logging

- OSLog (nativo). El token nunca se loguea.

### Not Using (yet)

- SwiftData / Core Data — sin necesidad real de persistencia todavía
- Navigation stacks / AppRouter: la UI es un popover de menu bar
- Feature flags / analytics de terceros

## Build & Run Commands

**Usar siempre `xcodebuild`. Nunca `swift build` / `swift test`.**

```bash
# Build
xcodebuild -project ClaudeUsageBar/ClaudeUsageBar.xcodeproj \
  -scheme ClaudeUsageBar -destination 'platform=macOS' build

# Todos los tests
xcodebuild -project ClaudeUsageBar/ClaudeUsageBar.xcodeproj \
  -scheme ClaudeUsageBar -destination 'platform=macOS' test

# Un solo test (Target/Suite/testFunction)
xcodebuild -project ClaudeUsageBar/ClaudeUsageBar.xcodeproj \
  -scheme ClaudeUsageBar -destination 'platform=macOS' \
  -only-testing:ClaudeUsageBarTests/ClaudeUsageBarTests/example test

# Lint
swiftlint
```

Único scheme: `ClaudeUsageBar`. Targets: `ClaudeUsageBar`, `ClaudeUsageBarTests`, `ClaudeUsageBarUITests`.

## Project Structure

Estructura por feature (crearla a medida que se implementa; hoy los archivos están planos en `ClaudeUsageBar/ClaudeUsageBar/`):

```
ClaudeUsageBar/ClaudeUsageBar/
├── App/                 # ClaudeUsageBarApp.swift, Configuration/
├── Features/            # p. ej. Usage/ con Views/, ViewModels/, Repositories/, Models/
├── Shared/              # Services/, Components/, Extensions/, Models/
└── Resources/
```

- Cada feature contiene solo lo que necesita.
- `Shared/` es para código usado por 2+ features.
- Features simples no necesitan subcarpetas.

## Architecture & Patterns

### Layers

```
View → ViewModel (cuando hace falta) → Repository → Service/FileSystem
```

Para esta app eso se traduce en: un service que lee/observa los `.jsonl` de `~/.claude`, un repository que agrega usage por sesión y por ventana temporal, y un ViewModel que expone el estado listo para pintar (tokens usados, restantes, fecha de reset).

### ViewModels

- Usar ViewModel cuando la view tiene lógica compleja, múltiples estados, o necesita unit tests
- Views simples pueden usar `@State` + `@Environment` sin ViewModel
- Un ViewModel por pantalla raíz
- SIEMPRE `final class` + `@Observable` + `@MainActor`
- No importar SwiftUI salvo que sea estrictamente necesario para tipos de navegación
- NUNCA lógica de negocio directamente en Views

Regla de decisión: ¿necesita una dependencia externa? → ViewModel. ¿La lógica es compleja o async? → ViewModel. Si no → `@State`.

### Dependency Injection

- SIEMPRE `@Environment` para compartir services y estado entre views
- NUNCA singletons ni instancias `shared`
- Inyectar dependencias en el root de la App
- Los ViewModels reciben dependencias por init

### Async/Await

- SIEMPRE async/await, NUNCA completion handlers
- `.task` para trabajo async en Views
- `AsyncStream` para streams continuos (file watching, conversión de delegates) — el cleanup va en `onTermination`
- NUNCA `DispatchQueue.main.async` — usar MainActor
- NUNCA `try!` en código async
- Chequear `Task.isCancelled` / `try Task.checkCancellation()` en loops largos

### Error Handling

- Los ViewModels capturan errores y exponen estado (propiedad `error`)
- No propagar errores a las Views con `throws`; las Views reaccionan al estado de error

### Component Hierarchy (Atomic Design)

- **Controls** — elemento UI indivisible, sin dependencias, sin ViewModel, configurado por parámetros
- **Composites** — combinan controls en una unidad funcional; sin dependencias ni ViewModel; reciben datos y emiten eventos por callbacks; reutilizables
- **Components** — combinan composites y controls en una sección completa; pueden tener ViewModel y dependencias inyectadas

Controls y composites se mantienen puros y reutilizables; los components tienen la inteligencia y la coordinación.

### Naming Conventions

- SIEMPRE nombres completos, nunca abreviaturas
- Views: `UsageMenuView`; ViewModels: `UsageMenuViewModel`; Repositories: `UsageRepository`; Services: `TranscriptFileService`

### Patterns to Avoid

Completion handlers · `DispatchQueue.main.async` · `Task { @MainActor in }` estando ya en MainActor · `.task` con `Task { }` anidado · `try!` en async · singletons

## Code Style

- `guard` para early exit
- Anotaciones de tipo explícitas: `let value: String = "text"`
- Trailing closure solo con un único closure, no con varios
- `self` solo cuando es obligatorio (closures, ambigüedad)
- Optional shorthand: `if let value { }`
- SIEMPRE access control explícito en todos los tipos y miembros
- `// MARK: -` para separar secciones (Properties, Lifecycle, Public Methods, Private Methods)
- Conformances a protocolos en extensions separadas
- SwiftLint con reglas por defecto

## Testing Guidelines

- Framework: **Swift Testing** (`@Test`), no XCTest — excepto UI tests, que van en XCUITest (`XCTestCase`, funciones con prefijo `test`)
- Nombres de función: `subjectAction` o `subjectActionCondition`
- SIEMPRE string descriptivo en el macro `@Test`:
  ```swift
  @Test("Usage window reset date is nil when no transcripts exist")
  func usageWindowResetDateNilWithoutTranscripts() async throws { }
  ```
- Mocks: protocolos para dependencias + implementaciones manuales. NO usar librerías de mocking.
- Cobertura: SIEMPRE ViewModels y Repositories; Services solo si tienen lógica; NO unit tests de Views.
- Para el parser de transcripts, tests con fixtures `.jsonl` (incluyendo líneas corruptas/parciales y eventos desconocidos) en lugar de leer `~/.claude` real.
- UI tests: usar `.accessibilityIdentifier(_:)` en las views clave y testear flujos end-to-end.

## Git & Workflow

- Branches: `feature/…`, `fix/…`, `refactor/…`
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`
- Squash merge de PRs
- NUNCA trailers de co-autoría de IA ni atribución de IA en commits o PRs
- Mantener `CHANGELOG.md` (Keep a Changelog + SemVer)

## Known Issues & Gotchas

Hallazgos del spike (2026-07-30), todos verificados corriendo la app real sandboxed + hardened runtime + firmada:

- **El Keychain cross-app funciona, pero con prompt.** Una app sandboxed *sí* puede leer el item que escribió el CLI `claude` (`errSecSuccess`), pero el primer arranque levanta un diálogo de `SecurityAgent` pidiendo autorización. No es transparente: el onboarding tiene que anticiparlo, y hasta que el usuario acepte, la llamada **bloquea**.
- **`ENABLE_USER_SELECTED_FILES = readonly` no alcanza para `~/.claude`.** Bajo sandbox `NSHomeDirectory()` se redirige al container. Trampa concreta: `FileManager.fileExists` sobre la ruta real devuelve `true`, pero `enumerator(atPath:)` rinde **cero** entradas y no lanza error — el sandbox permite `stat` y niega lectura. Un chequeo de existencia da falso positivo; hay que verificar apertura real de un archivo.
- **Los timestamps del endpoint rompen `.iso8601`.** Llegan con 6 dígitos fraccionarios (`2026-07-30T06:29:59.393695+00:00`). Hace falta `ISO8601DateFormatter` con `.withFractionalSeconds` más fallback sin fracción.
- **El `User-Agent` está pinneado a mano** (`claude-code/2.1.220`). Una app sandboxed no puede ejecutar `claude --version`, y sin el header correcto el endpoint devuelve 429 persistentes durante horas. Es el punto de mantenimiento más frágil del diseño.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** está activo. Todo tipo nuevo es `@MainActor` por defecto; las funciones que se pasan como closures `@Sendable` (p. ej. `JSONDecoder.dateDecodingStrategy = .custom`) necesitan `nonisolated` + `@Sendable` explícitos o no compilan.
- `MenuBarExtra` construye su contenido **de forma lazy**: un `.task` en la view del popover no corre hasta que el usuario lo abre. Para trabajo al arranque hace falta `applicationDidFinishLaunching` vía `NSApplicationDelegateAdaptor`.
- Con `LSUIElement = YES` la app no tiene icono en el Dock; el popover necesita su propio "Quit" o queda sin forma de cerrarse.

Preexistentes:

- `SWIFT_VERSION = 6.0` en las 6 build configurations, con `SWIFT_APPROACHABLE_CONCURRENCY = YES`. El código nuevo debe respetar strict concurrency desde el principio.
- `xcuserdata/` está en `.gitignore` y fuera del índice de git. No volver a trackearlo (`git add -f`) — genera ruido de diff en cada apertura de Xcode.
- SourceKit reporta "Cannot find type X in scope" sobre archivos recién creados hasta que se reindexa. `xcodebuild` es la autoridad, no los diagnósticos del editor.

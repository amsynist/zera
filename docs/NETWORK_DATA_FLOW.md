# Zera — Network Data Flow

How this was compiled: every URL literal and HTTP client in `Sources/Zera` was inventoried.
Only two `URLSession` users exist (`GitHubService`, `AnthropicAPIClient`), plus avatar loading in
`GitHubComponents.AvatarCache`. There are no analytics, telemetry, crash-reporting, update-check or webhook
endpoints. There are no third-party SDKs.

| # | Destination | Purpose | Data transmitted | Authentication | Optional? | User-controlled? |
|---|---|---|---|---|---|---|
| 1 | `https://api.github.com` | PR list, details, reviews, comments, check runs, Actions runs; **POST** approve / pending_deployments | Token (header); repo owner / name / PR numbers in paths; search queries (`involves:@me`, date) | `Authorization: Bearer <token>` (token from Keychain) | Yes — only after a token is saved | Connect / Disconnect; token scopes |
| 2 | `https://*.githubusercontent.com` (avatars) | Reviewer / author pictures | HTTP GET of the avatar URL GitHub returned (reveals IP, user agent and which avatars) | None (token never sent; the host is checked to end in `githubusercontent.com`) | Yes (only with GitHub on) | Indirect |
| 3 | `https://api.anthropic.com` (`/v1/models`, `/v1/messages`, SSE) | API-key provider mode | System prompt, file content / extracted text, user question; model choice | `x-api-key` from Keychain | Yes — off unless the user chooses API mode | Settings provider switch; never a silent fallback |
| 4 | **Claude Code CLI** (`claude` subprocess) → Anthropic, or Bedrock / Vertex / proxy per the user's env | Default AI provider (Summarize / Explain / Extract / Ask; PR and session questions) | Prompt + file content or path, PR / session briefs (may include diffs) | The CLI's own login; Zera reads no credentials | Yes — only on user action | Every request is a click |
| 5 | macOS EventKit (OS-managed sync to iCloud / Google / Exchange…) | Calendar read and write | Zera → local EventKit only; macOS syncs created events to that account | macOS accounts | Yes (Connect Calendar) | Settings / per event |
| 6 | `NSWorkspace.open(...)` targets: `github.com/...` PR / notification / pull links, meeting join links (zoom.us, meet.google.com, teams…), Calendar.app, Claude app / Terminal | Opens the user's browser or apps | URL only, opened by the default app | — | User clicks only | Yes |
| 7 | Terminal via Apple Events (`com.apple.security.automation.apple-events`) | "Open Claude" fallback when the Claude app is missing: runs a fixed `claude` command | No user text inserted into the command (per code comments) | — | User click only | Yes |

README-only (not app traffic): `img.shields.io` badges, `github.com/amsynist/zera` links.

## Findings
- **No unexpected telemetry** was found.
- Avatar fetches (#2) reveal the user's IP to GitHub's CDN; this is minor and expected. Document it.
- The highest-sensitivity flow is #4 (and #3): company source or diffs can leave the machine, but only on
  an explicit click. The README's Privacy section says so.
- GitHub **write** calls (#1, POST approve / pending_deployments) need Actions-write access. They are
  opt-in: the README recommends a read-only fine-grained token by default.

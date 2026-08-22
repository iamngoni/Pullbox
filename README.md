# Pullbox

Private iPhone media downloader: paste a permitted media URL, analyze it through a Rust/Actix backend, download an iOS-compatible MP4, and save it directly to Photos.

## Backend

Prerequisites already present on this Mac:

- Rust/Cargo
- `yt-dlp`
- `ffmpeg`

Run it:

```bash
cd /Users/modestnerd/Developer/Projects/Pullbox/backend
cargo run
```

The API listens on all interfaces at port `8787` by default.

Endpoints:

- `GET /health`
- `POST /api/analyze` with `{ "url": "https://…" }`
- `POST /api/download` with `{ "url": "https://…" }`

Override the bind address with `PULLBOX_BIND`, for example:

```bash
PULLBOX_BIND=0.0.0.0:8787 cargo run --release
```

## iPhone app

Open:

```text
/Users/modestnerd/Developer/Projects/Pullbox/ios/Pullbox.xcodeproj
```

The project is generated from `ios/project.yml` with XcodeGen. If project settings change, regenerate it with:

```bash
cd /Users/modestnerd/Developer/Projects/Pullbox/ios
xcodegen generate
```

The app defaults to the public HTTPS endpoint:

```text
https://pullbox.antonlabs.cc
```

The backend address can be changed using the sliders button in Pullbox. The public route is served through Cloudflare Tunnel and Traefik; no shared LAN or Tailscale connection is required.

## Docker deployment

```bash
cd /Users/modestnerd/Developer/Projects/Pullbox
docker compose up -d --build
```

The container joins the existing `media-server_default` network and advertises `pullbox.antonlabs.cc` to Traefik. Cloudflared forwards that public hostname to Traefik. The API is intentionally unauthenticated during personal testing; do not advertise the endpoint or treat it as a multi-user service.

## Install on Ngonidzashe's iPhone

1. Start the backend.
2. Connect/unlock the paired iPhone.
3. Open `Pullbox.xcodeproj` in Xcode.
4. Select the **Pullbox** scheme and **Ngonidzashe’s iPhone 17 Pro**.
5. Press Run.
6. Approve the Photos add-only and Local Network permissions when iOS asks.

The project uses automatic signing with team `4973Y692JU` and bundle identifier `dev.iamngoni.pullbox`.

## Verification

```bash
cd backend && cargo test
cd ../ios/PullboxCore && swift test
cd .. && xcodebuild -project Pullbox.xcodeproj -scheme Pullbox -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```

Only download media that you own or are authorized to save. The backend does not bypass DRM, logins, paywalls, or access controls.

## Private media (cookie jars)

Pullbox can save age-restricted, followers-only, and login-walled posts from platforms you have a session for.

1. In your desktop browser (logged into the platform), export cookies with a "Get cookies.txt LOCALLY" style extension — **Netscape format**.
2. Save the file on the host as `~/Services/Pullbox/cookies/<platform>.txt`:

| Platform | File name |
|---|---|
| Instagram | `instagram.txt` |
| TikTok | `tiktok.txt` |
| Twitter / X | `twitter.txt` |
| Facebook | `facebook.txt` |
| YouTube | `youtube.txt` |

3. Restart: `docker compose -f ~/Services/Pullbox/compose.yaml restart pullbox`

The `cookies/` dir is mounted read-only at `/cookies`; the backend passes `--cookies <platform>.txt` to yt-dlp whenever the URL matches that platform. Never commit these files — they contain live session tokens.

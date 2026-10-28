# App environment

The app needs one setting: `API_BASE_URL`, the server it signs in to. Server secrets (JWT_SECRET, DATABASE_URL,
META_*, SMTP_*) stay in `server/.env` and never go into the app.

| File | Use |
|---|---|
| `dev.json` | Also the live website for now (`https://connect.tyrescart.ae`). To use a local server again, put its website address here, e.g. `http://192.168.1.16:4000`. |
| `prod.json` | **Live**: the live website, `https://connect.tyrescart.ae` (not committed). |
| `demo.json` | **Demo**: the demo website, `https://support.tyrescart.ae` (not committed). Same Firebase settings as `prod.json`. |
| `prod.example.json` | Template for `prod.json`. |

Always the website's address, never the API's own port: the app's live connection uses `/socket.io` without a trailing
slash, which the website (Next.js locally, nginx live) serves; the API port alone only answers `/socket.io/`.

```bash
# Live (real customers and data)
flutter build apk --release --dart-define-from-file=env/prod.json         # live APK (HTTPS only)

# Demo (demo server and data)
flutter run --dart-define-from-file=env/demo.json                         # run on a phone/emulator
flutter build apk --release --dart-define-from-file=env/demo.json         # demo APK

flutter run --dart-define-from-file=env/dev.json                          # development (live server for now)
```

Both builds write `build/app/outputs/flutter-apk/app-release.apk`: copy or rename it after each build so the live and
demo APKs don't overwrite each other. Live and demo builds are the same app (`tech.synex.tyrescart_support`):
installing one replaces the other on a phone.

## Push notifications (Firebase)

Firebase project `tyrescart-support`. The app's Firebase settings are in `prod.json`, taken from the two files Firebase
gave for this app, which are also in the project: `android/app/google-services.json` (package
`tech.synex.tyrescart_support`) and `ios/Runner/GoogleService-Info.plist` (Bundle ID `tech.synex.tyrescartSupport`).
The app reads them from `prod.json` (dart-defines), so no Google Services Gradle plugin or Xcode file reference is used.
They're Firebase's public client identifiers, not secrets; restrict each API key to its app in Google Cloud console →
Credentials.

| Key | From |
|---|---|
| `FIREBASE_PROJECT_ID` | `project_info.project_id` / `PROJECT_ID` |
| `FIREBASE_MESSAGING_SENDER_ID` | `project_info.project_number` / `GCM_SENDER_ID` |
| `FIREBASE_ANDROID_APP_ID` | google-services.json `client.client_info.mobilesdk_app_id` |
| `FIREBASE_ANDROID_API_KEY` | google-services.json `client.api_key.current_key` |
| `FIREBASE_IOS_APP_ID` | GoogleService-Info.plist `GOOGLE_APP_ID` |
| `FIREBASE_IOS_API_KEY` | GoogleService-Info.plist `API_KEY` |
| `FIREBASE_IOS_BUNDLE_ID` | GoogleService-Info.plist `BUNDLE_ID` |

Push still stays off until the server can send: the app asks the server (`pushConfigured`) and registers no device
token before it says yes. That needs the server's service account (`FIREBASE_SERVICE_ACCOUNT_FILE` in `server/.env`),
the `PushDevice` table and the push code deployed; iPhones also need a paid Apple team and the APNs key (see the
app README).

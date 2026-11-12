# flariane_admin

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Push notifications (Firebase)

Admin alerts (new quote request, quote accepted, payment declared…) are sent by the backend through FCM.

1. Firebase console: create a project, add Android apps `com.regisse.flariane.admin` and
   `com.regisse.flariane.admin.integration`, download `google-services.json` into `android/app/`
   (without it the app builds and runs, just without push). The file is gitignored (it holds a Google API key): keep it local or inject it in CI.
2. Project settings → Service accounts → generate a key. On Render set `FLR_PUSH_MODE=live`,
   `FLR_FCM_PROJECT_ID=<project id>` and `FLR_FCM_SERVICE_ACCOUNT_JSON=<the key's JSON>`.
3. Log in on the phone and accept the notification permission: the token is sent to the server.

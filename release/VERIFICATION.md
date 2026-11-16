# Public source validation — 2026-11-16

- Flutter tests: 39 passed.
- Flutter analysis: no issues found.
- Android release build: passed with Flutter 3.47.9 and the documented dependencies.
- Both model files inside the newly built APK match the initial APK model checksums.
- 25 runtime code/resource files match the source baseline manifest.
- The published APK is the original user-designated 0.8.11 APK, not the new test build.
- Public build configuration supports local signing without disclosing the original private key. A locally built APK has a different signing certificate.

The public tests use synthetic images. Historical native manga sample regressions are not republished or rerun here; arbitrary manga accuracy and network availability are not guaranteed.

# pob

A minimal personal browser for macOS, built on WebKit.

Generate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen). New source files are picked up automatically, so you only need to regenerate when `project.yml` changes.

```sh
xcodegen generate
```

Run the tests:

```sh
xcodebuild test -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd
```

Build and open the app:

```sh
xcodebuild build -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd && open build/dd/Build/Products/Debug/pob.app
```

# NotchTheRock 플러그인 만들기

NotchTheRock의 모든 기능은 플러그인이에요. 플러그인은 공개 SDK인 NotchKit만 링크한 Swift 패키지이고,
빌드하면 `.notchplugin` 번들이 돼요. 앱에 들어 있는 내장 기능도 직접 만든 플러그인과 같은 스크립트로
빌드하고 같은 로더로 불러와요. Xcode는 필요 없어요.

## 준비물

| 항목 | 조건 |
|---|---|
| macOS | 14 이상 |
| 도구 | Command Line Tools (`xcode-select --install`), Swift 6 |
| 저장소 | 이 저장소의 클론 (`SDK/NotchKit`과 `scripts/`를 써요) |

## 1. 플러그인 만들기

```sh
scripts/new-plugin.sh Clock                       # Plugins/Clock에 만들어요
scripts/new-plugin.sh Clock --dir ~/Projects      # 다른 폴더에 만들어요
scripts/new-plugin.sh Clock --id com.me.clock     # 식별자를 직접 정해요
```

이름은 대문자로 시작하고 영문자와 숫자만 쓸 수 있어요. 식별자를 주지 않으면 `com.example.<이름 소문자>`가
돼요. 만들어진 패키지는 바로 빌드되고, 접힌 노치 양옆에 표시 하나와 펼친 화면에 탭 하나를 보여줘요.

```
Clock/
├── Package.swift                  # 동적 라이브러리 Clock, NotchKit만 의존해요
└── Sources/Clock/ClockPlugin.swift
```

패키지 폴더 이름, 라이브러리 제품 이름, 번들 이름은 모두 같아야 해요. 저장소 안에 만들면 NotchKit 경로가
상대 경로로 들어가고, 저장소 밖에 만들면 절대 경로로 들어가요.

## 2. 빌드하기

```sh
scripts/build-plugin.sh Plugins/Clock                 # Plugins/Clock/build/Clock.notchplugin
scripts/build-plugin.sh Plugins/Clock --out ~/out     # ~/out/Clock.notchplugin
```

스크립트는 패키지를 release로 빌드하고 동적 라이브러리를 아래 모양으로 묶은 뒤 번들 경로를 출력해요.

```
Clock.notchplugin/Contents/
├── Info.plist        # PluginManifest에서 만들어요
├── MacOS/Clock       # 플러그인 실행 파일(dylib)
└── Resources/        # SwiftPM 리소스 번들(<패키지>_<타깃>.bundle)
```

`Package.swift`에서 타깃의 `resources:`에 적은 파일은 SwiftPM이 dylib 옆에 `<패키지>_<타깃>.bundle`로
묶어 두고, 스크립트가 이 번들을 모두 `Contents/Resources`로 복사해요. 플러그인 코드에서는 이 번들을
`Bundle.module` 대신 `context.resourceBundle(named:)`로 열어요. `Bundle.module`은 앱 옆과 빌드 폴더에서만
번들을 찾아서, 빌드 폴더가 남아 있는 컴퓨터에서만 동작하고 다른 컴퓨터에서는 앱을 멈춰요. `Clock` 패키지의
`Clock` 타깃이라면 `context.resourceBundle(named: "Clock_Clock")`이고, 그런 이름의 번들이 없으면 `nil`이
돌아와요.

`Info.plist`에는 아래 키가 들어가요. 값은 코드에 적은 `PluginManifest`에서 읽어 오니 손으로 고칠 필요가 없어요.

| 키 | 값 |
|---|---|
| `CFBundleIdentifier` | `PluginManifest.id` |
| `CFBundleExecutable` | 패키지 이름 |
| `NotchKitSDKVersion` | 플러그인을 빌드한 SDK 버전(예: `1.0`) |
| `NotchPluginEntry` | 진입 함수 이름, `notchkit_plugin_entry` |

NotchKit은 앱 안에 한 벌만 있어요. 플러그인 실행 파일은 NotchKit을 `@rpath/libNotchKit.dylib`로만
참조하고, rpath `@loader_path/../../../../Frameworks`로 앱의 `Contents/Frameworks`에 있는 사본을 찾아요.
번들 안에는 NotchKit을 넣지 않아요. 두 벌이 들어가면 같은 타입이 서로 다른 타입으로 취급돼서 앱이
플러그인을 알아보지 못해요. 이 규칙을 어기는 빌드 결과는 스크립트가 거부해요.

로컬 서명 인증서(`scripts/signing-identity.sh`가 만들어요)가 있으면 그 인증서로 서명하고, 없으면 임시
서명을 해요. 앱에 넣을 때는 `scripts/build-app.sh`가 앱 인증서로 다시 서명해요.

## 3. 검사하기: notchkit-probe

`notchkit-probe`는 앱과 같은 방식으로 번들을 불러와요. `Info.plist`를 읽고, SDK 버전을 확인하고,
실행 파일을 연 다음 진입 함수로 플러그인 인스턴스를 만들어 봐요. 설치하기 전에 먼저 돌려 보세요.

```sh
swift build -c release --package-path SDK/NotchKit/Probe
PROBE="$(swift build -c release --package-path SDK/NotchKit/Probe --show-bin-path)/notchkit-probe"
"$PROBE" Plugins/Clock/build/Clock.notchplugin
```

성공하면 manifest와 탭 정보를 출력하고 종료 코드 0으로 끝나요. 실패하면 이유를 한 줄로 출력하고 1로
끝나요. 앱의 설정 화면에도 같은 문장이 표시돼요.

| 출력되는 이유 | 고칠 곳 |
|---|---|
| `NotchKit SDK 주 버전이 달라서 불러오지 않아요.` | 앱과 같은 주 버전의 SDK로 다시 빌드해요. |
| `앱의 NotchKit SDK가 플러그인보다 오래돼서 불러오지 않아요.` | 앱을 업데이트하거나 낮은 부 버전으로 빌드해요. |
| `진입 함수를 찾지 못했어요` | 아래 진입 함수가 있는지 확인해요. |
| `진입 함수가 돌려준 값이 이 앱의 NotchKit 타입이 아니에요.` | 번들이나 실행 파일에 NotchKit이 따로 들어갔어요. `build-plugin.sh`로 다시 빌드해요. |
| `Info.plist의 식별자(...)와 PluginManifest의 id(...)가 달라요.` | `Info.plist`를 손으로 고쳤다면 다시 빌드해요. |
| `실행 파일이 번들 밖을 가리켜요.` | 실행 파일 경로에 번들 밖을 가리키는 심볼릭 링크가 있어요. 링크를 지우고 `build-plugin.sh`로 다시 빌드해요. |

## 4. 설치하기

직접 만든 플러그인은 사용자 폴더에 넣어요.

```sh
mkdir -p ~/Library/Application\ Support/NotchTheRock/Plugins
cp -R Plugins/Clock/build/Clock.notchplugin ~/Library/Application\ Support/NotchTheRock/Plugins/
```

앱은 `NotchTheRock.app/Contents/PlugIns`의 내장 플러그인과 이 폴더의 플러그인을 같은 로더로 불러와요.
이 폴더에 들어온 코드는 앱 권한으로 실행되니, 처음 불러올 때 앱이 동의를 묻고 동의한 번들의 해시를
기억해요. 번들 내용이 바뀌면 다시 물어요. 설정 화면에서 다시 불러오기를 누르면 새 번들이 나타나고,
플러그인마다 켜고 끌 수 있어요. SDK 버전이 맞지 않는 번들은 불러오지 않고 설정 화면에 이유를 보여줘요.

## 5. 내장 플러그인 규칙

내장 기능은 `Plugins/<이름>/`에 각자의 SwiftPM 패키지로 있어요. `scripts/build-app.sh`가 이 폴더의 모든
패키지를 `build-plugin.sh`로 빌드해서 `Contents/PlugIns`에 넣어요. 앱 코드는 플러그인 모듈을 컴파일
시점에 참조하지 않아요.

플러그인은 NotchKit과 자기 패키지 안의 타깃만 의존할 수 있어요. 앱 모듈 `NotchTheRock`이나 다른
플러그인을 의존하거나 `import`하면 아래 검사가 실패하고 문제가 된 플러그인 이름을 출력해요.

```sh
scripts/check-plugin-deps.sh              # Plugins/ 전체를 검사해요
scripts/check-plugin-deps.sh <폴더>        # 다른 폴더를 검사해요
```

## 6. API

NotchKit 타입은 `import NotchKit`으로 가져오고, 화면을 그리는 `Text`나 `Image` 같은 SwiftUI 타입은
`import SwiftUI`로 가져와요. 템플릿에는 두 줄이 모두 들어 있어요.

### 플러그인 클래스

```swift
@MainActor
public final class ClockPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.me.clock",           // 역도메인 형식, Info.plist 식별자와 같아요
        name: "Clock",
        version: "1.0.0",
        symbol: "clock",              // SF Symbol 이름
        sdkVersion: NotchKitSDK.version
    )

    private let context: NotchContext
    public init(context: NotchContext) { self.context = context }

    public func activate() { /* 표시를 올리고 작업을 시작해요 */ }
    public func deactivate() { /* 올린 표시를 지우고 작업을 멈춰요 */ }

    public var expandedTab: PluginTab? {           // 선택: 펼친 화면의 탭
        PluginTab(title: "Clock", symbol: "clock") { Text("12:00") }
    }
    public var settingsView: AnyView? { nil }       // 선택: 설정 화면의 페이지
}
```

앱은 플러그인을 켤 때 `activate()`, 끄거나 종료할 때 `deactivate()`를 불러요. 끈 플러그인을 다시 켜면
`activate()`가 또 불려요. 한 번 불러온 코드는 메모리에서 내리지 않으니, 오래 걸리는 작업은 `activate()`에서
시작하고 `deactivate()`에서 반드시 멈춰요.

### NotchContext

앱이 플러그인마다 하나씩 만들어서 `init(context:)`로 넘겨줘요. 플러그인은 앱 타입을 보지 못하고 이
객체로만 노치를 다뤄요. 모든 호출은 메인 액터에서 해요.

| 기능 | API |
|---|---|
| 접힌 노치 양옆 표시 | `post(LiveActivity(id:priority:expiresAfter:leading:trailing:))`, `clear(activityID:)` |
| 노치에서 나오는 짧은 알림 | `showHUD(HUD(symbol:title:value:detail:), duration:)` (기본 2초) |
| 노치 전체를 잠시 차지하기 | `present(Takeover(duration:content:))` |
| 사용자에게 묻기 | `await requestAttention(AttentionRequest(...)) -> AttentionResponse` |
| 펼치기와 접기 | `expand()` (이 플러그인의 탭을 연 채로 펼쳐요), `collapse()` |
| 저장소 | `storage.directory`, `storage.defaults`, `storage.keychainData(for:)`, `setKeychainData(_:for:)`, `deleteKeychainData(for:)` |
| 번들과 리소스 | `bundleURL` (설치된 `.notchplugin` 번들), `resourceBundle(named:)` (없으면 `nil`) |
| 권한 | `permissions.isAccessibilityTrusted`, `permissions.requestAccessibility()` |
| 기록 | `log.debug(_:)`, `log.info(_:)`, `log.error(_:)` |

같은 `id`로 `post`하면 이전 표시를 바꿔요. `expiresAfter`를 주면 그 시간이 지나 저절로 사라지고, 주지
않으면 `clear(activityID:)`를 부를 때까지 남아요. `storage`의 폴더, 기본값 저장소, 키체인 항목은
플러그인마다 따로 있어서 다른 플러그인과 섞이지 않아요.

### 표시 우선순위

노치에는 한 번에 한 가지만 보여요. 앱이 아래 순서로 정하고, 플러그인은 이 순서를 바꿀 수 없어요.

| 순위 | 층 (`NotchLayer`) | 보이는 동안 |
|---|---|---|
| 1 | `takeover` | 다른 표시를 모두 가려요. |
| 2 | `attention` | HUD와 양옆 표시를 가려요. |
| 3 | `hud` | 정해진 시간 동안 양옆 표시를 가려요. |
| 4 | `liveActivity` | `priority`가 큰 것이 이기고, 같으면 나중에 올린 것이 보여요. |

내장 플러그인은 늘 보여 주는 정보에 `priority` 0, 사용자가 지금 하고 있는 일(음악 재생 등)에 100을 써요.

### 사용자에게 묻기

```swift
let response = await context.requestAttention(AttentionRequest(
    title: "배포할까요?",
    message: "main 브랜치에 올라가요.",
    accent: .orange,
    buttons: [AttentionButton(id: "ok", title: "배포"), AttentionButton(id: "no", title: "취소", role: .cancel)],
    choices: [AttentionChoices(id: "env", prompt: "환경", options: ["staging", "prod"])],
    textField: AttentionTextField(placeholder: "메모"),
    timeout: .seconds(60)
))
switch response {
case .answered(let answer): print(answer.buttonID, answer.choices["env"], answer.text)
case .released: break      // 요청을 보낸 원래 화면에서 답하기로 했어요 (releaseTitle)
case .dismissed, .timedOut, .cancelled: break
@unknown default: break    // 나중 부 버전에서 늘어날 경우를 받아요
}
```

`AttentionChoices`의 `allowsMultiple: true`로 여러 개를 고르게 할 수 있어요. 호출한 작업이 취소되면 앱이
요청을 거두고 `.cancelled`를 돌려줘요. 응답은 언제나 한 번만 와요. NotchKit의 열거형은 부 버전에서
경우가 늘어날 수 있어서, `switch`에 `@unknown default`를 넣어야 컴파일돼요.

## 7. 진입 함수

앱은 번들의 실행 파일을 연 다음 `Info.plist`의 `NotchPluginEntry`에 적힌 C 함수를 찾아 불러요. 플러그인마다
아래 네 줄을 한 번 넣고 `ClockPlugin`만 자기 클래스로 바꿔요. 매크로를 쓰지 않아서 Command Line Tools만
있으면 돼요.

```swift
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(ClockPlugin.self)
}
```

## 8. SDK 버전

지금 SDK는 `NotchKitSDK.version` = `1.0`이에요. 버전은 `주.부` 형식이고, 앱은 아래 조건을 만족하는
플러그인만 불러와요.

- 주 버전이 앱과 같아요.
- 부 버전이 앱보다 크지 않아요.

부 버전은 API를 추가만 하니 1.0으로 빌드한 플러그인은 1.x 앱에서 계속 돌아가요. 주 버전이 바뀌면 기존
플러그인을 다시 빌드해야 해요. NotchKit은 라이브러리 진화 모드(`-enable-library-evolution`)로 빌드해서
부 버전이 올라가도 이미 빌드한 플러그인의 바이너리가 그대로 맞아요. `sdkVersion: NotchKitSDK.version`은
플러그인을 빌드할 때의 값이 바이너리에 들어가서, 나중에 어느 앱이 불러오든 빌드한 버전을 알려줘요.

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
돼요. 만들어진 패키지는 바로 빌드돼요. 접힌 노치 양옆에 표시 하나를 올리고, 홈에 작은 타일 하나를 두고,
그 타일을 누르면 열리는 플러그인 화면 하나를 보여줘요.

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
├── Resources/        # SwiftPM 리소스 번들(<패키지>_<타깃>.bundle)
└── Helpers/          # 도우미 실행 파일과 라이브러리, 도우미가 있을 때만 생겨요
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
| `NotchKitSDKVersion` | 플러그인을 빌드한 SDK 버전(예: `1.1`) |
| `NotchPluginEntry` | 진입 함수 이름, `notchkit_plugin_entry` |

NotchKit은 앱 안에 한 벌만 있어요. 플러그인 실행 파일은 NotchKit을 `@rpath/libNotchKit.dylib`로만
참조하고, rpath `@loader_path/../../../../Frameworks`로 앱의 `Contents/Frameworks`에 있는 사본을 찾아요.
번들 안에는 NotchKit을 넣지 않아요. 두 벌이 들어가면 같은 타입이 서로 다른 타입으로 취급돼서 앱이
플러그인을 알아보지 못해요. 이 규칙을 어기는 빌드 결과는 스크립트가 거부해요.

로컬 서명 인증서(`scripts/signing-identity.sh`가 만들어요)가 있으면 그 인증서로 서명하고, 없으면 임시
서명을 해요. 앱에 넣을 때는 `scripts/build-app.sh`가 앱 인증서로 다시 서명해요.

### 도우미 실행 파일과 라이브러리

플러그인 코드는 앱 프로세스 안에서 돌아요. 앱 밖에서 따로 실행할 프로그램이 필요하면 도우미(helper)로
만들어요. 예를 들어 Claude Code 훅이 실행하는 명령이나 `/usr/bin/perl`이 불러오는 작은 라이브러리가
도우미예요. `Package.swift`에 제품을 하나 더 적으면 돼요.

```swift
products: [
    .library(name: "Clock", type: .dynamic, targets: ["Clock"]),               // 플러그인 자신
    .executable(name: "clock-hook", targets: ["ClockHook"]),                   // 실행 파일 도우미
    .library(name: "ClockBridge", type: .dynamic, targets: ["ClockBridge"]),   // 라이브러리 도우미
],
targets: [
    .target(name: "Clock", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
    .executableTarget(name: "ClockHook"),
    .target(name: "ClockBridge"),
]
```

`build-plugin.sh`는 플러그인 자신의 라이브러리 말고도 실행 파일 제품과 동적 라이브러리 제품을 모두 빌드해서
`Contents/Helpers`에 넣어요. 파일은 SwiftPM이 빌드한 그대로 복사하고, 라이브러리 파일 이름도 SwiftPM이
붙인 `lib<제품 이름>.dylib`를 그대로 써요. 정적 라이브러리(`type: .static`)와 종류를 정하지 않은
라이브러리는 도우미가 아니라서 넣지 않아요. 도우미 제품이 없으면 `Contents/Helpers` 폴더도 생기지 않아요.

| 제품 | 번들 안 위치 |
|---|---|
| `.executable(name: "clock-hook", ...)` | `Contents/Helpers/clock-hook` |
| `.library(name: "ClockBridge", type: .dynamic, ...)` | `Contents/Helpers/libClockBridge.dylib` |

플러그인 코드에서는 설치된 번들 위치에서 도우미를 찾아요. 번들은 내장 플러그인이면 앱 안에, 직접 넣은
플러그인이면 사용자 폴더에 있으니 경로를 코드에 적어 두지 않아요.

```swift
let hook = context.bundleURL.appendingPathComponent("Contents/Helpers/clock-hook")
let bridge = context.bundleURL.appendingPathComponent("Contents/Helpers/libClockBridge.dylib")
```

도우미는 앱과 다른 프로세스에서 실행돼서 앱에 한 벌만 있는 NotchKit을 찾지 못해요. 그래서 도우미 타깃은
시스템 프레임워크와 같은 패키지의 다른 타깃만 의존할 수 있어요. 앱 모듈 `NotchTheRock`이나 다른 플러그인도
의존하면 안 되고, NotchKit을 링크한 도우미는 스크립트가 거부해요. 플러그인과 도우미가 같은 코드를 써야
한다면 NotchKit을 쓰지 않는 타깃(예: `ClockCore`)으로 떼어 내고 양쪽에서 그 타깃을 의존해요.

도우미는 번들과 같은 인증서로 먼저 서명하고, 그다음 번들 서명이 도우미의 서명까지 함께 묶어요.
`scripts/build-app.sh`는 플러그인을 빌드하기 전에 앱 인증서를 준비하니, 앱에 들어가는 도우미는 앱과 같은
인증서로 서명돼요. 앱에 넣으면서 번들을 다시 서명해도 도우미 서명은 그대로 남아요. 도우미에는 강화된
런타임(hardened runtime)을 켜지 않아요. 공증하지 않는 로컬 인증서에는 팀 ID가 없어서, 강화된 런타임을 켠
실행 파일은 시스템 라이브러리가 아닌 라이브러리를 불러오지 못해요. 라이브러리 도우미는 자기 서명 옵션과
상관없이 불러오는 프로세스의 규칙을 따라요.

## 3. 검사하기: notchkit-probe

`notchkit-probe`는 앱과 같은 방식으로 번들을 불러와요. `Info.plist`를 읽고, SDK 버전을 확인하고,
실행 파일을 연 다음 진입 함수로 플러그인 인스턴스를 만들어 봐요. 설치하기 전에 먼저 돌려 보세요.

```sh
swift build -c release --package-path SDK/NotchKit/Probe
PROBE="$(swift build -c release --package-path SDK/NotchKit/Probe --show-bin-path)/notchkit-probe"
"$PROBE" Plugins/Clock/build/Clock.notchplugin
```

성공하면 manifest, 플러그인 화면(`expandedTab`), 타일이 지원하는 크기(`tile: small (2x2)`, 타일이
없으면 `tile: none`)를 출력하고 종료 코드 0으로 끝나요. 실패하면 이유를 한 줄로 출력하고 1로 끝나요.
앱의 설정 화면에도 같은 문장이 표시돼요.

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

    public var expandedTab: PluginTab? {           // 선택: 펼친 노치의 플러그인 화면
        PluginTab(title: "Clock", symbol: "clock") { Text("12:00") }
    }
    public var tile: PluginTile? {                  // 선택: 홈의 타일 (SDK 1.1)
        PluginTile(supportedSizes: [.small]) { _ in Text("12:00").padding(8) }
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

HUD는 접힌 노치를 아래로 늘이지 않고 양옆으로만 넓혀서 보여 줘요. 왼쪽 날개에 `symbol`을 그리고,
`value`가 있으면 오른쪽 날개에 그 값만큼 채운 얇은 막대를 그려요. `title`과 `detail`은 화면에 그리지
않고 VoiceOver가 읽어 줘요. HUD가 떠 있는 동안 새 HUD를 보내면 막대가 앞의 값에서 새 값으로 부드럽게
움직여요.

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

### 홈과 타일

노치를 펼치면 플러그인 타일이 격자로 놓인 홈이 나와요. 격자는 가로 8칸이고, 한 줄의 높이는 2칸이며,
줄은 최대 2줄까지 놓여요. 타일은 작은 타일 폭(2칸) 단위로만 놓이고, 두 칸 사이에 걸쳐 놓이지 않아요.
격자에 올리지 않은 플러그인은 격자 아래에 둥근 아이콘으로 한 줄로 늘어서고, 많으면 가로로 스크롤돼요.
아이콘에 포인터를 올리면 플러그인 이름이 툴팁으로 나와요. 사용자는 편집 모드에서 타일을 옮기고,
플러그인이 지원하는 크기 안에서 크기를 바꾸고, 타일을 격자에서 빼요. 아이콘을 누르면 그 플러그인이 첫 빈
칸에 타일로 올라가요. 빈 칸이 없으면 아무것도 옮기지 않고 짧은 안내만 보여 줘요.

모든 플러그인은 격자에 올릴 수 있어요. `tile`이 없는 플러그인은 앱이 만든 기본 타일로 올라가요. 기본 타일은
작은 크기 하나뿐이고, 플러그인 아이콘(`manifest.symbol`)과 이름(`manifest.name`)을 보여 줘요.

홈에서 플러그인이 어떻게 보일지는 `tile`과 `expandedTab`을 주는지에 따라 정해져요.

| `tile` | `expandedTab` | 홈에서 보이는 모습 |
|---|---|---|
| 있음 | 있음 | 타일이 보이고, 누르면 플러그인 화면이 열려요. |
| 없음 | 있음 | 격자 아래 아이콘으로 보이고, 누르면 플러그인 화면이 열려요. 기본 타일로 격자에 올리면 타일을 눌러도 화면이 열려요. |
| 있음 | 없음 | 정보만 보여 주는 타일이에요. 눌러도 열리는 화면은 없어요. |
| 없음 | 없음 | 격자 아래 아이콘으로 보이고, 기본 타일로 격자에 올릴 수 있어요. 눌러도 열리는 화면은 없어요. 인사만 띄우는 Hello가 이런 플러그인이에요. |

플러그인 화면에서는 노치 위쪽 띠의 카메라 왼쪽에 ‹와 플러그인 이름이 나오고, 누르면 홈으로 돌아가요.
이름이 길면 카메라에 닿기 전에 끝을 줄여서 보여 줘요. `settingsView`를 주는 플러그인은 카메라 오른쪽에
설정 버튼이 생기고, 이 버튼은 설정 창의 플러그인 탭을 그 플러그인의 페이지로 열어요. 설정 페이지가 없는
플러그인에는 이 버튼이 없어요.

타일 크기는 `TileSize`의 세 가지 중에서 골라요. 크기의 단위는 격자 칸이고, 한 칸이 몇 포인트인지는
앱이 정해요.

| `TileSize` | 가로 x 세로 (`columns` x `rows`) |
|---|---|
| `.small` | 2 x 2 |
| `.wide` | 4 x 2 |
| `.large` | 4 x 4 |

```swift
public var tile: PluginTile? {
    PluginTile(supportedSizes: [.small, .wide]) { size in   // 첫 번째가 기본 크기예요
        ClockTile(showsDate: size == .wide)
    }
}
```

`supportedSizes`에는 사용자가 고를 수 있는 크기만 넣어요. 타일은 첫 번째 크기로 처음 놓이고, 이 크기는
`defaultSize`로 읽을 수 있어요. 빈 배열을 넘기면 `PluginTile`을 만들지 않고 `nil`을 돌려줘서 타일이 없는
플러그인이 돼요. 플러그인 코드는 앱 안에서 돌기 때문에, 이런 실수로 앱 전체가 멈추지 않게 하려는 거예요.
앱은 타일을 그릴 때 메인 액터에서 지금 크기를 넘겨 `content`를 불러요. `TileSize`도 NotchKit
열거형이라 `switch`로 나눌 때는 `@unknown default`가 있어야 해요.

### 화면 크기

펼친 노치에는 정해진 크기가 없어요. 앱은 지금 보여 주는 화면(홈, 플러그인 화면, 알림, 인사)의 크기를
재고, 그 크기에 맞춰 노치를 키워요. 가장자리 여백은 어느 화면에서나 같아요. 그래서 `expandedTab`과
`tile`의 뷰는 내용으로 정해지는 크기를 스스로 가져야 해요.

- 글자, 이미지, `padding()`, `frame(width:height:)`처럼 크기가 정해지는 뷰로 만들어요.
- 화면 바깥 여백은 앱이 넣어요. 앱은 노치 모양의 왼쪽, 오른쪽, 아래 가장자리와 화면 내용 사이에 어느
  화면에서나 같은 여백(20pt)을 둬요. 그래서 `expandedTab` 뷰의 가장 바깥에는 `padding()`을 붙이지 않고,
  그려지는 내용보다 큰 고정 크기(`frame(width:height:)`)도 주지 않아요. 이런 뷰가 있으면 그 화면만
  여백이 넓어 보여요.
- `.frame(maxHeight: .infinity)`로 남는 높이를 채우지 않아요. 이런 뷰는 앱이 내준 높이만큼 늘어나서,
  노치 크기가 내용과 맞지 않게 돼요. 너비는 아래처럼 넓게 받을 수 있어요.
- `Color`나 `Rectangle`만 있는 뷰는 자기 크기가 없으니 `frame(width:height:)`로 크기를 정해 줘요.

앱은 뷰가 스스로 알려 주는 크기를 재서 써요. 잰 크기가 노치 모양보다 작으면 노치 모양 크기를 쓰고, 홈
격자 8칸 너비보다 넓으면 그 너비까지만 써요. 직접 확인하려면 `NSHostingView(rootView:).fittingSize`를
보면 돼요. 너비와 높이가 0보다 크고 유한해야 해요.

플러그인 화면에서는 위쪽 띠의 카메라 왼쪽에 뒤로 가기와 플러그인 이름이 놓여요. 이름이 길면 이 띠
때문에 노치가 화면보다 넓어지고, 그때 앱은 `expandedTab` 뷰에 노치 양쪽 여백 사이의 너비를 모두
내줘요. 뷰가 그 너비를 채우면 왼쪽, 오른쪽, 아래 여백이 같아져요. 자기 너비만 쓰는 뷰는 카메라 아래
가운데에 놓이고 오른쪽 여백이 넓게 남아요. 그러니 자기 크기는 지금처럼 정해 두고, 더 받은 너비는
`maxWidth: .infinity`와 `Spacer`가 받게 만들어요. 높이는 넓게 받을 때도 자기 높이 그대로예요.

```swift
VStack(alignment: .leading, spacing: 8) {
    HStack(spacing: 0) {
        Image(systemName: "sparkles")
        Spacer(minLength: 12)   // 자기 크기에서는 12pt, 넓게 받으면 양 끝으로 벌어져요
        Text("72%")
    }
    ProgressView(value: 0.72)
        // 고정 너비 대신 써요: 자기 크기는 200pt이고, 넓게 받으면 그만큼 늘어나요
        .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity)
}
```

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

지금 SDK는 `NotchKitSDK.version` = `1.1`이에요. 버전은 `주.부` 형식이고, 앱은 아래 조건을 만족하는
플러그인만 불러와요.

- 주 버전이 앱과 같아요.
- 부 버전이 앱보다 크지 않아요.

부 버전은 API를 추가만 하니 1.0으로 빌드한 플러그인은 1.x 앱에서 계속 돌아가요. 주 버전이 바뀌면 기존
플러그인을 다시 빌드해야 해요. NotchKit은 라이브러리 진화 모드(`-enable-library-evolution`)로 빌드해서
부 버전이 올라가도 이미 빌드한 플러그인의 바이너리가 그대로 맞아요. `sdkVersion: NotchKitSDK.version`은
플러그인을 빌드할 때의 값이 바이너리에 들어가서, 나중에 어느 앱이 불러오든 빌드한 버전을 알려줘요.

| 버전 | 달라진 점 |
|---|---|
| `1.0` | 처음 공개한 API예요. |
| `1.1` | 홈 타일을 위한 `TileSize`, `PluginTile`, `NotchPlugin.tile`이 추가됐어요. |

1.0으로 빌드한 플러그인에는 `tile` 구현이 없어서, 1.1 앱은 기본 구현이 돌려주는 `nil`을 읽어요. 이런
플러그인은 "홈과 타일"의 규칙대로 격자 아래 아이콘으로 보이고, 앱의 기본 타일로 격자에 올릴 수 있어요. 1.0 SDK로 빌드한 템플릿을
1.1 로더로 불러오는 검사는 아래 스크립트가 해요. 스크립트는 1.0 코드를 임시 git 작업 트리로 꺼내
빌드하고, 끝나면 지워요.

```sh
SDK/NotchKit/Tests/sdk-compat-test.sh
```

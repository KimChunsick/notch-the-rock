# NotchTheRock Raycast 확장

Raycast에서 NotchTheRock 노치를 펼치거나 플러그인 화면을 바로 여는 확장이에요. 명령마다
Raycast 단축키를 지정하면 플러그인별 단축키처럼 쓸 수 있어요.

## 명령

| 명령 | 여는 주소 |
|---|---|
| 노치 열기 | `notchtherock://open` |
| 복사 기록 열기 | `notchtherock://open/com.notchtherock.clipboard` |
| 시스템 상태 열기 | `notchtherock://open/com.notchtherock.systemstats` |
| 배터리 열기 | `notchtherock://open/com.notchtherock.battery` |
| 음악 열기 | `notchtherock://open/com.notchtherock.nowplaying` |
| 에이전트 열기 | `notchtherock://open/com.notchtherock.agents` |
| 미디어 키 열기 | `notchtherock://open/com.notchtherock.mediakeys` |
| 플러그인 열기 | `notchtherock://open/<입력한 식별자>` |

직접 만든 플러그인은 `플러그인 열기`에 식별자(예: `com.example.clock`)를 적어서 열어요. 꺼져
있거나 화면이 없는 플러그인을 고르면 노치는 홈을 보여 줘요.

명령을 실행하면 노치가 열리고 Raycast 창은 닫혀요. NotchTheRock이 설치되어 있지 않으면 Raycast에
실패 알림이 떠요.

## Raycast에 불러오기

Node.js 22 이상과 npm이 필요해요. 이 폴더에서 아래 명령을 실행하면 Raycast가 개발용 확장으로
불러와요.

```sh
cd Integrations/Raycast
npm install && npm run dev
```

`npm run dev`를 멈춰도 확장은 Raycast에 남아 있어요. 코드를 고쳤을 때만 다시 실행하면 돼요.

## 명령마다 단축키 지정하기

1. Raycast 설정(`⌘ ,`)을 열고 Extensions 탭으로 가요.
2. 목록에서 NotchTheRock을 펼치고 원하는 명령을 골라요.
3. Hotkey 칸의 Record Hotkey를 누르고 쓰고 싶은 키 조합을 눌러요.

예를 들어 `복사 기록 열기`에 `⌃⌥V`를 지정하면 어디서든 그 키로 복사 기록 화면이 열려요.

## 빌드와 검사

```sh
npm run build   # dist/에 빌드해요
npm run lint    # Raycast의 검사 도구를 실행해요
```

# 쪽뷰 (Jjokview)

macOS용 만화·웹툰 뷰어입니다. 압축 파일이나 폴더를 풀지 않고 바로 엽니다.
A comic and webtoon viewer for macOS. Opens archives and folders directly, without extracting.

- Apple Silicon(M1 이상), macOS 14 이상 / Apple silicon (M1 or later), macOS 14 or later
- 한국어·영어 / Korean and English
- MIT 라이선스 / MIT License

[English](#english)

## 기능

**열기**
- ZIP·CBZ·RAR·CBR·7Z·CB7과 이미지 폴더. 압축 안에 권별 압축이 들어 있는 모음 파일도 그대로 엽니다.
- 목록만 먼저 읽어서 첫 쪽이 바로 뜹니다. 손상된 zip은 읽을 수 있는 데까지 엽니다.
- 암호가 걸린 압축과 여러 개로 나뉜 RAR(part1, part2…)은 아직 열지 못합니다.
- 한글 파일명: CP949(확장 완성형 포함)·Shift_JIS·GBK·Big5·UTF-8을 자동으로 판별합니다.
  틀리게 보이면 보기 → 파일명 인코딩에서 직접 고릅니다.

**보기**
- 한쪽 / 두쪽 / 세로 스크롤(웹툰)
- 오른쪽→왼쪽(만화), 왼쪽→오른쪽
- 한쪽 보기에서는 두 쪽이 붙은 스캔을 읽는 순서대로 나눠 보여줍니다(S로 켜고 끔).
- 표지 단독 보기, 화면·폭·높이 맞춤, 확대
- 시리즈마다 보기 설정을 기억하고, 권 끝에서 다음 권으로 이어집니다.
- 마우스: 화면 왼쪽·오른쪽을 클릭해 넘깁니다(오른쪽→왼쪽 책은 왼쪽이 다음, 세로 보기는 아래쪽이 다음).
  꿀뷰식(왼쪽 버튼 다음, 오른쪽 버튼 이전)도 설정에서 고를 수 있습니다. 확대한 쪽은 끌어서 옮깁니다.

**선명도(E)**
| 방식 | 설명 |
|---|---|
| 글씨 선명 | 잉크는 진하게, 종이는 하얗게. 흐린 스캔의 말풍선을 읽기 쉽게 합니다. |
| 그림 선명 | 선 옆에 흰 테두리가 생기지 않게 선을 또렷하게 하고, 스크린톤을 지킵니다. |
| AI 업스케일 | 맥에 내장된 AI 초해상도로 저해상도 스캔을 키운 뒤 글씨 선명을 적용합니다(macOS 26 이상). |

방식마다 강도를 설정에서 0~100%로 조절합니다.

**북마크**
- 추가한 순서대로 보이는 목록, 삭제, 전체 삭제
- 파일을 옮기거나 이름을 바꿔도 유지됩니다. 파일 경로가 아니라 파일 내용으로 알아봅니다.
- 마지막으로 읽은 곳부터 이어 봅니다.

**자동 넘기기(P)**
- 쪽 보기: 2·5·10초마다 한 쪽씩
- 세로 보기: 흐르듯이 스크롤
- 스페이스·Esc·P로 멈춥니다.

## 단축키

기본값은 꿀뷰(Honeyview) 방식에 맥 표준 ⌘ 조합을 더한 것입니다.
한글 입력 상태에서도 동작하며, 설정 → 단축키에서 바꿀 수 있습니다.

| 동작 | 키 |
|---|---|
| 다음 / 이전 쪽 | 스페이스, →, ↓, Page Down / ⇧스페이스, ←, ↑, Page Up |
| 처음 / 마지막 쪽 | ⌘↑, Home / ⌘↓, End |
| 다음 / 이전 권 | `]`, `⌘]` / `[`, `⌘[` |
| 쪽 이동 | G, ⌘L |
| 한쪽 / 두쪽 / 세로 | ⌘1 / ⌘2 / ⌘3 |
| 두 쪽 스캔 나누기 | S |
| 읽기 방향 바꾸기 | 2, ⌘⌥R |
| 화면 맞춤 / 폭 맞춤 / 원본 크기 | 9 / 8 / 0 |
| 북마크 추가·삭제 / 목록 | B, ⌘D / F3, ⌘⌥B |
| 자동 넘기기 / 느리게 / 빠르게 | P / `,` / `.` |
| 선명도 바꾸기 | E |
| 전체 화면 | F, Return, ⌃⌘F |

전체 목록은 도움말 → 키보드 단축키(⌘/)에서 볼 수 있습니다.

## 설치

[Releases](../../releases)에서 DMG를 받아 응용 프로그램 폴더로 옮깁니다.

## 개인정보

- 네트워크는 새 버전 확인에만 씁니다. 하루 한 번 GitHub 릴리스 페이지에 요청을 하나 보내 최신 버전 번호만 읽습니다.
  이때 전달되는 것은 IP 주소와 앱 이름·버전(`Jjokview/0.1.0`)뿐입니다. 설정에서 끌 수 있습니다.
- AI 업스케일을 처음 켜면 macOS가 시스템 AI 모델을 내려받습니다.
- 샌드박스 앱이라, 사용자가 연 파일과 폴더만 읽기 전용으로 접근합니다.
- 북마크와 읽은 위치는 이 맥 안에만 저장됩니다.

## 빌드

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Jjokview.xcodeproj -scheme Jjokview -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
open build/Build/Products/Release/Jjokview.app
```

- 테스트: `xcodebuild -project Jjokview.xcodeproj -scheme Jjokview -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test`
- `project.yml`이 프로젝트 원본입니다. 파일을 더하거나 빼면 `xcodegen generate`를 다시 실행하세요.
- 배포용 DMG(Developer ID 서명·공증)는 `scripts/release.sh`로 만듭니다.

## 라이선스

MIT. 앱 아이콘도 이 프로젝트에서 직접 만든 것으로 같은 라이선스를 따릅니다. 포함하거나 연결한 구성 요소는 다음과 같습니다.
- [libarchive](https://www.libarchive.org) (BSD 2-Clause): RAR·7Z 읽기, macOS 시스템 라이브러리
- zlib: macOS 시스템 라이브러리

자세한 고지는 앱의 설정 → 오픈소스 고지에 있습니다.

---

## English

**Open**
- ZIP, CBZ, RAR, CBR, 7Z, CB7, and image folders, including archives that contain one archive per volume.
- Only the index is read up front, so the first page appears right away. Damaged ZIPs open as far as they can be read.
- Password-protected archives and multi-part RAR files are not supported yet.
- Filename encoding is detected automatically: CP949 (Korean), Shift_JIS, GBK, Big5, and UTF-8.
  If names look wrong, pick the encoding under View → Filename Encoding.

**View**
- Single page, two pages, and vertical scroll (webtoon).
- Right-to-left (manga) or left-to-right.
- In single-page view, two-page scans are split in reading order. Toggle with S.
- Cover shown alone, fit to window, width, or height, and zoom.
- Settings are remembered per series, and reading continues into the next volume.
- Mouse: click the left or right side to turn pages. In right-to-left books the left side is next, and in vertical view the lower half is next.
  Honeyview-style clicks (left button next, right button previous) are available in Settings. Drag to move a zoomed page.

**Sharpen (E)**
| Mode | What it does |
|---|---|
| Sharp Text | Darkens ink and whitens paper so blurry speech bubbles are easier to read. |
| Sharp Art | Crisps line art without white halos and keeps screentones intact. |
| AI Upscale | Enlarges low-resolution scans with Apple's on-device super resolution, then applies Sharp Text (macOS 26+). |

Each mode has its own strength setting, from 0 to 100%, in Settings.

**Bookmarks**
- Listed in the order you add them. Delete one or clear all.
- Bookmarks survive moving or renaming files, because books are identified by their content, not their path.
- Resume where you left off.

**Auto advance (P)**
- Page views turn every 2, 5, or 10 seconds.
- Vertical view scrolls continuously.
- Stop with Space, Esc, or P.

**Keyboard**
- Defaults follow Honeyview plus standard Mac ⌘ shortcuts, and work with any input source.
- Change them in Settings → Shortcuts. See Help → Keyboard Shortcuts (⌘/) for the full list.

**Privacy**
- The only network use is an update check. Once a day, the app sends a single request to the GitHub releases page and reads the latest version number.
  GitHub sees only your IP address and the app name and version (`Jjokview/0.1.0`). You can turn this off in Settings.
- macOS downloads its system AI model the first time you use AI Upscale.
- It is sandboxed and reads only the files and folders you open.
- Bookmarks and reading positions stay on your Mac.

**Build:** see [빌드](#빌드) above.
The commands are the same. `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` builds with ad-hoc signing, with no Apple developer account needed.

**License:** MIT, including the app icon, which was made for this project. Uses libarchive (BSD 2-Clause) and zlib, both macOS system libraries.

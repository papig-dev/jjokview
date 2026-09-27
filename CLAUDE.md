# 쪽뷰 / Jjokview (macOS 만화·웹툰 뷰어)

번들 ID `dev.papig.jjokview`. 표시명은 ko "쪽뷰", en "Jjokview"(`Resources/*.lproj/InfoPlist.strings`).

기획·실측 근거는 `ANALYSIS.md`(로컬 전용, 공개 저장소에는 없음: 개인 샘플 파일명 포함). 벤치마크는 꿀뷰(Honeyview).

## 빌드
- **XcodeGen**: `project.yml`이 소스. 파일을 추가/삭제하면 `xcodegen generate` 필수(안 하면 "cannot find in scope").
- 빌드: `xcodebuild -project Jjokview.xcodeproj -scheme Jjokview -derivedDataPath build/dd build`
- 테스트: 같은 명령에 `test`. 테스트 호스트가 샌드박스라 `~/Downloads` 같은 실제 파일은 못 읽는다.
  실제 파일 검증은 Archive/·Book/ 소스를 swiftc로 묶은 명령줄 하니스로 한다(`-I Jjokview/CLibArchive`).
- arm64 전용(M1+), macOS 14+. 샌드박스(읽기 전용 + app-scope 북마크).

## 구조
- `Archive/` ZIP 자체 파서(central directory, zip64, 0x7075, 손상 시 로컬 헤더 스캔), libarchive(RAR/7z, 순차 해제 캐시), 파일명 인코딩 판정
- `Book/` 시리즈(권 목록)·권 로딩. 책 ID = 내용 지문, 쪽 ID = 원본 파일명 바이트 해시
- `Reader/` SpreadLayout(쪽 배치는 여기서만), SpreadScrollView(한쪽/두쪽), StripScrollView(세로), ReaderController(상태)
- `Library/` library.json(북마크·위치·시리즈 설정, 자동 삭제 없음), AccessBroker(보안 범위 북마크)
- `Keys/` 단축키는 물리 키코드로 저장(한글 입력 상태에서도 동작). 기본값 = 꿀뷰 + 맥 ⌘ 조합

## 규칙
- 파일명 디코딩은 EUC-KR이 아니라 CP949(`kCFStringEncodingDOSKorean`). 결과는 NFC.
- 인코딩 판정은 "첫 성공"이 아니라 점수 비교(SJIS가 CP949로 오류 없이 풀린다).
- 북마크·위치 기록은 절대 자동 삭제하지 않는다. library.json을 못 읽으면 백업하고 덮어쓰지 않는다.
- 권 사이 이동 시 세로 위치 등 이전 권 상태가 새 권으로 새지 않게 할 것(실제로 한 번 샜음).
- 한쪽 보기 = 두 쪽 스캔(가로 이미지)을 항상 반씩 나눔. 앱 전체 설정 `AppPreferences.splitSpreads`(기본 켬, 시리즈별 아님),
  S 키·보기 메뉴·설정 창이 같은 값을 바꾼다. 툴바 버튼은 두지 않음(한쪽 보기 버튼과 겹쳐 보임). 두쪽 보기는 그 이미지를 그대로 펼침면으로.
- 선명도: 끄기 / 글씨 선명 / 그림 선명 / AI 업스케일(macOS 26+). 강도는 방식별 0~1(`SharpenPreferences`, 앱 전체, 설정 창 슬라이더,
  툴바 선명도 메뉴의 "강도 조절…"). 캐시 키에 강도(%)가 들어간다. 세 방식 모두 **화면 크기까지 직접 키운 뒤** 처리한다
  (원본 해상도에서 걸고 레이어가 키우면 효과가 거의 사라진다).
  - 글씨 선명: Mitchell 확대 + 약한 블러 + sRGB 레벨(`sharpText`, 기본 0.5 = 흑점 0.20·백점 0.93·블러 0.61px).
    CIToneCurve 곡선은 회색 바탕 흰 글씨를 뭉개고(OCR 0.60→0.45), 언샤프·획 굵게·잡음 제거·확대 전 적용은 모두 손해였다.
  - 그림 선명: 원본에서 양방향 평활(CIKL 커널, deprecated 경고는 알고 둠 — Metal 커널은 Metal Toolchain 필요) → Lanczos 확대 →
    오버슛 제한 언샤프(흰 헤일로 없음). 기본 0.5. 글씨 선명 곡선을 그림에 쓰면 얼굴·종이가 날아가고 스크린톤이 부서진다.
  - AI: 화면 배율 1.5배 이상이고 입력 가로·세로 1920 이하일 때만 VTSuperResolutionScaler 4배 → Mitchell 축소 → 글씨 선명.
    아니면 글씨 선명. 세션 하나가 1.5GB+를 잡아 2개까지만 두고 AI를 끄면 `releaseSessions()`.
  - 예전 저장값 light/strong은 글씨 선명으로 읽는다. 툴바 선명도는 현재 단계가 글자로 보이는 선택 버튼(켜지면 강조색).
- 자동 넘기기(P·⌘⌥P 켜기/끄기, 넘기는 중엔 스페이스·Esc도 멈춤 / , 느리게 / . 빠르게): 쪽 보기는 간격 타이머(`AutoPlayPreferences.interval`, 기본 5초),
  세로는 디스플레이 링크로 흐르는 스크롤(`speed`, 기본 70pt/s, 휠 조작 시 1.5초 멈춤). 권 끝에서 다음 권으로 이어감(옵션).
  툴바 버튼은 시계 아이콘에 숫자 배지(2/5/10), 세로는 거북이·속도계·토끼 아이콘. 누르면 값 선택 메뉴.
  툴바는 `.space`로 [확대·선명도] / [자동 넘기기] / [북마크]를 서로 다른 캡슐로 나눈다.
- `@Published`는 값이 바뀌기 **직전**에 알린다. sink에서 새 값을 읽어야 하면 다음 차례(`DispatchQueue.main.async`)로 미룬다(자동 넘기기 타이머가 안 돌던 원인).
- 새 시리즈 기본값은 설정 창 값. 마지막 사용 설정을 따라가지 않는다(웹툰→만화 세로 전염 버그).
- 손상·악성 zip: 크기 계산은 덧셈 대신 `size - offset` 뺄셈으로 검사, 한 쪽 해제 상한 256MB(`ZipArchive.maxEntryBytes`),
  크기 읽기(`prefix`)는 앞 64KB만 푼다. 잘린 마지막 엔트리는 버리지 않고 남은 데이터까지 푼다.
- 인코딩 판정: 전부 유효한 UTF-8이어도 2바이트 글자(U+0080–07FF)가 있으면 CP949 후보와 점수 비교("1화"→"1ȭ" 사례).
- 저장소(LibraryStore)는 메인 스레드 전용. 백그라운드로는 `store.recent` 복사본을 넘긴다. Codable은 `lenient`로 필드 누락·모르는 값 허용.
- 열기 요청은 `requestID`로 늦게 온 결과를 버린다. 디코딩 콜백은 `controller.book === book`을 확인한다. 캐시 키는 `book.cacheKey`(지문+인코딩).
- RAR/7z 해제 스레드는 reader가 아닌 공유 State만 잡는다(권을 넘기면 `cancel()`로 멈춤). `ArchiveCache.keepOnly`로 이전 파일을 놓는다.
- UI 문자열은 `String(localized:)` + `Resources/Localizable.xcstrings`(en 원문, ko 번역). 새 문자열 추가 시 ko도 채울 것.

- 새 버전 알림(`App/UpdateChecker.swift`): 하루 한 번 GitHub `releases/latest`의 tag(`v0.1.0` 형식)만 읽고 다운로드 페이지를 연다.
  자동 설치 없음(Sparkle은 나중에). App Store판(번들에 `_MASReceipt`)이면 메뉴·설정·확인 모두 꺼진다. 네트워크 권한은 이것 때문.
  릴리스 태그는 반드시 `v<MARKETING_VERSION>`, draft/prerelease는 무시된다.
- 배포: `scripts/release.sh`(Developer ID 서명 → DMG → 공증 → 스테이플). `adhoc` 인자는 이 맥 확인용.

- 경로 비교는 `URL ==` 금지, `comparablePath`(standardized + NFC)로. 연 파일 URL은 경로 전체 NFD, 폴더 목록은 파일명만 NFC라
  한글 시리즈에서 현재 권을 못 찾아 다음 권으로 못 넘어갔다(`VolumeRef ==`, 이어보기 lastPath 비교).
- 보정 결과 렌더: 지연 CGImage를 우리 비트맵에 그려서 만든다(`createImage`). 기본 createCGImage는 큰 결과를 지연 이미지로 줘서
  레이어가 그릴 때마다(메인 스레드) 필터를 다시 돌렸고, `deferred:false`/`render(toBitmap:)`는 장마다 GPU 메모리가 약 330MB씩 쌓였다.
  결과 픽셀 상한 `maxEnhancedPixels`(24MP), 넘으면 레이어가 키운다.
- AI 끄기: `AIUpscaler.releaseSessions()`가 generation을 올려 큐에 남은 AI 요청을 건너뛰게 한다(안 하면 세션을 다시 만들어 1GB 가까이 붙잡음).
  다른 창이 AI를 쓰면 닫지 않는다. 쪽 보기·세로 보기 모두 보정 전 이미지를 먼저 보여주고, 창 크기를 끄는 동안에는 보정 요청을 하지 않는다.

- 마우스(`Reader/ReaderMouse.swift`): 한 번 클릭 = 넘김(`ClickMode` sides 기본: RTL은 왼쪽이 다음, 세로는 아래 절반이 한 화면 아래 /
  buttons: 꿀뷰식 왼쪽 다음·오른쪽 이전 / off), 끌기 = 팬. 두 번 클릭 확대는 없앴다(첫 클릭에 넘어감).
  **NSClipView는 클릭을 스크롤 뷰로 넘기지 않는다** → `CenteringClipView`가 mouseDown/rightMouseDown을 전달(안 하면 쪽 바깥 빈 곳 클릭이 무시됨).
- 이어보기·최근 메뉴는 `displayTitle`(확장자 없음) + `seriesName`(폴더/묶음 압축 이름)으로 같은 이름 권을 구분. 창 부제목 = 시리즈 · n / N.

## 검증 도구 (Debug 빌드 전용)
`open --env JJOKVIEW_SCRIPT="wait:3;do:layoutDouble;snap:a;page:10;quit" -a build/dd/Build/Products/Debug/Jjokview.app <파일>`
- 스냅샷·상태는 `~/Library/Containers/dev.papig.jjokview/Data/tmp/snapshots/`(`state.txt`에 쪽·설정·토스트, `timings.txt`에 보정 시간·업데이트 확인 결과)
- 업데이트 알림 확인: `--env JJOKVIEW_UPDATE_URL=<다른 저장소의 releases/latest>`(Debug 전용)
- 클릭 확인: 스크립트 `click:0.2,0.5` / `rclick:x,y`(읽기 영역 비율, 위에서부터). 이 환경은 System Events 클릭이 창을 못 찾는다.
- 스냅샷은 쪽 레이어만 직접 합성한다(툴바·SwiftUI는 안 나옴, 빈 곳은 자홍색). 창 전체 모습은 화면 녹화 권한이 필요.

## 검증 기록
- 2026-09-27 코드·UX 리뷰(팀원 2명)에서 나온 크래시 4종, CP949 오판정, 다 읽음 고착, 연타로 권 넘김, 데이터 경쟁 등을 수정하고
  `JjokviewTests/CoreTests.swift` 회귀 테스트(22개)와 `Fixtures/`의 손상 zip으로 고정했다.

## 남은 일
- unrar 소스 번들(암호 RAR, 분할 RAR), libarchive 3.8.x 번들(현재 시스템 3.7.4를 헤더 직접 선언으로 링크)
- Sparkle(자동 설치), Metal CI 커널

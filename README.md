# MOA Docs

MOA 프로젝트의 기획부터 설계, 테스트까지 모든 문서를 모은 저장소입니다. 코드는 [moa-web](https://github.com/moa-team/moa-web) · [moa-backend](https://github.com/moa-team/moa-backend)에 있습니다.

## 문서 지도

| 폴더 | 내용 | 대표 문서 |
|---|---|---|
| [01-planning](./01-planning) | 제안서, 시장·경쟁 분석, 페르소나 | 과제 제안서 |
| [02-requirements](./02-requirements) | 기능(FR 26)·비기능(NFR 8) 요구사항, 유스케이스 | 요구사항 명세 |
| [03-design](./03-design) | 와이어프레임, 스토리보드, MMI 정의서, 소프트웨어 설계서, DB 스키마 | [소프트웨어 설계서](./03-design/software-design.md) · [PDF](./03-design/MOA_소프트웨어_설계서.pdf) |
| [04-api](./04-api) | API 명세(OpenAPI), 오류 코드, SSE 이벤트 | `openapi.yaml` |
| [05-adr](./05-adr) | 설계 결정 기록 | [ADR 목록](./05-adr) |
| [06-meetings](./06-meetings) | 주간 회의록 | — |
| [07-retrospectives](./07-retrospectives) | 스프린트 회고 | — |
| [08-usability-test](./08-usability-test) | 사용성 테스트 계획·결과·개선 내역 | — |

## 진행 현황

| 단계 | 기간 | 상태 | 산출물 |
|---|---|---|---|
| 기획 | 2026.09 | ✅ | 제안서, 요구사항 |
| 화면·설계 | 2026.10 | ✅ | 와이어프레임 17화면, 스토리보드, MMI 정의서, 소프트웨어 설계서 |
| 프론트엔드 | 2026.10 ~ 11 | 🟢 | 목 API 기반 전체 화면 |
| 사용성 테스트 | 2026.11 | ⚪ | 결과 보고서 |
| 백엔드·통합 | 2026.11 ~ | ⚪ | — |

## 문서 작성 규칙
- 파일 이름은 `kebab-case.md`, 날짜가 들어가는 문서는 `YYYY-MM-DD-제목.md`로 쓴다.
- 이미지는 각 폴더의 `images/`에 둔다. 피그마 원본 링크를 함께 적는다.
- 설계를 바꾸면 설계서를 고치는 PR과 ADR을 같이 올린다.

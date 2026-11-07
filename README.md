# GA4 웹 트래픽 KPI 분석 — SQL 쿼리 모음

GA4 공개 샘플 데이터(구글 머천다이즈 스토어)로 웹 트래픽 KPI를 정의하고, BigQuery SQL로 산출해 Power BI 대시보드와 개선 제안까지 만든 프로젝트의 핵심 쿼리입니다.

- 전체 분석과 대시보드: [포트폴리오 페이지](https://alder-cyclamen-53e.notion.site/3fe17f3999f5813faf82d62da0936d04)
- 데이터: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` (2020-11-01 ~ 2021-01-31)
- 도구: BigQuery(샌드박스), Power BI Desktop

## 핵심 질문

방문 대비 구매 전환이 1.35%인데, 퍼널의 어느 단계에서, 어떤 채널·기기에서 가장 많이 빠지는가?

## 쿼리 목록

| 파일 | 내용 | 주요 결과 |
| --- | --- | --- |
| [01_sessions_daily.sql](01_sessions_daily.sql) | 세션 수 일별 추이 | 세션 360,129, 자정 넘는 세션 중복 제거 |
| [02_channel_conversion.sql](02_channel_conversion.sql) | 채널(세션 내 첫 medium)별 전환율 | organic 1.61% / (none) 0.81% / cpc 0.61% |
| [03_funnel_cumulative.sql](03_funnel_cumulative.sql) | 구매 퍼널, "해당 단계 이상 도달" 기준 | 전체 기간 값 (정정 전) |
| [04_engaged_recheck.sql](04_engaged_recheck.sql) | 참여율 재검증 | 88.9% → 67.2%로 정정 |
| [05_fact_daily_channel_device.sql](05_fact_daily_channel_device.sql) | Power BI 세션 팩트 (일자 × 채널 × 기기) | 정상 수집 기간 이탈률 70.5 / 54.5 / 34.0 / 27.0% |
| [06_fact_transactions.sql](06_fact_transactions.sql) | Power BI 매출 팩트 (거래 1건 1행) | 매출 $307,640 / 객단가 $69.12 |

각 파일 상단에 목적, 정의, 검증값, 결과를 적었고, 판단이 들어간 줄에는 그렇게 한 이유를 주석으로 남겼습니다.

## 공통 정의

- 분석 단위는 세션이고, 세션 키는 `user_pseudo_id` + `ga_session_id`입니다. `ga_session_id`는 사용자 간에 겹칠 수 있어 단독으로 쓰지 않았습니다.
- 세션 날짜는 세션의 첫 `event_date`로, 자정을 넘긴 세션이 이틀에 중복 집계되지 않게 했습니다.
- 채널은 `traffic_source`(사용자 최초 유입) 대신 이벤트의 `medium` 중 세션 내 첫 값을 썼습니다. 출처가 자기 도메인인 referral은 `referral_self`로 분리했습니다.

## 분석 중 스스로 정정한 2건

1. **참여율 88.9% → 67.2%** (04번): `session_engaged`가 문자 칸과 정수 칸에 섞여 있어 둘을 합쳤는데, 정수 칸만 1인 78,164세션은 GA4 참여 규칙 충족률이 0.1%였습니다. 규칙으로 직접 재계산한 값(66.2~68.9%)이 문자 칸 값(67.2%)과 일치해 이를 공식 값으로 정했습니다.
2. **핵심 이탈 지점 변경** (03번 → 05번): 처음에는 장바구니 이벤트 누락을 태깅 문제로 보고 보정했지만, 일별로 점검해 보니 26일간 수집 자체가 안 된 기간이었습니다. 이 기간을 빼자 최대 이탈 지점이 배송정보 → 결제정보에서 장바구니 → 결제 시작(54.5%)으로 바뀌었습니다.

## 데이터 한계

- 공개 샘플이라 일부 값이 난독화되어 있습니다(`<Other>`, `(data deleted)`). 채널 불명 세션이 약 35%입니다.
- 거래 ID가 수집되지 않은 구간(11/1~11/10, 1/26~1/31)이 있어 매출은 거래 ID 식별분만 센 보수적 값입니다.

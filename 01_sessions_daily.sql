-- =========================================================
-- 01_sessions_daily.sql
-- 목적: 세션 수 일별 추이 (세션을 시작일 하루에만 배정)
-- 데이터: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--        (2020-11-01 ~ 2021-01-31, 92일)
-- 세션 정의: user_pseudo_id + ga_session_id
-- 검증: 일별 합계 360,129 = 전체 세션 수 (중복 없음), 92행
-- 결과: 세션 상위일 12/8(7,562), 12/9, 1/6, 12/10, 12/15
--       주말은 평일보다 낮고, 12월 하순~연초는 약 2.5천 수준으로 하락
-- =========================================================

WITH ev AS (
  SELECT
    user_pseudo_id,
    event_date,
    -- event_params는 ARRAY라 SELECT 안 서브쿼리로 UNNEST
    -- (FROM절 UNNEST는 이벤트 행이 파라미터 수만큼 늘어남)
    (SELECT value.int_value FROM UNNEST(event_params)
     WHERE key = 'ga_session_id') AS session_id
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

sessions AS (
  SELECT
    user_pseudo_id,
    session_id,
    -- event_date로 그냥 묶으면 자정을 넘긴 세션이 이틀에 중복 집계됨
    -- → 세션당 첫 날짜(MIN) 하나만 배정
    -- event_date는 STRING('20201101')이라 DATE로 변환
    PARSE_DATE('%Y%m%d', MIN(event_date)) AS session_date
  FROM ev
  WHERE session_id IS NOT NULL   -- 확인 결과 세션 ID 없는 이벤트 0건 (안전장치)
  -- ga_session_id는 세션 시작 시각 기반이라 사용자 간 겹칠 수 있음
  -- → user_pseudo_id와 묶어서 세션 키로 사용
  GROUP BY user_pseudo_id, session_id
)

SELECT
  session_date,
  FORMAT_DATE('%a', session_date) AS dow,   -- 요일 (주말 패턴 확인용)
  COUNT(*) AS sessions
FROM sessions
GROUP BY session_date
ORDER BY session_date;

-- 상위 5일만 볼 때는 마지막 두 줄을 아래로 바꿔 실행
-- ORDER BY sessions DESC
-- LIMIT 5;
